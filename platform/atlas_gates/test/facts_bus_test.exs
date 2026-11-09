defmodule AtlasGates.FactsBusTest do
  @moduledoc """
  Recording over the Bus, against a stand-in store that answers as Facts does: reads of a
  kind, and facts answered once per id (a resent id gets its first answer again), refusing
  a key that is taken with `exists`. How a key is made is the model's
  (`AtlasGates.Neutral.ids/0`).
  """
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasGates.Fixtures

  defmodule Store do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def facts(pid), do: GenServer.call(pid, :facts)

    @impl true
    def init(opts) do
      :ok = AtlasBus.attach(AtlasBus.store())

      {:ok,
       %{
         facts: Map.new(opts[:facts] || [], &{&1["key"], &1}),
         answers: %{},
         refuse: opts[:refuse],
         silent: opts[:silent] == true
       }}
    end

    @impl true
    def handle_call(:facts, _from, s), do: {:reply, s.facts, s}

    @impl true
    def handle_info({:atlas_bus, _e, _c}, %{silent: true} = s), do: {:noreply, s}

    def handle_info(
          {:atlas_bus, %Envelope{class: "read"} = e, %{"key" => key, "plain" => true}},
          s
        ) do
      :ok = AtlasBus.send(Envelope.reply(e, "answer"), %{"fact" => s.facts[key]})
      {:noreply, s}
    end

    def handle_info({:atlas_bus, %Envelope{class: "read"} = e, _}, s) do
      :ok = AtlasBus.send(Envelope.reply(e, "answer"), %{"facts" => Map.values(s.facts)})
      {:noreply, s}
    end

    def handle_info({:atlas_bus, %Envelope{class: "fact"} = e, %{"key" => key} = c}, s) do
      {{class, answer}, s} =
        case s.answers[e.id] do
          nil ->
            answer =
              cond do
                s.refuse ->
                  {"refused", %{"reasons" => [s.refuse]}}

                not Enum.all?(Map.values(c["links"] || %{}), &is_list/1) ->
                  {"refused", %{"reasons" => ["links need lists of keys"]}}

                # As Facts and rela: a fact is made without association links, then linked.
                c["op"] == "create" and c["links"] not in [nil, %{}] ->
                  {"refused", %{"reasons" => ["a create carries no association links"]}}

                c["op"] == "change" and Map.has_key?(s.facts, key) ->
                  {"stored", %{"op" => "change", "key" => key}}

                Map.has_key?(s.facts, key) ->
                  {"refused", %{"key" => key, "code" => "exists"}}

                true ->
                  {"stored", %{"op" => "create", "key" => key}}
              end

            facts =
              cond do
                elem(answer, 0) != "stored" ->
                  s.facts

                c["op"] == "change" ->
                  put_in(s.facts, [key, "links"], c["links"])

                true ->
                  Map.put(s.facts, key, %{"key" => key, "values" => c["values"], "links" => %{}})
              end

            {answer, %{s | facts: facts, answers: Map.put(s.answers, e.id, answer)}}

          answer ->
            {answer, s}
        end

      :ok = AtlasBus.send(Envelope.reply(e, class), answer)
      {:noreply, s}
    end
  end

  setup do
    Application.put_env(:atlas_bus, :store, "store-#{System.unique_integer([:positive])}")
    endpoint = "gates-test-#{System.unique_integer([:positive])}"
    {:ok, facts} = AtlasGates.Facts.Bus.attach(endpoint)
    %{facts: facts}
  end

  defp decide(request, facts),
    do: AtlasGates.decide(request, facts, kind: "ruling", now: Fixtures.now())

  test "fetch resolves a subject key and retains exact values and links", %{
    facts: {module, state}
  } do
    row = %{
      "key" => "RU-001",
      "values" => %{"weight" => "heavy"},
      "links" => %{"about" => ["C-7"]}
    }

    start_supervised!({Store, facts: [row]})
    assert {:ok, ^row} = module.fetch(state, nil, "RU-001")
    assert {:ok, [^row]} = module.fetch(state, "ruling", nil)
    assert {:ok, nil} = module.fetch(state, "ruling", "missing")
  end

  test "a verdict is recorded with the next key, and a repeat finds it", %{facts: facts} do
    store = start_supervised!({Store, facts: [%{"key" => "RU-009", "values" => %{}}]})

    assert {:ok, %{recorded: "RU-010", recorded_as: :new, outcome: "ship"}} =
             decide(
               Fixtures.request("dispatch", Fixtures.evidence(), %{"links" => %{"about" => "C-7"}}),
               facts
             )

    assert %{
             "values" => %{"verdict" => "ship", "evidence_digest" => "sha256:" <> _},
             "links" => %{"about" => ["C-7"]}
           } =
             Store.facts(store)["RU-010"]

    assert {:ok, %{recorded: "RU-010", recorded_as: :again}} = decide(Fixtures.request(), facts)
    assert map_size(Store.facts(store)) == 2
  end

  test "a request sent again is stored once, under its first key", %{facts: {module, state}} do
    store = start_supervised!(Store)
    values = %{"gate" => "dispatch"}

    assert {:ok, "RU-001"} = module.create(state, "ruling", "GR-same", values, %{})
    # A second create with the same request id: Facts answers it as the first time.
    assert {:ok, "RU-001"} = module.create(state, "ruling", "GR-same", values, %{})
    assert Map.keys(Store.facts(store)) == ["RU-001"]
  end

  test "a key taken meanwhile is tried again with the next number", %{facts: {module, state}} do
    # The store holds RU-002 but the reads see none: the first try clashes.
    store = start_supervised!({Store, facts: [%{"key" => "RU-001", "values" => %{}}]})
    :sys.replace_state(store, fn s -> put_in(s.facts["RU-002"], %{"key" => "RU-002"}) end)

    assert {:ok, "RU-003"} = module.create(state, "ruling", "GR-x", %{}, %{})
  end

  test "a refusal is an error with the safe verdict", %{facts: facts} do
    start_supervised!({Store, refuse: "a test refusal"})

    assert {:error, %{outcome: "ask", unsettled: "error", recorded: nil}, why} =
             decide(Fixtures.request(), facts)

    assert why =~ "a test refusal"
  end

  test "a store that does not answer is an error, never a pass", %{facts: {module, state}} do
    start_supervised!({Store, silent: true})
    facts = {module, %{state | wait: 0}}

    assert {:error, %{outcome: "ask", unsettled: "error"}, why} =
             decide(Fixtures.request(), facts)

    assert why =~ "did not answer"
  end
end
