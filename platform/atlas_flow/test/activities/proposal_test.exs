defmodule AtlasFlow.Activities.ProposalTest.Bench do
  @moduledoc """
  A neutral model of a task that proposes facts (slice 7): a crate is sorted by a robot (a
  machinery kind) whose agent proposes the crate's items in a file of its result; Flow
  makes them under the crate (`in_crate`, the item's parent relation). Labelled, its agent
  writes the crate's note instead (slice 9). Asked, its agent may write its questions about
  the crate instead of proposing its items (`asks`). Checked, an item is reviewed, and its
  review's follow-ups become new items beside it, in its crate (`follow_ups`). A clerk
  supervises the run, and is the producer of the items it makes (`made_by`, the model's
  `producer`).
  """
  use RelaDSL.Composition,
    name: "proposal",
    subflow_behaviour: AtlasFlow.Subflow

  @behaviour AtlasFlow.Model

  defmodule Desk do
    @moduledoc "The crates, their items and robots, who supervises their runs, and the slips."
    use RelaDSL

    type(:slip_operation, values: [:choice, :pickup, :hand_over, :retry])

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
      field(:questions, :string)
      field(:suggestions, :string)
      field(:designed_suggestions, :string)
      field(:snapshot_known, :boolean)
    end

    entity :item, label: "Item", plural: "items", id_type: :manual, id_prefix: "IT-" do
      field(:title, :string)
      field(:description, :string)
      field(:size, :string)
      field(:proposal_id, :string, unique: true, set_by: [:flow])
      field(:origin, :string)
      field(:phase, :string)
      field(:task_result, :string)
    end

    relation(:owned_by,
      label: "owned by",
      from: [:crate, :item],
      to: [:robot, :clerk],
      max_outgoing: 1
    )

    relation(:in_crate,
      label: "in crate",
      from: [:item],
      to: [:crate],
      max_outgoing: 1,
      parent: true
    )

    entity :cursor, label: "Cursor", plural: "cursors", id_type: :manual do
      for f <- ~w(flow subject_kind subject_key state entered_at status
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

    # An item's producer: the clerk who supervised the run that made it.
    relation(:made_by,
      label: "made by",
      from: [:item],
      to: [:clerk],
      max_outgoing: 1,
      set_by: [:flow]
    )

    producer(relation: :made_by)

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
          fields: [:title, :suggestions],
          snapshot: [field: :suggestions, into: :designed_suggestions, known: :snapshot_known],
          creates: [kind: :item, file: "items.json", fields: [:size], values: [origin: "robot"], identity: :proposal_id],
          records: [kind: "task", relation: "task_of"],
          machinery: "robot",
          on: [completed: :sorted, check_failed: :sorted, stuck: :stuck, abandoned: :stuck]
        )
      end

      final :sorted do
        set(phase: "sorted")
      end
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

    subflow :ask, label: "Ask", subject: :crate do
      run_as("system:proposal")
      owner(relation: :owned_by, default: {:clerk, :desk})
      start(:predicate, when: "entity.phase == 'third'")
      initial(:asking)
      supervise(:query, label: "Query", states: [:asking])

      state :asking do
        task(:plan,
          role: :architect,
          profile: :deep_coding,
          input: [repository: "example.org/acme/proposal", base: "develop"],
          instructions: "Sort the crate, or ask.",
          fields: [:title, :suggestions],
          snapshot: [field: :suggestions, into: :designed_suggestions, known: :snapshot_known],
          creates: [kind: :item, file: "items.json", identity: :proposal_id],
          asks: [field: :questions, file: "questions.md"],
          records: [kind: "task", relation: "task_of"],
          machinery: "robot",
          on: [
            completed: :sorted,
            check_failed: :sorted,
            stuck: :stuck,
            abandoned: :stuck,
            asked: :asked
          ]
        )
      end

      final(:sorted)
      final(:stuck)
      final(:asked)
    end

    select(:ask, admission: [phase: [:third]], imports: [])

    subflow :check, label: "Check", subject: :item do
      run_as("system:proposal")
      owner(relation: :owned_by, default: {:clerk, :desk})
      start(:predicate, when: "entity.phase == 'check'")
      initial(:checking)
      supervise(:inspect, label: "Inspect", states: [:checking])

      state :checking do
        task(:review,
          role: :architect,
          profile: :deep_coding,
          input: [repository: "example.org/acme/proposal", base: "develop"],
          instructions: "Review the item.",
          fields: [:title],
          follow_ups: :item,
          records: [kind: "task", relation: "task_of"],
          machinery: "robot",
          on: [completed: :checked, check_failed: :checked, stuck: :stuck, abandoned: :stuck]
        )
      end

      final(:checked)
      final(:stuck)
    end

    select(:check, admission: [phase: [:check]], imports: [])
  end

  defmodule Crates do
    @moduledoc "The proposal model's one module."
    use RelaDSL.Module, path: "modules/crates/schema.yaml", concepts: [Desk]
  end

  schema(version: "1.0", namespace: "https://example.invalid/proposal#", description: "Crates.\n")
  modules([Crates])
  environments([:prod, :test])

  acl(comment: "The proposal's roles.")
  role("proposal", read: ["*"], create: [:cursor, :item], update: [:crate, :cursor, :item])
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
  UC-Atlas-24: one that may ask (`asks`) and whose result has its questions has Flow put
  them in the subject's field, makes nothing and ends `asked`. SC-Atlas-09: what a proposal
  makes is linked to its producer, the run's supervisor (the model's `producer` relation).
  UC-Atlas-23: so are the items a review's follow-ups make (`follow_ups`), and nothing is
  made with an empty producer: while the run has no supervisor, they wait for one.
  The real Dispatch, Delivery and Bases (on `FakeCode`), with `FakeFacts` and a manual clock.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Bases, Delivery, Dispatch, FakeCode, FakeFacts, ManualClock}
  alias AtlasFlow.WorkSource
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

  defp flow("first"), do: "sort"
  defp flow("second"), do: "label"
  defp flow("third"), do: "ask"

  defp working("first"), do: "sorting"
  defp working("second"), do: "labelling"
  defp working("third"), do: "asking"

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
  defp intended(c, key, phase \\ "first", suggestions \\ nil) do
    FakeFacts.put("crate", %{
      "key" => key,
      "values" => %{"phase" => phase, "title" => "Crate #{key}", "suggestions" => suggestions},
      "links" => %{"owned_by" => ["mini"]},
      "origins" => %{"owned_by" => %{"by" => "someone", "position" => 1}}
    })

    if reconcile(c, key)["pending"]["task"] == nil,
      do: assert_receive({:reconcile, "crate", ^key}, 2_000)

    flow = flow(phase)
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
  defp finish(c, key, files, phase \\ "first", lose_ack \\ nil) do
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
    assert reconcile(c, key)["state"] == working(phase)
    assert_receive {:reconcile, "crate", ^key}, 2_000
    if lose_ack do
      FakeFacts.lose_ack(lose_ack)
      {:ok, %{runs: known}} = Store.plan(c.runner.config, c.runner.flows)
      Store.reconcile_subjects(c.runner.config, c.runner.flows, AtlasFlow.Runs.Clock.now(c.clock), known, [{"crate", key}])
    else
      reconcile(c, key)
    end
  end

  test "the proposal records the exact frozen input, even after the subject changes", c do
    run = intended(c, "C-20", "first", "  first\n")
    assert run["pending"]["task"]["snapshot"] == %{"value" => "  first\n"}
    crate = FakeFacts.get("crate", "C-20")
    FakeFacts.put("crate", put_in(crate, ["values", "suggestions"], "later"))

    finish(c, "C-20", [{"items.json", ~s([{"title":"One"}])}])
    values = FakeFacts.get("crate", "C-20")["values"]
    assert values["suggestions"] == "later"
    assert values["designed_suggestions"] == "  first\n"
    assert values["snapshot_known"] == true
  end

  test "nil is a known snapshot and an empty proposal can complete", c do
    run = intended(c, "C-21")
    assert run["pending"]["task"]["snapshot"] == %{"value" => nil}
    sorted = finish(c, "C-21", [{"items.json", "[]"}])
    assert sorted["state"] == "sorted"
    values = FakeFacts.get("crate", "C-21")["values"]
    assert Enum.any?(FakeFacts.sent(), fn w ->
      w["key"] == "C-21" and w["values"] == %{"designed_suggestions" => nil, "snapshot_known" => true}
    end)
    assert values["designed_suggestions"] == nil
    assert values["snapshot_known"] == true
  end

  test "a legacy intent marks the snapshot unknown", c do
    run = intended(c, "C-22", "first", "old")
    fact = FakeFacts.get(c.runner.config["kind"], run["key"])
    pending = JSON.decode!(fact["values"]["pending"])
    pending = update_in(pending, ["task"], &Map.delete(&1, "snapshot"))
    FakeFacts.put(c.runner.config["kind"], put_in(fact, ["values", "pending"], JSON.encode!(pending)))

    finish(c, "C-22", [{"items.json", "[]"}])
    assert FakeFacts.get("crate", "C-22")["values"]["snapshot_known"] == false
  end

  test "a lost create acknowledgement replays the durable outbox before snapshot", c do
    run = intended(c, "C-23", "first", "frozen")
    assert {:error, _} = finish(c, "C-23", [{"items.json", ~s([{"title":"One"}])}], "first", "item")
    fact = FakeFacts.get(c.runner.config["kind"], run["key"])
    {:ok, stored} = Store.decode(c.runner.config, fact)
    writes = stored["pending"]["writes"]
    create = Enum.find_index(writes, &(&1["kind"] == "item"))
    snapshot = Enum.find_index(writes, &(get_in(&1, ["content", "values", "snapshot_known"]) == true))
    destination = Enum.find_index(writes, &(get_in(&1, ["content", "values", "phase"]) == "sorted"))
    assert is_integer(destination) and snapshot < destination
    assert is_integer(create) and is_integer(snapshot) and create < snapshot
    assert Enum.at(writes, snapshot)["content"]["values"]["designed_suggestions"] == "frozen"

    reconcile(c, "C-23")
    assert FakeFacts.get("crate", "C-23")["values"]["snapshot_known"] == true
    assert FakeFacts.get("item", "IT-01")["values"]["title"] == "One"
    assert FakeFacts.get("item", "IT-02") == nil
    assert Enum.count(FakeFacts.stored_from_flow(), &(&1["key"] == "IT-01")) == 1
  end

  test "an identical stranger at a newly allocated key is not adopted", c do
    intended(c, "C-24", "first", "frozen")
    FakeFacts.hook("item", "IT-01", "flow", :before, fn _ ->
      %{"key" => "IT-01", "values" => %{"title" => "One", "origin" => "robot", "proposal_id" => "another"},
        "links" => %{"in_crate" => ["C-24"], "made_by" => ["ada"]}, "origins" => %{}}
    end)
    sorted = finish(c, "C-24", [{"items.json", ~s([{"title":"One"}])}])
    assert FakeFacts.get("item", "IT-01")["values"]["proposal_id"] == "another"
    assert FakeFacts.get("item", "IT-02")["values"]["proposal_id"] != "another"
    assert [%{"made" => [["item", "IT-02"]]}] = sorted["pending"]["tasks"]
  end

  test "Flow makes the proposed items under the crate, numbered after those there are", c do
    FakeFacts.put("item", %{"key" => "IT-07", "values" => %{"title" => "An older item"}})
    run = intended(c, "C-1")
    assert run["pending"]["task"]["work"]["instructions"] =~ "items.json"

    # Each item with the texts the creates' fields name (others are dropped), and its values.
    proposal = [
      %{"title" => "One", "description" => "The first.", "size" => "L", "colour" => "red"},
      %{"title" => "Two"}
    ]

    sorted = finish(c, "C-1", [{"items.json", JSON.encode!(proposal)}])
    assert {sorted["state"], sorted["status"]} == {"sorted", "completed"}

    one = FakeFacts.get("item", "IT-08")

    assert Map.delete(one["values"], "proposal_id") == %{
             "title" => "One",
             "description" => "The first.",
             "size" => "L",
             "origin" => "robot"
           }

    assert run["pending"]["task"]["work"]["instructions"] =~ "its `size`"
    assert one["links"]["in_crate"] == ["C-1"]
    assert Map.delete(FakeFacts.get("item", "IT-09")["values"], "proposal_id") == %{"title" => "Two", "origin" => "robot"}
    assert is_binary(one["values"]["proposal_id"])
    refute one["values"]["proposal_id"] == FakeFacts.get("item", "IT-09")["values"]["proposal_id"]

    # Each is produced by the run's supervisor, ada, in the same create, by Flow.
    for key <- ["IT-08", "IT-09"],
        do: assert(FakeFacts.get("item", key)["links"]["made_by"] == ["ada"])

    assert FakeFacts.get("item", "IT-07")["links"]["made_by"] == nil

    assert [%{"by" => "flow", "links" => %{"made_by" => ["ada"], "in_crate" => ["C-1"]}} | _] =
             for(w <- FakeFacts.stored_from_flow(), w["key"] == "IT-08", do: w)

    assert FakeFacts.get("item", "IT-10") == nil
  end

  test "a key held back after a delete is skipped: the proposal is made past it (IS-Atlas-38)",
       c do
    # IT-08 was deleted a moment ago: Facts lists only IT-07, but holds IT-08 back.
    FakeFacts.put("item", %{"key" => "IT-07", "values" => %{"title" => "An older item"}})
    FakeFacts.reserve("item", "IT-08")
    intended(c, "C-7")

    proposal = [%{"title" => "One"}, %{"title" => "Two"}]
    sorted = finish(c, "C-7", [{"items.json", JSON.encode!(proposal)}])

    # Not blocked on the held-back key: both made after it, in their order.
    assert {sorted["state"], sorted["status"]} == {"sorted", "completed"}
    assert sorted["pending"]["writes"] == []
    assert FakeFacts.get("item", "IT-08") == nil
    assert FakeFacts.get("item", "IT-09")["values"]["title"] == "One"
    assert FakeFacts.get("item", "IT-10")["values"]["title"] == "Two"
    assert FakeFacts.get("item", "IT-09")["links"]["in_crate"] == ["C-7"]

    # The task's result names the keys they were made under, so a discard deletes those.
    assert [%{"made" => [["item", "IT-09"], ["item", "IT-10"]]}] = sorted["pending"]["tasks"]
  end

  test "a task that proposes nothing ends stuck, and nothing is made", c do
    intended(c, "C-2")
    stuck = finish(c, "C-2", [{"notes.txt", "nothing to propose\n"}])
    assert stuck["state"] == "stuck"
    assert [%{"outcome" => "completed", "reason" => "no proposal"}] = stuck["pending"]["tasks"]
    assert FakeFacts.get("item", "IT-01") == nil
    refute Map.has_key?(FakeFacts.get("crate", "C-2")["values"], "snapshot_known")
  end

  test "Flow puts the written text in the crate's field (writes)", c do
    run = intended(c, "C-3", "second")
    assert run["pending"]["task"]["work"]["instructions"] =~ "note.md"

    labelled = finish(c, "C-3", [{"note.md", "# Fragile\n\nHandle with care.\n"}], "second")
    assert {labelled["state"], labelled["status"]} == {"labelled", "completed"}
    assert FakeFacts.get("crate", "C-3")["values"]["note"] == "# Fragile\n\nHandle with care."
  end

  test "questions instead of a proposal: Flow puts them in the crate's field, makes nothing, and the task ends asked",
       c do
    run = intended(c, "C-4", "third")
    instructions = run["pending"]["task"]["work"]["instructions"]
    assert instructions =~ "items.json"
    assert instructions =~ "too vague to propose from"
    assert instructions =~ "`questions.md`"

    questions = "1. Which crates are fragile?\n2. Who labels them?\n"
    # Questions win over a proposal written beside them: nothing of it is made.
    files = [{"questions.md", questions}, {"items.json", JSON.encode!([%{"title" => "One"}])}]
    asked = finish(c, "C-4", files, "third")
    assert {asked["state"], asked["status"]} == {"asked", "completed"}
    assert [%{"outcome" => "completed"} = task] = asked["pending"]["tasks"]
    refute Map.has_key?(task, "made")
    refute Map.has_key?(task, "reason")

    crate = FakeFacts.get("crate", "C-4")
    assert crate["values"]["questions"] == String.trim(questions)
    refute Map.has_key?(crate["values"], "snapshot_known")
    assert FakeFacts.get("item", "IT-01") == nil

    # Flow wrote them, for the run's supervisor; the agent wrote nothing into Atlas.
    assert [write] =
             for(w <- FakeFacts.stored_from_flow(), w["values"]["questions"] != nil, do: w)

    assert write["by"] == "flow"
    assert write["cause"] == "For ada: asked by TK-C-4-1"
  end

  test "with no questions, or empty ones, a task that may ask ends as before", c do
    intended(c, "C-5", "third")

    files = [{"questions.md", "  \n"}, {"items.json", JSON.encode!([%{"title" => "One"}])}]
    sorted = finish(c, "C-5", files, "third")
    assert {sorted["state"], sorted["status"]} == {"sorted", "completed"}
    assert FakeFacts.get("item", "IT-01")["links"]["in_crate"] == ["C-5"]
    assert FakeFacts.get("crate", "C-5")["values"]["questions"] == nil

    intended(c, "C-6", "third")
    stuck = finish(c, "C-6", [{"notes.txt", "nothing\n"}], "third")
    assert stuck["state"] == "stuck"
    assert [%{"reason" => "no proposal"}] = stuck["pending"]["tasks"]
  end

  # -- A review's follow-ups (UC-Atlas-23) ------------------------------------------------

  defp reconcile_item(c, key) do
    {:ok, %{runs: known}} = Store.plan(c.runner.config, c.runner.flows)
    now = AtlasFlow.Runs.Clock.now(c.clock)

    {:ok, runs} =
      Store.reconcile_subjects(c.runner.config, c.runner.flows, now, known, [{"item", key}])

    assert [run] = Enum.filter(runs, &(&1["subject_key"] == key))
    run
  end

  defp watched_by(c, key, clerks) do
    run_key = AtlasFlow.Runs.Run.key("check", "item", key, 1)
    fact = FakeFacts.get(c.runner.config["kind"], run_key)
    links = Map.put(fact["links"] || %{}, "watched_by", clerks)
    FakeFacts.put(c.runner.config["kind"], Map.merge(fact, %{"links" => links}))
  end

  # An item in crate C-9 to check, on the mini, supervised by ada, whose run holds its
  # review's intent.
  defp checking(c, key) do
    FakeFacts.put("crate", %{"key" => "C-9", "values" => %{"title" => "Crate C-9"}})

    FakeFacts.put("item", %{
      "key" => key,
      "values" => %{"phase" => "check", "title" => "Item #{key}"},
      "links" => %{"in_crate" => ["C-9"], "owned_by" => ["mini"]},
      "origins" => %{"owned_by" => %{"by" => "someone", "position" => 1}}
    })

    if reconcile_item(c, key)["pending"]["task"] == nil,
      do: assert_receive({:reconcile, "item", ^key}, 2_000)

    watched_by(c, key, ["ada"])
    run = reconcile_item(c, key)
    assert %{"version" => 2} = run["pending"]["task"]
    assert run["pending"]["task"]["work"]["instructions"] =~ ~s("follow_ups")
    run
  end

  # The review leased and ended with `answer` (`before` just before it ended); the run
  # reconciled. A review reads its base, and writes no result to wait for.
  defp reviewed(c, key, answer, before \\ fn -> :ok end) do
    {id, _} = @mini

    assert {:polled, %{leases: [%{lease_id: lease}]}} =
             WorkSource.poll(@mini, L.poll_input(id, [], %{"deep_coding" => 1}))

    FakeCode.put(c.code, @repository, "refs/atlas/results/TK-#{key}-1", "rev_#{key}", %{
      "README.md" => "# Proposal\n"
    })

    report = &WorkSource.report(@mini, %{lease_id: lease, revision: &1, report: &2})
    assert {:recorded, _} = report.(1, %{state: :accepted})
    assert {:recorded, _} = report.(2, %{state: :started})
    before.()
    assert {:recorded, _} = report.(3, L.ended(nil, answer: answer))
    assert_receive {:"$gen_cast", {:reconcile, "item", ^key}}
    reconcile_item(c, key)
  end

  defp review(follow_ups),
    do:
      "Looked at it.\n\n```json\n" <>
        JSON.encode!(%{"verdict" => "approved", "findings" => [], "follow_ups" => follow_ups}) <>
        "\n```\n"

  test "a review's follow-ups are new items in the crate, produced by the run's supervisor", c do
    checking(c, "IT-01")
    answer = review([%{"title" => "Wrap it", "description" => "It scratches."}])
    checked = reviewed(c, "IT-01", answer)
    assert {checked["state"], checked["status"]} == {"checked", "completed"}

    made = FakeFacts.get("item", "IT-02")
    assert made["values"] == %{"title" => "Wrap it", "description" => "It scratches."}
    assert made["links"] == %{"in_crate" => ["C-9"], "made_by" => ["ada"]}

    # In the same create, by Flow for ada, the review in its cause.
    assert [
             %{
               "by" => "flow",
               "cause" => "For ada: proposed by TK-IT-01-1 in the review of IT-01"
             }
           ] =
             for(w <- FakeFacts.stored_from_flow(), w["key"] == "IT-02", do: w)
  end

  test "a review whose run has no supervisor makes no follow-up until it has one", c do
    checking(c, "IT-05")
    answer = review([%{"title" => "Wrap it"}])

    # Its supervisor lets go while the review runs: its follow-up is not made producerless.
    waiting = reviewed(c, "IT-05", answer, fn -> watched_by(c, "IT-05", []) end)
    assert waiting["state"] == "checking"
    assert FakeFacts.get("item", "IT-06") == nil
    refute Enum.any?(FakeFacts.stored_from_flow(), &(&1["key"] == "IT-06"))

    # Once ada supervises it again, the follow-up is made, produced by ada.
    watched_by(c, "IT-05", ["ada"])
    checked = reconcile_item(c, "IT-05")
    assert checked["state"] == "checked"
    assert FakeFacts.get("item", "IT-06")["links"]["made_by"] == ["ada"]
  end
end
