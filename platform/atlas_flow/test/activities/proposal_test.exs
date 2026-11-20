defmodule AtlasFlow.Activities.ProposalTest.Bench do
  @moduledoc """
  A neutral model of a task that proposes facts (slice 7): a crate is sorted by a robot (a
  machinery kind) whose agent proposes the crate's items in a file of its result; Flow
  makes them under the crate (`in_crate`, the item's parent relation). Labelled, its agent
  writes the crate's note instead (slice 9). A clerk supervises the run.
  """
  use RelaDSL.Composition,
    name: "proposal",
    subflow_behaviour: AtlasFlow.Subflow

  @behaviour AtlasFlow.Model

  defmodule Desk do
    @moduledoc "The crates, their items and robots, who supervises their runs, and the slips."
    use RelaDSL

    type(:slip_operation, values: [:choice, :pickup, :hand_over])

    entity :clerk, label: "Clerk", plural: "clerks", id_type: :manual do
      field(:name, :string)
    end

    entity :robot, label: "Robot", plural: "robots", id_type: :manual do
      field(:name, :string)
    end

    entity :crate, label: "Crate", plural: "crates", id_type: :manual do
      field(:title, :string)
      field(:phase, :string)
      field(:task_result, :string)
      field(:note, :string)
    end

    entity :item, label: "Item", plural: "items", id_type: :manual, id_prefix: "IT-" do
      field(:title, :string)
      field(:description, :string)
    end

    relation(:owned_by, label: "owned by", from: [:crate], to: [:robot, :clerk], max_outgoing: 1)

    relation(:in_crate,
      label: "in crate",
      from: [:item],
      to: [:crate],
      max_outgoing: 1,
      parent: true
    )

    entity :cursor, label: "Cursor", plural: "cursors", id_type: :manual do
      for f <- ~w(flow subject_kind subject_key definition_sha256 state entered_at status
                  deadlines pending last_input blocked_reason)a,
          do: field(f, :string)

      for f <- ~w(generation entry input_cursor)a, do: field(f, :integer)
    end

    entity :slip, label: "Slip", plural: "slips", id_type: :manual do
      field(:run, :string)
      field(:actor, :string)
      field(:operation, :slip_operation)
      field(:hand_to, :string)
    end

    relation(:watched_by,
      label: "watched by",
      from: [:cursor],
      to: [:clerk],
      max_outgoing: 1,
      set_by: [:flow]
    )

    flow_runtime(
      runs: :cursor,
      writer: [sender: :flow, by: :flow],
      inputs: :slip,
      supervision: [relation: :watched_by, operation: :operation, hand_to: :hand_to]
    )

    subflow :sort, label: "Sort", subject: :crate do
      run_as("system:proposal")
      owner(relation: :owned_by, default: {:clerk, :desk})
      start(:create)
      initial(:sorting)
      supervise(:pack, label: "Pack", states: [:sorting])

      state :sorting do
        task(:plan,
          role: :architect,
          profile: :deep_coding,
          input: [repository: "example.org/acme/proposal", base: "develop"],
          instructions: "Sort the crate.",
          fields: [:title],
          creates: [kind: :item, file: "items.json"],
          records: [kind: "task", relation: "task_of"],
          machinery: "robot",
          on: [completed: :sorted, check_failed: :sorted, stuck: :stuck, abandoned: :stuck]
        )
      end

      final(:sorted)
      final(:stuck)
    end

    select(:sort, admission: [phase: [:first]], imports: [])

    subflow :label, label: "Label", subject: :crate do
      run_as("system:proposal")
      owner(relation: :owned_by, default: {:clerk, :desk})
      start(:predicate, when: "entity.phase == 'second'")
      initial(:labelling)
      supervise(:write, label: "Write", states: [:labelling])

      state :labelling do
        task(:plan,
          role: :architect,
          profile: :deep_coding,
          input: [repository: "example.org/acme/proposal", base: "develop"],
          instructions: "Label the crate.",
          fields: [:title],
          writes: [field: :note, file: "note.md"],
          records: [kind: "task", relation: "task_of"],
          machinery: "robot",
          on: [completed: :labelled, check_failed: :labelled, stuck: :stuck, abandoned: :stuck]
        )
      end

      final(:labelled)
      final(:stuck)
    end

    select(:label, admission: [phase: [:second]], imports: [])
  end

  defmodule Crates do
    @moduledoc "The proposal model's one module."
    use RelaDSL.Module, path: "modules/crates/schema.yaml", concepts: [Desk]
  end

  schema(version: "1.0", namespace: "https://example.invalid/proposal#", description: "Crates.\n")
  modules([Crates])
  environments([:prod, :test])

  acl(comment: "The proposal's roles.")
  role("proposal", read: ["*"], create: [:cursor, :item], update: [:crate, :cursor])
  assign("system:proposal", "proposal")

  defcomposition :proposal do
    subflows([Desk])
  end
