# The migration lives in platform/ops/plan (`atlas migrate-producer`), which is no part of
# the model; its module is loaded here to run it on the real path. Its default reads and
# writes go through the agent client, which this project has not: the test passes its own.
warn = Code.get_compiler_option(:no_warn_undefined)
Code.put_compiler_option(:no_warn_undefined, [AtlasAgent, AtlasAgent.Client])
Code.require_file("../../../../../platform/ops/plan/lib/atlas_plan/producer.ex", __DIR__)
Code.put_compiler_option(:no_warn_undefined, warn)

defmodule Model.ProducerMigrationTest do
  @moduledoc """
  UC-Atlas-23: the one-off `atlas migrate-producer` (`AtlasPlan.Producer`) on a store from
  before producers were recorded, on the real path: the real Facts on its in-memory rela,
  with the history Facts keeps of each fact's links in its data folder, as a copy of an
  environment's facts holds them. It reads what Control's `facts_read` reads (with
  `history`) and writes as the migration, as Control sends it.

  Afterwards no scene, use case or issue is without **Produced by**, each with an origin
  by the migration that says it was backfilled and from what; a second run changes
  nothing; and Facts refuses an item without one. Then Design's questions and Accept the
  scene go to the producer, as the model's owners resolve them, never to the decider.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log
  @moduletag :tmp_dir

  alias AtlasBus.Envelope
  alias AtlasFacts.{FakeRela, Links}
  alias AtlasPlan.Producer
  alias Model.AtlasEyra

  @model AtlasEyra
  @decider "melle"
  @assists %{"coordinator" => "melle"}

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  setup %{tmp_dir: dir} do
    environment = Application.get_env(:atlas_bus, :environment)
    store = Application.get_env(:atlas_bus, :store)
    Application.put_env(:atlas_bus, :environment, "test")
    Application.put_env(:atlas_bus, :store, "migration-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_env(:atlas_bus, :environment, environment)
      restore_env(:atlas_bus, :store, store)
    end)

    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    rela = FakeRela.start(@model)
    for p <- ~w(adrienne melle bob), do: {:ok, _} = FakeRela.create(rela, "people", p, %{}, %{})

    # The store from before: items in rela without produced_by, and the history Facts
    # recorded of the links their creates set.
    before(rela, dir)

    start_supervised!({AtlasFacts.Server, rela: {FakeRela, rela}, data_dir: dir, model: @model})
    :ok = AtlasBus.attach("control/session-migration-#{System.unique_integer([:positive])}")
    :ok
  end

  # Who made what, as Facts' history of their links says.
  @before [
    # Put in by hand at the TUI.
    {"scene", "scenes", "SC-Atlas-01", %{}, {"assignment", "adrienne", nil}},
    # Put in by an assisting agent, before Control said on whose behalf.
    {"scene", "scenes", "SC-Atlas-02", %{}, {"assignment", "coordinator", "Newcomers"}},
    # From an import nobody is named for.
    {"scene", "scenes", "SC-Atlas-03", %{}, {"assignment", "migration", "load plan"}},
    # Design's proposal, for its run's supervisor.
    {"use_case", "use_cases", "UC-Atlas-04", %{"in_scene" => ["SC-Atlas-01"]},
     {"in_scene", "flow",
      "For bob: proposed by TK-SC-Atlas-01-1 in the break-down of SC-Atlas-01"}},
    # A review's follow-up.
    {"issue", "issues", "IS-Atlas-05", %{"in_use_case" => ["UC-Atlas-04"]},
     {"in_use_case", "flow",
      "For adrienne: proposed by TK-IS-Atlas-09-2 in the review of IS-Atlas-09"}},
    # Nothing recorded at all.
    {"issue", "issues", "IS-Atlas-06", %{"in_use_case" => ["UC-Atlas-04"]}, nil}
  ]

  defp before(rela, dir) do
    links = Links.open(dir)

    for {kind, plural, key, parent, made} <- @before do
      values =
        if kind == "scene", do: %{"title" => key, "status" => "refine"}, else: %{"title" => key}

      targets =
        Map.new(parent, fn {relation, keys} ->
          {relation, {if(relation == "in_scene", do: "scenes", else: "use_cases"), keys}}
        end)

      {:ok, _} = FakeRela.create(rela, plural, key, values, targets)

      with {relation, by, cause} <- made do
        keys = Map.get(parent, relation, ["AS-" <> key])

        about = %{
          "by" => by,
          "cause" => cause,
          "since" => "2026-10-01T10:00:00Z",
          "position" => 1
        }

        :ok = Links.record(links, kind, key, relation, keys, about)
      end
    end

    Links.close(links)
  end

  defp send_bus(class, kind, content) do
    envelope = Envelope.new(class, kind)
    :ok = AtlasBus.send(envelope, content)
    id = envelope.id
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: answer_class}, answer}, 2_000
    {answer_class, answer}
  end

  # Control's facts_read: a list, or one fact with its history.
  defp read(kind, nil),
    do: {:ok, elem(send_bus("read", kind, %{"plain" => true, "linked" => %{}}), 1)}

  defp read(kind, key), do: {:ok, elem(send_bus("read", kind, %{"key" => key}), 1)}

  # The migration's change, as Control sends it for the client that is the migration.
  defp write(key, links, cause) do
    kind =
      Enum.find_value(@before, fn
        {k, _, ^key, _, _} -> k
        _ -> nil
      end)

    content = %{
      "op" => "change",
      "key" => key,
      "values" => %{},
      "links" => Map.new(links, fn {r, p} -> {r, [p]} end),
      "by" => "migration",
      "cause" => cause
    }

    case send_bus("fact", kind, content) do
      {"stored", _} -> {:ok, key}
      {"refused", answer} -> {:refused, answer["reasons"] || ["refused"]}
    end
  end

  defp migrate(opts \\ []),
    do:
      Producer.run(
        nil,
        [
          assists: @assists,
          decider: @decider,
          read: &read/2,
          write: &write/3,
          say: fn _ -> :ok end
        ] ++ opts
      )

  defp fact(kind, key), do: elem(read(kind, key), 1)["fact"]

  test "every item gets its producer from its history, the decider when it names nobody; once" do
    # A dry run writes nothing.
    assert {:ok, %{steps: steps, written: 0}} = migrate(dry_run: true)
    assert length(steps) == 6
    assert fact("scene", "SC-Atlas-01")["links"]["produced_by"] in [nil, []]

    assert {:ok, %{written: 6}} = migrate()

    expected = %{
      "SC-Atlas-01" => {"adrienne", "put in by adrienne by hand"},
      "SC-Atlas-02" => {"melle", "put in by coordinator, who assists melle"},
      "SC-Atlas-03" =>
        {"melle",
         "its history names nobody who made it (made by migration): the configured decider"},
      "UC-Atlas-04" => {"bob", ~s|made by flow, "For bob: proposed by TK-SC-Atlas-01-1|},
      "IS-Atlas-05" =>
        {"adrienne", ~s|made by flow, "For adrienne: proposed by TK-IS-Atlas-09-2 in the review|},
      "IS-Atlas-06" => {"melle", "its history names nobody who made it: the configured decider"}
    }

    for {kind, _, key, _, _} <- @before do
      {person, from} = expected[key]
      f = fact(kind, key)
      assert f["links"]["produced_by"] == [person], key

      # Its origin: by the migration, saying it was backfilled and from what.
      assert %{"by" => "migration", "cause" => cause} = f["origins"]["produced_by"]
      assert cause =~ "backfilled (UC-Atlas-23)", key
      assert cause =~ from, key
    end

    # A second run changes nothing.
    assert {:ok, %{steps: [], written: 0}} = migrate()

    # Nobody takes it away again, the migration neither.
    clear = %{
      "op" => "change",
      "key" => "SC-Atlas-01",
      "values" => %{},
      "links" => %{"produced_by" => []},
      "by" => "migration",
      "cause" => "x"
    }

    assert {"refused", %{"reasons" => [why]}} = send_bus("fact", "scene", clear)
    assert why =~ "records its producer (produced_by)"
  end

  test "before it runs, Facts refuses any change to an item that records no producer" do
    content = %{
      "op" => "change",
      "key" => "IS-Atlas-06",
      "values" => %{"title" => "Wrap it"},
      "links" => %{},
      "by" => "adrienne"
    }

    assert {"refused", %{"reasons" => [why]}} = send_bus("fact", "issue", content)
    assert why =~ "records its producer (produced_by)"
  end

  test "after it, the producer states go to the producer, never the decider" do
    assert {:ok, _} = migrate()
    {:ok, actors} = AtlasBus.Actors.resolve(AtlasEyra.actors(), %{"decider" => @decider})

    producer = %{"producer" => person(hd(fact("scene", "SC-Atlas-01")["links"]["produced_by"]))}

    for {flow, state} <- [
          {"break_down_scene", "clarifying"},
          {"break_down_use_case", "clarifying"},
          {"accept_scene", "to_accept"}
        ],
        env <- [:prod, :test] do
      subflow = Enum.find(AtlasEyra.subflows(env), &(&1.name() == flow))
      default = subflow.owner(state)["default"]
      refute Map.has_key?(default, "config"), "#{flow} #{state}"

      assert AtlasFlow.Model.owner(default, actors, producer) == person("adrienne")
    end
  end

  # A person as an owner is written (`%{"kind", "key"}`): a test's, never the model's.
  defp person(key), do: Map.put(%{"kind" => "person"}, "key", key)
end
