defmodule AtlasRuntime.FakeFacts do
  @moduledoc """
  A stand-in for Facts on the Bus, for Runtime's tests: answers reads (one fact, all of a
  kind, those linked to a key), stores creates and changes in memory, and answers each
  fact with stored (the Bus hints it to listeners). Its kinds are the neutral model's
  (`AtlasRuntime.TestModel`): a clerk owns a box through a card; a run is a turn.

  A read that asks for it (`"presentation" => true`) answers each fact with the
  presentation the test gave it (as Facts derives it from the runs), or none.
  """
  use GenServer

  alias AtlasBus.Envelope

  @doc """
  What Facts answers as its description for `model`: the model's Rela schema with its
  additions merged into it, map by map. Runtime never reads it; Facts' other readers (a
  Flow item in an integration script) do, until Facts runs the model itself.
  """
  def description_of(model) do
    d = model.__rela__(:description)
    merge(d.schema, d.extension)
  end

  defp merge(left, right) do
    Map.merge(left, right, fn _key, l, r ->
      if is_map(l) and is_map(r), do: merge(l, r), else: r
    end)
  end

  @doc "Start it; `description:` is what it answers to a description read (none by default)."
  def start_link(opts \\ []),
    do:
      GenServer.start_link(__MODULE__, Keyword.get(List.wrap(opts), :description),
        name: __MODULE__
      )

  @doc "Put a fact as Facts would answer it."
  def put(kind, fact), do: GenServer.call(__MODULE__, {:put, kind, fact})
  def get(kind, key), do: GenServer.call(__MODULE__, {:get, kind, key})
  def all(kind), do: GenServer.call(__MODULE__, {:all, kind})

  # Capture one read's answer, keeping Facts responsive while the test advances other
  # processes. Releasing it returns the old snapshot, as a delayed Bus reply would.
  def hold_read(kind, content), do: GenServer.call(__MODULE__, {:hold, kind, content})
  def release_read, do: GenServer.call(__MODULE__, :release)

  @doc "Every fact content sent, oldest first, with its kind."
  def sent, do: GenServer.call(__MODULE__, :sent)

  @impl true
  def init(description) do
    :ok = AtlasBus.attach(AtlasBus.store())
    {:ok, %{facts: %{}, sent: [], position: 0, hold: nil, held: nil, description: description}}
  end

  @impl true
  def handle_call({:put, kind, fact}, _from, s) do
    fact = Map.merge(%{"values" => %{}, "links" => %{}, "origins" => %{}}, fact)
    {:reply, :ok, put_in(s.facts[{kind, fact["key"]}], fact)}
  end

  def handle_call({:get, kind, key}, _from, s), do: {:reply, s.facts[{kind, key}], s}

  def handle_call({:all, kind}, _from, s),
    do: {:reply, for({{^kind, _}, fact} <- Enum.sort(s.facts), do: fact), s}

  def handle_call(:sent, _from, s), do: {:reply, Enum.reverse(s.sent), s}

  def handle_call({:hold, kind, content}, {pid, _}, s) do
    ref = make_ref()
    {:reply, ref, %{s | hold: {kind, content, pid, ref}}}
  end

  def handle_call(:release, _from, %{held: {e, answer}} = s) do
    :ok = AtlasBus.send(Envelope.reply(e, "answer"), answer)
    {:reply, :ok, %{s | held: nil}}
  end

  @impl true
  def handle_info({:atlas_bus, %Envelope{class: "read"} = e, content}, s) do
    answer =
      case {e.kind, content} do
        {"_description", _} when s.description != nil ->
          %{"description" => s.description}

        {kind, %{"key" => key}} ->
          %{"fact" => s.facts[{kind, key}] && present(kind, s.facts[{kind, key}], content)}

        {kind, %{"linked" => linked}} ->
          facts =
            for {{^kind, _}, fact} <- Enum.sort(s.facts),
                Enum.all?(linked, fn {rel, key} -> key in (fact["links"][rel] || []) end),
                do: present(kind, fact, content)

          %{"facts" => facts}

        {kind, _} ->
          %{"facts" => for({{^kind, _}, fact} <- Enum.sort(s.facts), do: fact)}
      end

    case s.hold do
      {kind, ^content, pid, ref} when kind == e.kind ->
        send(pid, {:held_read, ref})
        {:noreply, %{s | hold: nil, held: {e, answer}}}

      _ ->
        :ok = AtlasBus.send(Envelope.reply(e, "answer"), answer)
        {:noreply, s}
    end
  end

  def handle_info({:atlas_bus, %Envelope{class: "fact"} = e, %{"key" => key} = c}, s) do
    s = %{s | sent: [{e.kind, c} | s.sent], position: s.position + 1}
    clean = fn values -> Map.reject(values, fn {_, v} -> v in [nil, ""] end) end

    fact =
      case s.facts[{e.kind, key}] do
        nil ->
          %{"key" => key, "values" => clean.(c["values"] || %{}), "links" => c["links"] || %{}}

        fact ->
          %{
            fact
            | "values" => clean.(Map.merge(fact["values"], c["values"] || %{})),
              "links" => Map.merge(fact["links"], c["links"] || %{})
          }
      end

    :ok =
      AtlasBus.send(
        Envelope.reply(e, "stored", position: s.position),
        Map.take(c, ["op", "key", "by"])
      )

    {:noreply, put_in(s.facts[{e.kind, key}], fact)}
  end

  def handle_info(_message, s), do: {:noreply, s}

  # A presentation the test gives (a run that ended, say) is answered as it is.
  defp present(_kind, %{"presentation" => _} = fact, %{"presentation" => true}), do: fact

  defp present(_kind, fact, _content), do: fact
end
