defmodule AtlasFlow.FakeFacts do
  @moduledoc """
  A stand-in for Facts on the Bus, for Flow's tests: answers reads with facts as Facts
  wires them (values, links, origins, progress, completion), stores changes in memory,
  and answers each fact with stored and a position (the Bus hints it to listeners). Its
  kinds are made up on purpose: a box holds crates, a clerk signs a box off.
  """
  use GenServer

  alias AtlasBus.Envelope

  @flow %{
    "kinds" => ["box"],
    "field" => "todo",
    "owner_relation" => "owned_by",
    "states" => [
      %{"name" => "done", "when" => %{"completed" => true}, "done" => true},
      %{
        "name" => "again",
        "when" => %{"reopened" => "signed_by"},
        "owner" => %{"kind" => "clerk", "key" => "bob"},
        "expected" => "Again: {note}",
        "why" => "taken back",
        "next" => ["packing", "done"]
      },
      %{
        "name" => "check",
        "when" => %{"progress" => "check"},
        "owner" => %{"kind" => "clerk", "key" => "ada"},
        "expected" => "Check it",
        "why" => "all in it is packed",
        "next" => ["done"]
      },
      %{
        "name" => "packing",
        "owner" => %{"kind" => "clerk", "key" => "bob"},
        "expected" => "Pack it",
        "why" => "not all in it is packed",
        "next" => ["check"]
      }
    ]
  }

  def flow, do: @flow

  def description(flow \\ @flow, problems \\ []) do
    %{
      "entities" => %{
        "box" => %{"plural" => "boxes"},
        "crate" => %{"plural" => "crates"},
        "clerk" => %{"plural" => "clerks"}
      },
      "relations" => %{
        "in_box" => %{"from" => ["crate"], "to" => ["box"], "parent" => true, "max_outgoing" => 1},
        "signed_by" => %{"from" => ["box"], "to" => ["clerk"], "max_outgoing" => 1},
        "owned_by" => %{"from" => ["box"], "to" => ["clerk"], "max_outgoing" => 1}
      },
      "flows" => %{"pack" => flow},
      "flow_problems" => %{"pack" => problems}
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Put a fact as Facts would answer it: `%{\"key\", \"values\", \"links\", …}`."
  def put(kind, fact), do: GenServer.call(__MODULE__, {:put, kind, fact})

  def get(kind, key), do: GenServer.call(__MODULE__, {:get, kind, key})

  @doc "Every fact content Flow sent, oldest first."
  def sent, do: GenServer.call(__MODULE__, :sent)

  def set_description(description), do: GenServer.call(__MODULE__, {:description, description})

  @doc """
  How many of Flow's reads were answered so far, and of those how many plain. Only reads
  from Flow's endpoints count: the Bus is shared, and a process another test left behind
  (a Control session still asking, in the same VM) reads from whatever the store is now.
  """
  def reads, do: GenServer.call(__MODULE__, :reads)

  @impl true
  def init(opts) do
    :ok = AtlasBus.attach(AtlasBus.store())

    {:ok,
     %{
       facts: %{},
       sent: [],
       reads: {0, 0},
       position: 0,
       busy: MapSet.new(),
       description: Keyword.get(opts, :description, description())
     }}
  end

  @impl true
  def handle_call({:put, kind, fact}, _from, s) do
    fact = Map.merge(%{"values" => %{}, "links" => %{}, "origins" => %{}}, fact)
    {:reply, :ok, put_in(s.facts[{kind, fact["key"]}], fact)}
  end

  def handle_call({:get, kind, key}, _from, s), do: {:reply, s.facts[{kind, key}], s}
  def handle_call(:sent, _from, s), do: {:reply, Enum.reverse(s.sent), s}
  def handle_call({:description, d}, _from, s), do: {:reply, :ok, %{s | description: d}}
  def handle_call(:reads, _from, s), do: {:reply, s.reads, s}

  def handle_call({:drop, kind, key}, _from, s),
    do: {:reply, :ok, %{s | facts: Map.delete(s.facts, {kind, key})}}

  # A read of this fact gets Facts' answer when it could not read it, until `{:free, …}`.
  def handle_call({:busy, kind, key}, _from, s),
    do: {:reply, :ok, %{s | busy: MapSet.put(s.busy, {kind, key})}}

  def handle_call({:free, kind, key}, _from, s),
    do: {:reply, :ok, %{s | busy: MapSet.delete(s.busy, {kind, key})}}

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "read"} = e, content}, s) do
    s = if flow?(e.sender), do: %{s | reads: count(s.reads, content)}, else: s

    answer =
      case {e.kind, content} do
        {"_description", _} ->
          %{"description" => s.description}

        {kind, %{"key" => key}} ->
          if MapSet.member?(s.busy, {kind, key}),
            do: %{"error" => "Facts did not answer"},
            else: %{"fact" => s.facts[{kind, key}]}

        {kind, %{"linked" => linked}} ->
          facts =
            for {{^kind, _}, fact} <- s.facts,
                Enum.all?(linked, fn {rel, key} -> key in (fact["links"][rel] || []) end),
                do: fact

          %{"facts" => facts}

        {kind, _} ->
          %{"facts" => for({{^kind, _}, fact} <- s.facts, do: fact)}
      end

    :ok = AtlasBus.send(Envelope.reply(e, "answer"), answer)
    {:noreply, s}
  end

  def handle_info({:atlas_bus, %Envelope{class: "fact"} = e, %{"key" => key} = c}, s) do
    s = %{s | sent: [c | s.sent], position: s.position + 1}

    facts =
      Map.update(s.facts, {e.kind, key}, nil, fn fact ->
        values =
          (fact["values"] || %{})
          |> Map.merge(c["values"] || %{})
          |> Map.reject(fn {_, v} -> v in [nil, ""] end)

        %{fact | "values" => values, "links" => Map.merge(fact["links"], c["links"] || %{})}
      end)

    :ok =
      AtlasBus.send(
        Envelope.reply(e, "stored", position: s.position),
        Map.take(c, ["op", "key", "by"])
      )

    {:noreply, %{s | facts: facts}}
  end

  def handle_info(_message, s), do: {:noreply, s}

  defp flow?(sender), do: sender == "flow" or String.starts_with?(sender || "", "flow/")

  defp count({all, plain}, content),
    do: {all + 1, plain + if(content["plain"] == true, do: 1, else: 0)}
end
