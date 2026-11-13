defmodule AtlasFlow.FakeFacts do
  @moduledoc """
  A stand-in for Facts on the Bus, for Flow's tests: answers reads with facts as Facts
  wires them (values, links, origins, progress, completion), stores changes in memory,
  and answers each fact with stored and a position (the Bus hints it to listeners). Its
  kinds are the neutral depot's (`AtlasFlow.Depot`): a box holds crates, a clerk signs a
  box off.

  It keeps a run's inputs as Facts does (its flow inputs), for the kind a fact
  `submit` is sent of: a submit applies the choice to the run's subject and records it
  applied; a read by `run` answers the run's inputs; Flow's `consume` is taken only for the
  input the stored run names as its last, at or past its position.
  """
  use GenServer

  alias AtlasBus.Envelope

  @doc """
  What Facts describes: rela's kinds and relations. What the model adds to them (parent
  relations, components, the turn) and its flows are the model's (`AtlasFlow.Depot`),
  never the description's.
  """
  def description do
    %{
      "entities" => %{
        "box" => %{"plural" => "boxes"},
        "crate" => %{"plural" => "crates"},
        "clerk" => %{"plural" => "clerks"}
      },
      "relations" => %{
        "in_box" => %{"from" => ["crate"], "to" => ["box"], "max_outgoing" => 1},
        "signed_by" => %{"from" => ["box"], "to" => ["clerk"], "max_outgoing" => 1},
        "owned_by" => %{"from" => ["box"], "to" => ["clerk"], "max_outgoing" => 1}
      }
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Put a fact as Facts would answer it: `%{\"key\", \"values\", \"links\", …}`."
  def put(kind, fact), do: GenServer.call(__MODULE__, {:put, kind, fact})

  def lose_ack(kind), do: GenServer.call(__MODULE__, {:lose_ack, kind})
  def get(kind, key), do: GenServer.call(__MODULE__, {:get, kind, key})

  @doc "Every fact content Flow sent, oldest first."
  def sent, do: GenServer.call(__MODULE__, :sent)

  @doc "Every fact content stored from Flow's endpoints only, oldest first."
  def stored_from_flow, do: GenServer.call(__MODULE__, :from_flow)

  def set_description(description), do: GenServer.call(__MODULE__, {:description, description})

  @doc """
  How many of Flow's reads were answered so far, and of those how many plain. Only reads
  from Flow's endpoints count: the Bus is shared, and a process another test left behind
  (a Control session still asking, in the same VM) reads from whatever the store is now.
  """
  def reads, do: GenServer.call(__MODULE__, :reads)

  @doc "How many facts Flow sent so far, each attempt and replay counted: its round trips."
  def puts, do: GenServer.call(__MODULE__, :puts)

  @doc "How many facts its answers to Flow's reads held so far (a list counts each fact)."
  def facts_read, do: GenServer.call(__MODULE__, :facts_read)

  @impl true
  def init(opts) do
    :ok = AtlasBus.attach(AtlasBus.store())

    {:ok,
     %{
       facts: %{},
       sent: [],
       ledger: %{},
       lose_ack: nil,
       reads: {0, 0},
       facts_read: 0,
       puts: 0,
       from_flow: [],
       inputs: %{},
       position: 0,
       busy: MapSet.new(),
       busy_after_write: MapSet.new(),
       description: Keyword.get(opts, :description, description())
     }}
  end

  @impl true
  def handle_call({:put, kind, fact}, _from, s) do
    fact = Map.merge(%{"values" => %{}, "links" => %{}, "origins" => %{}}, fact)
    {:reply, :ok, put_in(s.facts[{kind, fact["key"]}], fact)}
  end

  def handle_call({:lose_ack, kind}, _from, s), do: {:reply, :ok, %{s | lose_ack: kind}}
  def handle_call({:get, kind, key}, _from, s), do: {:reply, s.facts[{kind, key}], s}
  def handle_call(:sent, _from, s), do: {:reply, Enum.reverse(s.sent), s}
  def handle_call(:from_flow, _from, s), do: {:reply, Enum.reverse(s.from_flow), s}
  def handle_call({:description, d}, _from, s), do: {:reply, :ok, %{s | description: d}}
  def handle_call(:reads, _from, s), do: {:reply, s.reads, s}
  def handle_call(:facts_read, _from, s), do: {:reply, s.facts_read, s}
  def handle_call(:puts, _from, s), do: {:reply, s.puts, s}

  def handle_call({:drop, kind, key}, _from, s),
    do: {:reply, :ok, %{s | facts: Map.delete(s.facts, {kind, key})}}

  # A read of this fact gets Facts' answer when it could not read it, until `{:free, …}`.
  def handle_call({:busy, kind, key}, _from, s),
    do: {:reply, :ok, %{s | busy: MapSet.put(s.busy, {kind, key})}}

  # Reads of this fact fail once its next write is stored (Flow stops there, as on a crash
  # right after that write), until `{:free, …}`.
  def handle_call({:busy_after_write, kind, key}, _from, s),
    do: {:reply, :ok, %{s | busy_after_write: MapSet.put(s.busy_after_write, {kind, key})}}

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

        # The inputs of a run, in their order.
        {_kind, %{"run" => run}} ->
          %{
            "inputs" =>
              for({_, i} <- s.inputs, i["run"] == run, do: i) |> Enum.sort_by(& &1["position"])
          }

        {kind, _} ->
          %{"facts" => for({{^kind, _}, fact} <- s.facts, do: fact)}
      end

    s =
      if flow?(e.sender),
        do: %{s | facts_read: s.facts_read + length(List.wrap(answer["facts"] || answer["fact"]))},
        else: s

    :ok = AtlasBus.send(Envelope.reply(e, "answer"), answer)
    {:noreply, s}
  end

  def handle_info({:atlas_bus, %Envelope{class: "fact"} = e, c}, s) do
    s = if flow?(e.sender), do: %{s | puts: s.puts + 1}, else: s

    case {s.ledger[e.id], c} do
      {{class, answer, position}, _} ->
        AtlasBus.send(Envelope.reply(e, class, position: position), answer)
        {:noreply, s}

      {nil, %{"op" => "submit"}} ->
        {:noreply, submit(e, c, s)}

      {nil, %{"op" => "consume"}} ->
        {:noreply, consume(e, c, s)}

      {nil, %{"key" => _}} ->
        fact(e, c, s)

      _ ->
        {:noreply, s}
    end
  end

  def handle_info(_message, s), do: {:noreply, s}

  # Someone's choice (`values`: `run`, `entry`, `roles`, `changed_fields`): its subject
  # changed as it says, and the input recorded applied on the subject's new version.
  defp submit(e, %{"key" => key, "values" => v}, s) do
    run = cursor(s, v["run"])
    subject_key = {run["values"]["subject_kind"], run["values"]["subject_key"]}
    position = s.position + 1
    subject = s.facts[subject_key]

    subject =
      Map.merge(subject, %{
        "values" => Map.merge(subject["values"], v["changed_fields"]),
        "version" => position,
        "position" => position
      })

    input =
      Map.merge(v, %{
        "key" => key,
        "status" => "applied",
        "position" => position,
        "subject_version" => position,
        "prepared_at" => v["prepared_at"] || "2026-11-12T00:00:00Z"
      })

    answer = %{
      "op" => "submit",
      "key" => key,
      "subject_kind" => elem(subject_key, 0),
      "subject_key" => elem(subject_key, 1),
      "changes" => [
        %{"kind" => elem(subject_key, 0), "key" => elem(subject_key, 1), "op" => "change"}
      ]
    }

    AtlasBus.send(Envelope.reply(e, "stored", position: position), answer)

    %{
      s
      | position: position,
        facts: Map.put(s.facts, subject_key, subject),
        inputs: Map.put(s.inputs, key, input),
        ledger: Map.put(s.ledger, e.id, {"stored", answer, position})
    }
  end

  # Flow's consume: only of the input the stored run accepted last, as Facts takes it.
  defp consume(e, %{"key" => key, "run" => run_key} = c, s) do
    input = s.inputs[key]
    run = cursor(s, run_key)
    last = run && JSON.decode!(run["values"]["last_input"])

    if input != nil and input["run"] == run_key and last["input"] == key and
         run["values"]["input_cursor"] >= input["position"] do
      position = s.position + 1
      answer = %{"key" => key, "status" => "consumed"}
      AtlasBus.send(Envelope.reply(e, "stored", position: position), answer)

      %{
        s
        | position: position,
          sent: [c | s.sent],
          from_flow: [c | s.from_flow],
          inputs: Map.put(s.inputs, key, Map.put(input, "status", "consumed")),
          ledger: Map.put(s.ledger, e.id, {"stored", answer, position})
      }
    else
      AtlasBus.send(Envelope.reply(e, "refused"), %{"reasons" => ["input authority"]})
      s
    end
  end

  defp cursor(s, run_key),
    do: Enum.find_value(s.facts, fn {{_, key}, fact} -> if key == run_key, do: fact end)

  defp fact(e, %{"key" => key} = c, s) do
    old = s.facts[{e.kind, key}]

    conflict =
      old != nil and c["op"] == "change" and c["version"] != nil and
        c["version"] != old["version"] and
        not Enum.all?(c["was"] || %{}, fn {field, value} -> old["values"][field] == value end)

    cond do
      old != nil and c["op"] == "create" and
          Enum.all?(c["values"] || %{}, fn {f, v} -> old["values"][f] == v end) ->
        AtlasBus.send(
          Envelope.reply(e, "stored", position: s.position),
          Map.take(c, ["op", "key", "by"])
        )

        {:noreply, s}

      conflict or (old != nil and c["op"] == "create") ->
        AtlasBus.send(Envelope.reply(e, "refused"), %{"reasons" => ["conflict"]})
        {:noreply, s}

      true ->
        position = s.position + 1
        fact = old || %{"key" => key, "values" => %{}, "links" => %{}, "origins" => %{}}

        values =
          Map.merge(fact["values"], c["values"] || %{})
          |> Map.reject(fn {_, v} -> v in [nil, ""] end)

        links = Map.merge(fact["links"], c["links"] || %{})

        fact =
          Map.merge(fact, %{
            "values" => values,
            "links" => links,
            "version" => position,
            "position" => position
          })

        # What changed, as Facts says it: the fact, with its links before and after.
        both =
          Map.merge(fact_links(old), links, fn _, a, b -> Enum.uniq(a ++ b) end)
          |> Map.reject(fn {_, keys} -> keys == [] end)

        change = %{"kind" => e.kind, "key" => key, "op" => c["op"], "links" => both}
        answer = Map.put(Map.take(c, ["op", "key", "by"]), "changes", [change])

        facts =
          if c["op"] == "delete",
            do: Map.delete(s.facts, {e.kind, key}),
            else: Map.put(s.facts, {e.kind, key}, fact)

        s = %{
          s
          | sent: [c | s.sent],
            from_flow: if(flow?(e.sender), do: [c | s.from_flow], else: s.from_flow),
            position: position,
            facts: facts,
            ledger: Map.put(s.ledger, e.id, {"stored", answer, position})
        }

        s =
          if MapSet.member?(s.busy_after_write, {e.kind, key}),
            do: %{
              s
              | busy: MapSet.put(s.busy, {e.kind, key}),
                busy_after_write: MapSet.delete(s.busy_after_write, {e.kind, key})
            },
            else: s

        if s.lose_ack == e.kind do
          # Commit, then lose the answer. Immediate transport failure avoids timer waits.
          AtlasBus.send(Envelope.reply(e, "refused"), %{"reasons" => ["answer lost"]})
          {:noreply, %{s | lose_ack: nil}}
        else
          AtlasBus.send(Envelope.reply(e, "stored", position: position), answer)
          {:noreply, s}
        end
    end
  end

  defp fact_links(nil), do: %{}
  defp fact_links(fact), do: fact["links"] || %{}

  defp flow?(sender), do: sender == "flow" or String.starts_with?(sender || "", "flow/")

  defp count({all, plain}, content),
    do: {all + 1, plain + if(content["plain"] == true, do: 1, else: 0)}
end
