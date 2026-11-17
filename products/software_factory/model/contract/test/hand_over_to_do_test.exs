defmodule Model.HandOverToDoTest do
  @moduledoc """
  M3 S3 (work acquisition decision 2026-11-17, decision 4; plan rev 3 N10, Q16): the
  To-Do Flow gives the person a run is handed over to, as the core's configuration
  (`config :atlas_flow, :hand_over`) and this model make it. Facts takes its two writes
  (the To-Do's create, which makes its Assignment, then the Assignment's `assigned_to`),
  and the To-Do's own run, started and projected through the composition, keeps that
  person as its owner instead of moving it to its subflow's default (the decider).
  Structure, not wording.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.FakeFacts
  alias AtlasFlow.Runs.{HandOver, Projection, Store}

  @now ~U[2026-11-17 09:00:00Z]
  @config Path.expand("../../../config/config.exs", __DIR__)
  @issue "IS-Atlas-01"
  @run "RUN-1"

  # The core's configuration of the hand-over To-Do, as Flow reads it.
  defp configured, do: Config.Reader.read!(@config, env: :test)[:atlas_flow][:hand_over]

  defp runner, do: AtlasFlow.Model.load(Model.AtlasEyra, :test, %{"decider" => "someone"})

  defp lookup do
    %{
      "current" => fn -> nil end,
      "fact" => fn _, _ -> nil end,
      "list" => fn _ -> {:ok, []} end,
      "incoming" => fn _, _, _ -> [] end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  setup do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    environment = Application.get_env(:atlas_bus, :environment)
    hand_over = Application.get_env(:atlas_flow, :hand_over)
    Application.put_env(:atlas_bus, :environment, "test")
    Application.put_env(:atlas_flow, :hand_over, configured())

    on_exit(fn ->
      restore_env(:atlas_bus, :environment, environment)
      restore_env(:atlas_flow, :hand_over, hand_over)
    end)

    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    start_supervised!(FakeFacts)
    :ok = AtlasBus.attach("flow")

    for p <- ~w(ada bea someone), do: FakeFacts.put("person", %{"key" => p})

    runner = runner()
    assert runner.refusal == nil
    assert %{} = spec = runner.config["hand_over"]
    %{runner: runner, spec: spec}
  end

  # The hand-over of the issue's run from ada to bea, as Flow builds its writes.
  defp writes(spec, number \\ 1),
    do:
      HandOver.writes(
        spec,
        %{"key" => @run, "subject_key" => @issue},
        %{"to" => "bea", "input" => "FI-1"},
        "ada",
        number
      )

  # What Facts stores of `writes`: the To-Do with the Assignment its create makes (the
  # model's `with_change/3`), and the Assignment's link with who set it (its origin).
  defp store(writes) do
    [create, owner] = writes
    content = create["content"]
    changes = Model.AtlasEyra.with_change(create["kind"], content, lookup())
    assert [%{"as" => "component"} = part, %{"as" => "fact"}] = changes

    FakeFacts.put(create["kind"], %{
      "key" => content["key"],
      "values" => content["values"],
      "links" => %{part["relation"] => [part["key"]]}
    })

    links = owner["content"]["links"] || %{}

    origins =
      Map.new(links, fn {relation, _} ->
        {relation, %{"by" => owner["content"]["by"], "position" => 1}}
      end)

    FakeFacts.put(part["kind"], %{
      "key" => part["key"],
      "values" => part["values"],
      "links" => links,
      "origins" => origins
    })

    {content["key"], part}
  end

  test "the core configures it, and it resolves on this model's To-Do and Assignment", c do
    assert configured() != nil
    assert %{"kind" => "to_do", "part" => %{"kind" => "assignment"}} = c.spec
    assert c.spec["owner_relation"] == "assigned_to"
    assert c.spec["prefix"] == Enum.find(Model.AtlasEyra.kinds(), &(&1.name == "to_do")).id.prefix

    # Whoever supervises can be assigned it.
    holders =
      get_in(Model.AtlasEyra.relations(), [Model.AtlasEyra.supervision()["relation"], "to"])

    assert Enum.all?(holders, &(&1 in Model.AtlasEyra.relations()["assigned_to"]["to"]))
  end

  test "Facts takes both writes: the To-Do and its Assignment, then the Assignment's assigned_to",
       c do
    [create, owner] = writes(c.spec)
    content = create["content"]

    # One To-Do, valid as the model requires it, by Flow.
    assert create["kind"] == "to_do" and content["op"] == "create"
    assert content["key"] == "TD-01"
    assert String.contains?(content["values"]["instructions"], @issue)
    assert content["values"]["status"] == "open"

    assert Model.AtlasEyra.check(
             "to_do",
             Map.put(content, "links", %{}),
             %{"by" => "flow", "sender" => "flow"},
             lookup()
           ) == :ok

    # Its create makes its Assignment; the second write links that one to bea.
    assert [%{"as" => "component", "kind" => "assignment", "key" => part}, _] =
             Model.AtlasEyra.with_change("to_do", content, lookup())

    assert owner["kind"] == "assignment" and owner["content"]["key"] == part
    assert owner["content"]["links"] == %{"assigned_to" => ["bea"]}
    assert owner["content"]["by"] == "ada"

    assert Model.AtlasEyra.check(
             "assignment",
             owner["content"],
             %{"by" => "ada", "sender" => "flow"},
             %{
               lookup()
               | "current" => fn ->
                   %{"key" => part, "values" => %{"of" => "TD-01"}, "links" => %{}}
                 end
             }
           ) == :ok
  end

  test "the To-Do's own run keeps bea as its owner: started and projected, never the decider",
       c do
    {key, part} = store(writes(c.spec))

    config = c.runner.config
    flows = c.runner.flows
    {:ok, %{runs: known}} = Store.plan(config, flows)
    assert {:ok, runs} = Store.reconcile_subjects(config, flows, @now, known, [{"to_do", key}])

    assert [%{"state" => "open", "status" => "active"}] =
             Enum.filter(runs, &(&1["flow"] == "to_do"))

    assert {:ok, _} = Projection.project(c.runner, "to_do", key)
    assignment = FakeFacts.get("assignment", part["key"])
    assert assignment["values"]["flow_state"] == "open"
    assert assignment["links"]["assigned_to"] == ["bea"]

    # Projected again, still bea's.
    assert {:ok, _} = Projection.project(c.runner, "to_do", key)
    assert FakeFacts.get("assignment", part["key"])["links"]["assigned_to"] == ["bea"]
  end
end