end

defmodule AtlasFlow.Activities.ProposalTest do
  @moduledoc """
  Slice 7: a task that proposes facts (`creates`). Its agent writes them to a file at the
  top of the repository in its result commit (`refs/atlas/results/<key>`, read through
  Bases and Code); once it completed, Flow makes one fact per entry under the subject,
  numbered after those there are, by Flow; with no such file the task ends stuck. Slice
  9: one that writes a field of its subject (`writes`) has Flow put the file's text there.
  The real Dispatch, Delivery and Bases (on `FakeCode`), with `FakeFacts` and a manual clock.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Bases, Delivery, Dispatch, FakeCode, FakeFacts, ManualClock}
  alias AtlasFlow.{Results, WorkSource}
  alias AtlasFlow.Activities.ProposalTest.Bench
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.Runs.Store

  @epoch ~U[2026-11-17 12:00:00Z]
  @repository "example.org/acme/proposal"
  @actors %{"desk" => "ada"}
  @mini {"mini", "ada"}

  setup do
    Application.put_env(:atlas_bus, :store, "proposal-#{System.unique_integer([:positive])}")
    dir = Path.join(System.tmp_dir!(), "proposal-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!(FakeFacts)
    {:ok, clock} = ManualClock.start_link(@epoch)
    clock = {ManualClock, clock}

    results = [dir: dir, clock: clock, sweep_ms: 86_400_000, pins: fn -> [] end]
    start_supervised!(Supervisor.child_spec({Results, results}, id: Results))

    code = start_supervised!({FakeCode, %{}}, id: :code)
    FakeCode.put(code, @repository, "develop", "rev_1", %{"README.md" => "# Proposal\n"})

    runner = AtlasFlow.Model.load(Bench, :prod, @actors)
    assert runner.refusal == nil

    FakeFacts.put("clerk", %{"key" => "ada"})
    FakeFacts.put("robot", %{"key" => "mini"})
    :ok = AtlasBus.attach("flow")

    start_supervised!(
      Supervisor.child_spec({Bases, client: FakeCode.client(code), clock: clock}, id: Bases)
    )

    start_supervised!(
      Supervisor.child_spec(
        {Dispatch,
         model: Bench, actors: @actors, clock: clock, poll_wait: 0, sweep_ms: nil, resync_ms: nil},
        id: Dispatch
      )
    )

    start_supervised!(
      Supervisor.child_spec(
        {Delivery, model: Bench, actors: @actors, clock: clock, engine: self()},
        id: Delivery
      )
    )

    %{runner: runner, clock: clock, code: code}
  end

  defp reconcile(c, key) do
    {:ok, %{runs: known}} = Store.plan(c.runner.config, c.runner.flows)
    now = AtlasFlow.Runs.Clock.now(c.clock)

    {:ok, runs} =
      Store.reconcile_subjects(c.runner.config, c.runner.flows, now, known, [{"crate", key}])

    assert [run] = Enum.filter(runs, &(&1["subject_key"] == key))
    run
  end

  # A crate on the mini, supervised by ada, whose run holds its task's intent: sorted in
  # its first phase, labelled in its second.
  defp intended(c, key, phase \\ "first") do
    FakeFacts.put("crate", %{
      "key" => key,
      "values" => %{"phase" => phase, "title" => "Crate #{key}"},
      "links" => %{"owned_by" => ["mini"]},
      "origins" => %{"owned_by" => %{"by" => "someone", "position" => 1}}
    })

    if reconcile(c, key)["pending"]["task"] == nil,
      do: assert_receive({:reconcile, "crate", ^key}, 2_000)

    flow = if phase == "first", do: "sort", else: "label"
    run_key = AtlasFlow.Runs.Run.key(flow, "crate", key, 1)
    fact = FakeFacts.get(c.runner.config["kind"], run_key)
    links = Map.put(fact["links"] || %{}, "watched_by", ["ada"])
    FakeFacts.put(c.runner.config["kind"], Map.merge(fact, %{"links" => links}))

    run = reconcile(c, key)
    assert %{"version" => 2} = run["pending"]["task"]
    run
  end

  # The lease worked to its end, its result commit (the base plus `files`) pushed to Code;
  # the run reconciled once Bases resolved that commit.
  defp finish(c, key, files, phase \\ "first") do
    {id, _} = @mini

    assert {:polled, %{leases: [%{lease_id: lease}]}} =
             WorkSource.poll(@mini, L.poll_input(id, [], %{"deep_coding" => 1}))

    tree = Map.new([{"README.md", "# Proposal\n"} | files])
    FakeCode.put(c.code, @repository, "refs/atlas/results/TK-#{key}-1", "rev_#{key}", tree)
    report = &WorkSource.report(@mini, %{lease_id: lease, revision: &1, report: &2})
    assert {:recorded, _} = report.(1, %{state: :accepted})
    assert {:recorded, _} = report.(2, %{state: :started})
    assert {:recorded, _} = report.(3, L.ended(nil))
    assert_receive {:"$gen_cast", {:reconcile, "crate", ^key}}

    # Its result is asked of Bases first; nothing moves until Bases has it.
    assert reconcile(c, key)["state"] == if(phase == "first", do: "sorting", else: "labelling")
    assert_receive {:reconcile, "crate", ^key}, 2_000
    reconcile(c, key)
  end

  test "Flow makes the proposed items under the crate, numbered after those there are", c do
    FakeFacts.put("item", %{"key" => "IT-07", "values" => %{"title" => "An older item"}})
    run = intended(c, "C-1")
    assert run["pending"]["task"]["work"]["instructions"] =~ "items.json"

    proposal = [%{"title" => "One", "description" => "The first."}, %{"title" => "Two"}]
    sorted = finish(c, "C-1", [{"items.json", JSON.encode!(proposal)}])
    assert {sorted["state"], sorted["status"]} == {"sorted", "completed"}

    one = FakeFacts.get("item", "IT-08")
    assert one["values"] == %{"title" => "One", "description" => "The first."}
    assert one["links"]["in_crate"] == ["C-1"]
    assert FakeFacts.get("item", "IT-09")["values"] == %{"title" => "Two"}
    assert FakeFacts.get("item", "IT-10") == nil
  end

  test "a task that proposes nothing ends stuck, and nothing is made", c do
    intended(c, "C-2")
    stuck = finish(c, "C-2", [{"notes.txt", "nothing to propose\n"}])
    assert stuck["state"] == "stuck"
    assert [%{"outcome" => "completed", "reason" => "no proposal"}] = stuck["pending"]["tasks"]
    assert FakeFacts.get("item", "IT-01") == nil
  end

  test "Flow puts the written text in the crate's field (writes)", c do
    run = intended(c, "C-3", "second")
    assert run["pending"]["task"]["work"]["instructions"] =~ "note.md"

    labelled = finish(c, "C-3", [{"note.md", "# Fragile\n\nHandle with care.\n"}], "second")
    assert {labelled["state"], labelled["status"]} == {"labelled", "completed"}
    assert FakeFacts.get("crate", "C-3")["values"]["note"] == "# Fragile\n\nHandle with care."
  end
end
