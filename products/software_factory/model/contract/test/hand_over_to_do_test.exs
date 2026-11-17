defmodule Model.HandOverToDoTest do
  @moduledoc """
  M3 S3 (work acquisition decision 2026-11-17, decision 4; plan rev 3 N10, Q16): the
  To-Do Flow gives the person a run is handed over to, as the core's configuration
  (`config :atlas_flow, :hand_over`) and this model make it. Facts takes its two writes
  (the To-Do's create, which makes its Assignment, then the Assignment's `assigned_to`),
  both by Flow, never as a person, with the supervisor's hand-over input as their cause
  (Main, #325 B2 (b)). The To-Do's own run, started and projected through the
  composition, keeps that person as its owner because the model owns a To-Do by its
  assignee, whoever wrote the link; only a To-Do nobody is assigned goes to its
  subflow's default (the decider). Structure, not wording.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.FakeFacts
  alias AtlasFlow.Runs.{HandOver, Projection, Store}

  @now ~U[2026-11-17 09:00:00Z]
  @config Path.expand("../../../config/config.exs", __DIR__)
  @issue "IS-Atlas-01"
  @run "RUN-1"
  @agent "coordinator"
  @machinery "sorter"

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
    # An agent and a machinery `assigned_to` may link as well (owner rule (ii)).
    FakeFacts.put("agent", %{"key" => @agent})
    FakeFacts.put("machinery", %{"key" => @machinery})

    runner = runner()
    assert runner.refusal == nil
    assert %{} = spec = runner.config["hand_over"]
    %{runner: runner, spec: spec}
  end

  # The hand-over of the issue's run from ada to `to` (bea), as Flow builds its writes.
  defp writes(spec, number \\ 1, to \\ "bea"),
    do:
      HandOver.writes(
        spec,
        %{"key" => @run, "subject_key" => @issue},
        %{"to" => to, "input" => "FI-1"},
        "ada",
        number
      )

  # What Facts stores of `writes`: the To-Do with the Assignment its create makes (the
  # model's `with_change/3`), and the Assignment's link with who set it (its origin).
  defp store(writes, by \\ nil) do
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
        {relation, %{"by" => by || owner["content"]["by"], "position" => 1}}
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

    # Both by Flow, never as a person; each names the supervisor's hand-over input.
    for write <- [create, owner] do
      assert write["content"]["by"] == "flow"
      assert String.contains?(write["content"]["cause"], "FI-1")
      assert String.contains?(write["content"]["cause"], "ada")
    end

    assert Model.AtlasEyra.check(
             "assignment",
             owner["content"],
             %{"by" => "flow", "sender" => "flow"},
             %{
               lookup()
               | "current" => fn ->
                   %{"key" => part, "values" => %{"of" => "TD-01"}, "links" => %{}}
                 end
             }
           ) == :ok
  end

  # The To-Do's run, started and projected once: the Assignment as it is then.
  defp started(c, key, part) do
    config = c.runner.config
    flows = c.runner.flows
    {:ok, %{runs: known}} = Store.plan(config, flows)
    assert {:ok, runs} = Store.reconcile_subjects(config, flows, @now, known, [{"to_do", key}])
    assert [%{"state" => "open"}] = Enum.filter(runs, &(&1["flow"] == "to_do"))
    assert {:ok, _} = Projection.project(c.runner, "to_do", key)
    FakeFacts.get("assignment", part["key"])
  end

  test "N10: the To-Do is owned by its assignee, whoever wrote the link", c do
    for {by, number} <- [{"flow", 1}, {"ada", 2}] do
      {key, part} = store(writes(c.spec, number), by)
      assert started(c, key, part)["links"]["assigned_to"] == ["bea"]
    end
  end

  test "a To-Do nobody is assigned is the decider's", c do
    [create, owner] = writes(c.spec)
    {key, part} = store([create, put_in(owner, ["content", "links"], %{})])
    assert started(c, key, part)["links"]["assigned_to"] == ["someone"]
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

  # The To-Do is updated (its evidence, then its Assignment's deadline), and Flow
  # reconciles and projects it again, as it does on every change of it: its owner then.
  defp updated(c, key, part) do
    to_do = FakeFacts.get("to_do", key)
    FakeFacts.put("to_do", put_in(to_do, ["values", "evidence"], "updated"))
    project_again(c, key)

    assignment = FakeFacts.get("assignment", part["key"])
    FakeFacts.put("assignment", put_in(assignment, ["values", "deadline"], "2026-11-24"))
    project_again(c, key)

    FakeFacts.get("assignment", part["key"])
  end

  defp project_again(c, key) do
    config = c.runner.config
    flows = c.runner.flows
    {:ok, %{runs: known}} = Store.plan(config, flows)
    assert {:ok, runs} = Store.reconcile_subjects(config, flows, @now, known, [{"to_do", key}])

    assert [%{"state" => "open", "status" => "active"}] =
             Enum.filter(runs, &(&1["flow"] == "to_do"))

    assert {:ok, _} = Projection.project(c.runner, "to_do", key)
  end

  test "owner rule (ii): the hand-over To-Do is owned by its person recipient, across updates",
       c do
    {key, part} = store(writes(c.spec))
    assert FakeFacts.get("person", "bea") != nil
    assert started(c, key, part)["links"]["assigned_to"] == ["bea"]
    assert updated(c, key, part)["links"]["assigned_to"] == ["bea"]
    # Flow's writes kept: the link still by Flow, its cause the hand-over input.
    assert FakeFacts.get("assignment", part["key"])["origins"]["assigned_to"]["by"] == "flow"
  end

  # An assignee of another kind than the default's: the To-Do stays theirs, whether the
  # link was written by hand (a person) or by Flow.
  for {kind, assignee} <- [{"agent", @agent}, {"machinery", @machinery}] do
    test "owner rule (ii): a To-Do assigned to #{kind} stays #{kind}-owned across updates",
         c do
      assignee = unquote(assignee)
      assert FakeFacts.get(unquote(kind), assignee) != nil
      assert FakeFacts.get("person", assignee) == nil

      for {by, number} <- [{"ada", 1}, {"flow", 2}] do
        {key, part} = store(writes(c.spec, number, assignee), by)
        assert started(c, key, part)["links"]["assigned_to"] == [assignee]
        assert updated(c, key, part)["links"]["assigned_to"] == [assignee]
        refute FakeFacts.get("assignment", part["key"])["links"]["assigned_to"] == ["someone"]
      end
    end
  end
end
