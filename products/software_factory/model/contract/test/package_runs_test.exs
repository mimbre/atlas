defmodule Model.PackageRunsTest do
  @moduledoc """
  The package subflow on Flow's durable runs, through the composition: F1.4 on the lease
  path (M3 A4) and the review → fix loop (F2-P; F2/F3 plan rev 3 §3.3, Main's B-3). A
  package waits for its instructions, then each task (author, review, fix, diagnose, a
  fresh or a stronger author) is a step of `AtlasFlow.Ladder` for the machinery its
  Assignment names, offered through Flow's work source to a Runtime of its issue's human
  supervisor. Its end leads where the ladder says: another task, `ready`, `held` or
  `awaiting_decision`. In every task state the machinery keeps the package; `held` and
  `awaiting_decision` move it to the supervisor, who sets `answer` and hands it back. It
  is run by `AtlasFlow.Runs.Store` as the composition selects it, with
  `AtlasFlow.FakeFacts`, the work source's processes (Dispatch, Delivery, the result
  store, Bases on `AtlasFlow.FakeCode`) and a manual clock, and presented on its
  Assignment (`AtlasFlow.Runs.Projection`). Structure, not wording.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.{Bases, Delivery, Dispatch, FakeCode, FakeFacts, ManualClock, Results}
  alias AtlasFlow.WorkSource
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.Runs.{Projection, Run, Store}
  alias AtlasFlow.WorkSource.Translate

  @now ~U[2026-11-17 09:00:00Z]
  @envs [:prod, :test]
  @name "package"
  @key "PK-IS-Atlas-01-1"
  @task "TK-PK-IS-Atlas-01-1-1"
  @issue "IS-Atlas-01"
  @repository "github.com/mimbre/atlas"
  @actors %{"decider" => "someone"}
  # The Runtime on the machinery the package is assigned to, its holder the supervisor.
  @mini {"mac-mini", "ada"}
  @offer %{"deep_coding" => 2, "independent_review" => 2, "deep_coding_max" => 1}
  @task_states ~w(authoring reviewing fixing diagnosing fresh stronger)
  @steps %{
    "author" => "authoring",
    "review" => "reviewing",
    "fix" => "fixing",
    "diagnose" => "diagnosing",
    "fresh" => "fresh",
    "stronger" => "stronger",
    "ready" => "ready",
    "held" => "held",
    "escalate" => "awaiting_decision",
    "abandon" => "stuck"
  }
  @author [{"parser.ex", "defmodule Parser do\nend\n"}]
  @fixed [{"parser.ex", "defmodule Parser do\nend\n"}, {"parser_test.exs", "# test\n"}]
  # The environment needs access, and the supervisor must choose (rung e).
  @needs_access %{
    "cause" => "environment",
    "evidence" => "the machinery cannot reach the registry",
    "advice" => "grant it the registry",
    "needs" => "access",
    "decision" => %{
      "question" => "Grant the machinery the registry?",
      "rationale" => "it cannot build without it",
      "options" => [
        %{
          "id" => "grant",
          "text" => "grant it",
          "details" => "the registry",
          "rule" => "only this registry",
          "consequences" => "it can build"
        }
      ],
      "safe_to_continue" => false,
      "touches" => ["credentials"]
    }
  }

  defp flow(env), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == @name))
  defp runner, do: AtlasFlow.Model.load(Model.AtlasEyra, :test, @actors)

  describe "the definition" do
    test "selected in both environments, runnable: the loop's states, stuck its one end" do
      for env <- @envs do
        runner = AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"})
        assert runner.refusal == nil
        assert Map.has_key?(runner.config["selection"], @name)

        f = flow(env)
        assert Run.validate(f) == :ok
        assert f.subject() == "package"
        assert f.initial() == "waiting"

        assert Enum.sort(f.states()) ==
                 ~w(authoring awaiting_decision diagnosing fixing fresh held ready reviewing stronger stuck waiting)

        # ready, held and awaiting_decision are not final: only stuck ends a package.
        assert Enum.filter(f.states(), &f.final?/1) == ~w(stuck)
        assert f.mechanism("waiting") == nil
        assert Enum.all?(f.states(), &(f.timers(&1) == []))

        # waiting: on to authoring once it has its instructions, and not before.
        assert f.next("waiting", %{"title" => "Build it"}, nil) == :stay
        assert f.next("waiting", %{"instructions" => ""}, nil) == :stay
        assert f.next("waiting", %{"instructions" => "Do it."}, nil) == {:to, "authoring"}

        # Every task state: each ladder step leads to its own state.
        for state <- @task_states, {step, to} <- @steps do
          assert f.next(state, %{"task_result" => step}, :result) == {:to, to}, "#{state} #{step}"
        end
      end
    end

    test "each answer leads to its state: fresh or a worded option, stronger, abandon (stuck)" do
      for env <- @envs, state <- ~w(held awaiting_decision) do
        f = flow(env)

        for {answer, to} <- [
              {"fresh", {:to, "fresh"}},
              {"grant", {:to, "fresh"}},
              {"stronger", {:to, "stronger"}},
              {"abandon", {:to, "stuck"}},
              {"retry", :stay},
              {"none", :stay},
              {"", :stay}
            ] do
          assert f.next(state, %{"answer" => answer}, nil) == to, "#{state} #{answer}"
        end

        # No answer yet: it waits.
        assert f.next(state, %{}, nil) == :stay

        # retry (D3): from held, to the state of the step Flow wrote in retry_step; with
        # none (retry not offered), or from awaiting_decision (rung (e) offers no retry), it
        # stays.
        for {step, to} <- Map.take(@steps, ~w(author review fix diagnose fresh stronger)) do
          want = if state == "held", do: {:to, to}, else: :stay

          assert f.next(state, %{"answer" => "retry", "retry_step" => step}, nil) == want,
                 "#{state} retry #{step}"

          # Only the answer retry reads it.
          assert f.next(state, %{"answer" => "none", "retry_step" => step}, nil) == :stay
        end

        assert f.next(state, %{"answer" => "retry", "retry_step" => "none"}, nil) == :stay
        # Entering it resets the answer to none, so an earlier one is never taken again.
        assert f.enter(state, %{"answer" => "fresh"}) == [{:set, %{"answer" => "none"}}]
      end

      # ready waits for F3; its supervisor may abandon it, and nothing else moves it.
      for env <- @envs do
        f = flow(env)
        assert f.next("ready", %{"answer" => "abandon"}, nil) == {:to, "stuck"}
        assert f.next("ready", %{"answer" => "fresh"}, nil) == :stay
        assert f.next("ready", %{}, nil) == :stay
      end
    end

    test "each task is a ladder step: its kind, role, profile, input and check" do
      for env <- @envs do
        specs =
          for state <- @task_states, into: %{} do
            assert {:task, spec} = flow(env).mechanism(state)
            {state, spec}
          end

        for {_state, spec} <- specs do
          assert spec["ladder"] == true
          assert spec["fields"] == ["title", "instructions", "acceptance"]
          assert spec["records"] == %{"kind" => "task", "relation" => "task_of"}
          assert spec["machinery"] == "machinery"
          assert spec["field"] == "task_result"
          assert AtlasFlow.Activities.Task.valid?(spec)
        end

        author = %{"repository" => @repository, "base" => "develop"}
        latest = fn access -> %{"result" => "latest", "access" => access} end

        assert Map.new(specs, fn {state, spec} ->
                 {state,
                  {spec["kind"], spec["role"], spec["profile"], spec["cost_class"], spec["input"],
                   spec["check"]}}
               end) == %{
                 "authoring" =>
                   {"author", "developer", "deep_coding", "standard", author, ["bin/check"]},
                 "reviewing" =>
                   {"review", "developer", "independent_review", "standard", latest.("read"), nil},
                 "fixing" =>
                   {"fix", "developer", "deep_coding", "standard", latest.("write"),
                    ["bin/check"]},
                 "diagnosing" =>
                   {"diagnose", "investigator", "deep_coding", "standard", latest.("read"), nil},
                 "fresh" =>
                   {"author", "developer", "deep_coding", "standard", author, ["bin/check"]},
                 "stronger" =>
                   {"author", "developer", "deep_coding_max", "high", author, ["bin/check"]}
               }

        # The authors' standard text: the worker rules, the affected tests, the answer's end.
        for state <- ~w(authoring fresh stronger fixing) do
          text = specs[state]["instructions"]
          assert text =~ "boundary greps"
          assert text =~ "no web search"
          assert text =~ "Run the tests of every system you change."
          assert text =~ "End your answer with"
        end
      end
    end

    test "owners (B-3): the machinery stays in every task state; held and awaiting_decision go to the supervisor" do
      for env <- @envs do
        f = flow(env)
        decider = %{"kind" => "person", "config" => "decider"}

        assert Map.take(f.owner(), ~w(via relation default preserve_kind)) == %{
                 "via" => "assignment",
                 "relation" => "assigned_to",
                 "default" => decider,
                 "preserve_kind" => ["person", "machinery"]
               }

        for state <- @task_states ++ ~w(waiting ready), do: assert(f.owner(state) == f.owner())

        for state <- ~w(held awaiting_decision) do
          owner = f.owner(state)

          assert Map.take(owner, ~w(via relation default)) ==
                   Map.take(f.owner(), ~w(via relation default))

          assert owner["preserve_kind"] in [nil, []]
        end

        # Every task state, held and awaiting_decision present: so entering each is a move.
        for state <- @task_states ++ ~w(held awaiting_decision) do
          assert %{"expected" => expected} = f.present(state, %{})
          assert is_binary(expected) and expected != "", state
        end

        assert f.present("waiting", %{}) == nil
        assert f.present("ready", %{}) == nil
        assert f.present("stuck", %{}) == nil
      end

      # The issue's span names the package's and the pull request's runs.
      assert [%{"name" => "build", "with" => with}] =
               Model.AtlasEyra.supervision()["spans"]["issue"]

      assert Enum.sort(with) == ~w(package pull_request)
    end

    test "presented on its Assignment, in plain texts; waiting presents nothing" do
      s = Model.AtlasEyra.selection(@name)
      assert s["subject"] == "package"
      assert s["imports"] == []
      assert s["admission"] == []

      assert Map.take(s["projection"], ~w(on owner_relation state_field field)) == %{
               "on" => "assignment",
               "owner_relation" => "assigned_to",
               "state_field" => "flow_state",
               "field" => "expected"
             }

      flows = Model.AtlasEyra.__flows__()
      package = Enum.find(flows, &(&1.name == :package))
      states = Map.new(package.states, &{&1.name, &1})
      assert states[:waiting].present == nil
      present = states[:authoring].present

      # Plain: no field filled in, no markup; a text a person or the TUI shows as it is.
      for text <- [present.expected, present.why, present.instructions] do
        assert is_binary(text) and text != ""
        refute text =~ ~r/[{}<>`*#]/, text
      end

      assert present.expected == "Author it on the machinery"
      assert present.answers == []
    end

    test "a package's assignment may name a machinery; its task belongs to it" do
      schema = Model.AtlasEyra.rela_schema()
      assert "package" in schema["relations"]["assignment"]["from"]
      assert "machinery" in schema["relations"]["assigned_to"]["to"]
      assert "package" in schema["relations"]["task_of"]["to"]
      # What its task branches read: the run's own result, Flow's alone.
      assert schema["entities"]["package"]["properties"]["task_result"]["type"] == "string"
    end
  end

  describe "through the run store" do
    setup :work_source

    test "the state path (acc. 1): author, review, approved, ready; the machinery keeps it in every task state",
         c do
      issue_run(c, "ada")
      package(@key, "mac-mini")

      # Its base is asked of Code first; once Bases has it, the intent is made.
      assert reconcile(c)["pending"]["task"] == nil
      assert_receive {:reconcile, "package", @key}, 2_000
      {:ok, base} = Bases.cached(@repository, "develop")
      authoring = reconcile(c)
      assert {authoring["state"], authoring["status"]} == {"authoring", "active"}

      # Its issue is picked up: the task is the supervisor's, and names no machinery.
      assert %{"version" => 2, "key" => @task, "machinery" => nil} =
               intent = authoring["pending"]["task"]

      # The task record, intent first, belongs to the package.
      record = FakeFacts.get("task", @task)
      assert record["links"]["task_of"] == [@key]

      assert Map.take(record["values"], ~w(kind role profile client_key state)) == %{
               "kind" => "author",
               "role" => "developer",
               "profile" => "deep_coding",
               "client_key" => @task,
               "state" => "waiting"
             }

      assert JSON.decode!(record["values"]["input"]) == %{
               "repository" => @repository,
               "base" => "develop"
             }

      # Offered to the issue's supervisor's Runtime: the base, bin/check after it.
      assert {:polled, %{leases: [%{lease_id: lease, work: work}]}} = poll(@mini)
      assert work == Translate.offered_work(intent)
      assert work.work_key == @task
      assert work.input.base == %{base_id: base.base_id, manifest: base.manifest}
      assert work.after_check == %{command: ["atlas/bin/check"]}
      assert {work.profile, work.cost_class} == {"deep_coding", "standard"}
      assert work.title == "author " <> @key
      assert work.instructions =~ ~r/\ABuild the package below/

      assert work.instructions =~
               "\n\n## title\n\nThe parser\n\n## instructions\n\nWrite the parser.\n\n## acceptance\n\nIt parses."

      refute Enum.any?(Map.keys(work), &(&1 in [:repository, :folder, :slot, :resume_from]))

      # Presented on its Assignment; the machinery it was handed to keeps it.
      assert {:ok, _} = Projection.project(c.runner, "package", @key)
      assignment = FakeFacts.get("assignment", "AS-" <> @key)
      assert assignment["values"]["flow_state"] == "authoring"
      assert assignment["values"]["expected"] == "Author it on the machinery"
      assert owner(@key) == ["mac-mini"]

      finish(@key, files: @author, check: 0, lease: {lease, work})

      # The review: new work, read-only, on the author's base with the author's change set.
      reviewing = settle(c)
      assert FakeFacts.get("task", @task)["values"]["state"] == "completed"
      # Its attempt ran on the machinery the Runtime's id names.
      assert FakeFacts.get("task_attempt", "TA-#{@task}-1")["links"]["ran_on"] == ["mac-mini"]
      assert {reviewing["state"], reviewing["status"]} == {"reviewing", "active"}
      assert %{"key" => review} = reviewing["pending"]["task"]
      assert review != @task
      assert FakeFacts.get("task", review)["values"]["kind"] == "review"
      assert reviewing["pending"]["task"]["work"]["input"]["base"]["base_id"] == base.base_id
      assert reviewing["pending"]["task"]["work"]["input"]["permissions"] == "read-only"
      assert flow_state(@key) == "reviewing"
      assert owner(@key) == ["mac-mini"]

      finish(@key, answer: verdict("approved"))
      ready = settle(c)
      assert {ready["state"], ready["status"]} == {"ready", "active"}
      assert ready["pending"]["task"] == nil
      assert Enum.map(ready["pending"]["tasks"], & &1["task_kind"]) == ~w(author review)
      assert FakeFacts.get("task", review)["values"]["verdict"] == "approved"

      # Ready presents nothing: nothing is expected of anyone, and the machinery keeps it.
      values = FakeFacts.get("assignment", "AS-" <> @key)["values"]
      assert values["flow_state"] == "ready" and values["expected"] in [nil, ""]
      assert owner(@key) == ["mac-mini"]
      assert decisions() == []
    end

    test "changes required (acc. 2): a fix of the reviewed change set, then its review, then ready",
         c do
      issue_run(c, "ada")
      started(c)
      finish(@key, files: @author, check: 0)
      assert settle(c)["state"] == "reviewing"
      finish(@key, answer: verdict("changes_required", [%{"text" => "add a test"}]))

      fixing = settle(c)
      assert fixing["state"] == "fixing"
      fix = fixing["pending"]["task"]
      assert fix["work"]["input"]["permissions"] == "workspace-write"
      assert fix["work"]["after_check"] == %{"command" => ["atlas/bin/check"]}
      # The change set it fixes is the author's (never the review's).
      author = FakeFacts.get("task", @task)["values"]
      assert fix["work"]["input"]["change_set"]["manifest"] == author["result_manifest"]
      assert owner(@key) == ["mac-mini"] and flow_state(@key) == "fixing"

      finish(@key, files: @fixed, check: 0)
      reviewing = settle(c)
      assert reviewing["state"] == "reviewing"
      fixed = FakeFacts.get("task", fix["key"])["values"]

      assert reviewing["pending"]["task"]["work"]["input"]["change_set"]["manifest"] ==
               fixed["result_manifest"]

      finish(@key, answer: verdict("approved"))
      ready = settle(c)
      assert ready["state"] == "ready"

      assert Enum.map(ready["pending"]["tasks"], & &1["task_kind"]) ==
               ~w(author review fix review)

      assert owner(@key) == ["mac-mini"]
    end

    test "a failed or unfinished check (acc. 2) is a fix; another end is held, never silently",
         c do
      issue_run(c, "ada")

      ends = [
        {"PK-IS-Atlas-01-1", [files: @author, check: 1], "fixing"},
        {"PK-IS-Atlas-01-2", [files: @author, check: nil], "fixing"},
        {"PK-IS-Atlas-01-3", [kind: :failed, reason: "time_limit"], "held"},
        {"PK-IS-Atlas-01-4", [kind: :crashed], "held"}
      ]

      for {key, opts, state} <- ends do
        started(c, key)
        finish(key, opts)
        run = settle(c, key)
        assert {run["state"], run["status"]} == {state, "active"}, key

        if state == "held" do
          assert %{"on" => "held", "question" => q} = run["pending"]["ladder"]["awaiting"]
          assert is_list(q["answers"]) and q["answers"] != []
          # Held: the supervisor has it (B-3).
          assert owner(key) == ["ada"], key
        else
          assert owner(key) == ["mac-mini"], key
        end
      end
    end

    test "a refused work is held, and its supervisor has it", c do
      issue_run(c, "ada")
      started(c)
      {lease, _} = lease!(@key)
      assert {:recorded, _} = report(lease, 1, %{state: :refused, reason: :unsupported_profile})
      run = settle(c)
      assert {run["state"], run["status"]} == {"held", "active"}

      assert %{"on" => "held", "question" => %{"answers" => [_ | _]}} =
               run["pending"]["ladder"]["awaiting"]

      assert run["pending"]["task"] == nil
      assert owner(@key) == ["ada"]
    end

    # F2-P's migration (acc. 3) is history: Flow takes one hop, from a run's digest to the
    # compiled one, and live runs moved from a4 to the loop's digest then. It stays declared
    # as it was: waiting and authoring stay; authored and check_failed are stuck.
    test "a run of the package before the loop (acc. 3) moved on: waiting and authoring stayed; authored and check_failed are stuck" do
      a4 = "457c90fddd78d1aa85729dee951b6acd6beccdbd9fb109b6adfb89f7686d8747"
      loop = "ff2820a33b527143185cbdac7dea3d4bb4824b22ac4ce690f00bcba26f82f214"

      assert [%{"states" => states} = m] =
               Enum.filter(Model.AtlasEyra.selection(@name)["migrations"], &(&1["from"] == a4))

      assert m["to"] == loop
      refute Map.has_key?(m, "preserve_entry")

      assert states == %{
               "authored" => "stuck",
               "authoring" => "authoring",
               "check_failed" => "stuck",
               "stuck" => "stuck",
               "waiting" => "waiting"
             }
    end

    # Its presentation says its supervisor's pickup starts the work, and held and
    # awaiting_decision ask no hand-back to a machinery: texts only, so a live run on the
    # loop's digest keeps its state and its entry (nothing is presented again).
    test "a live run of the loop moves to the new texts, keeping its state and entry", c do
      issue_run(c, "ada")
      loop = "ff2820a33b527143185cbdac7dea3d4bb4824b22ac4ce690f00bcba26f82f214"
      digest = flow(:test).digest()
      assert digest != loop

      for {key, state, status} <- [
            {"PK-IS-Atlas-01-1", "held", "active"},
            {"PK-IS-Atlas-01-2", "awaiting_decision", "active"},
            {"PK-IS-Atlas-01-3", "stuck", "completed"},
            {"PK-IS-Atlas-01-4", "waiting", "active"}
          ] do
        package(key, "ada", %{"instructions" => if(state == "waiting", do: nil, else: "Do it.")})
        old_run(c, key, loop, state, status)
        run = reconcile(c, key)
        assert run["definition_sha256"] == digest, key
        assert {run["state"], run["status"], run["entry"]} == {state, status, 1}, key

        assert [%{"from" => ^loop, "to" => ^digest, "state" => ^state}] =
                 run["pending"]["migrations"]
      end

      package = Enum.find(Model.AtlasEyra.__flows__(), &(&1.name == :package))

      presented = for state <- package.states, state.present, do: {state.name, state.present}
      assert length(presented) == 8

      for {name, present} <- presented do
        assert present.instructions =~ "supervisor", "#{name}"

        if name in [:held, :awaiting_decision] do
          refute present.expected =~ "machinery", "#{name}"
          refute present.instructions =~ "machinery", "#{name}"
        end
      end
    end

    test "without its instructions it waits; nothing is asked or sent until they are set", c do
      issue_run(c, "ada")
      package(@key, "mac-mini", %{"instructions" => nil})
      waiting = reconcile(c)
      assert {waiting["state"], waiting["status"]} == {"waiting", "active"}
      assert FakeCode.calls(c.code) == []
      assert FakeFacts.get("task", @task) == nil

      # Nothing is expected of anyone while it waits, so the machinery keeps it.
      assert {:ok, _} = Projection.project(c.runner, "package", @key)
      assert FakeFacts.get("assignment", "AS-" <> @key)["links"]["assigned_to"] == ["mac-mini"]

      put_values(@key, %{"instructions" => "Write the parser."})
      authoring = intended(c)
      assert authoring["state"] == "authoring"

      # The move to authoring is what it first presents: the machinery keeps it (E1).
      assert {:ok, _} = Projection.project(c.runner, "package", @key)
      assignment = FakeFacts.get("assignment", "AS-" <> @key)
      assert assignment["links"]["assigned_to"] == ["mac-mini"]
      assert assignment["values"]["expected"] == "Author it on the machinery"
    end

    test "not assigned to a machinery: no task, nothing asked (E1)", c do
      issue_run(c, "ada")
      package(@key, "coordinator")
      run = reconcile(c)
      assert {run["state"], run["status"]} == {"authoring", "active"}
      assert run["pending"]["task"] == nil
      assert FakeCode.calls(c.code) == []
      assert FakeFacts.get("task", @task) == nil
    end

    test "its issue has no supervisor: the intent waits and nothing is offered", c do
      issue_run(c, nil)
      package(@key, "mac-mini")
      intended(c)
      assert FakeFacts.get("task", @task) != nil
      assert {:polled, %{leases: []}} = poll(@mini)
    end
  end

  describe "the supervisor answers, and hands the package back (B-3)" do
    setup :work_source

    test "acc. 5: held after the re-review bound, from reviewing: the supervisor has it, and an earlier answer is cleared",
         c do
      issue_run(c, "ada")
      started(c)
      finish(@key, files: @author, check: 0)
      assert settle(c)["state"] == "reviewing"
      # A machinery a person linked holds it while it is reviewed.
      assert owner(@key) == ["mac-mini"] and flow_state(@key) == "reviewing"
      # An answer left from before is never taken again.
      put_values(@key, %{"answer" => "fresh"})

      # Two reviews with no verdict: the re-review bound holds it (R1).
      finish(@key, answer: "no verdict here")
      assert settle(c)["state"] == "reviewing"
      finish(@key, answer: "still none")
      held = settle(c)

      assert {held["state"], held["status"]} == {"held", "active"}
      assert held["pending"]["task"] == nil
      assert %{"on" => "held", "question" => q} = held["pending"]["ladder"]["awaiting"]
      assert q["answers"] != []
      assert FakeFacts.get("package", @key)["values"]["answer"] == "none"
      # After the projection pass the supervisor holds it, and it stays held.
      assert owner(@key) == ["ada"] and flow_state(@key) == "held"
      assert settle(c)["state"] == "held"
      assert owner(@key) == ["ada"]
      assert decisions() == []
    end

    test "acc. 5: rung (e) from diagnosing: awaiting_decision, the supervisor has it, and an earlier answer is cleared",
         c do
      # An answer left from before (F-3) is never taken again.
      {_original, run} = escalated(c, @key, @needs_access, "fresh")
      assert {run["state"], run["status"]} == {"awaiting_decision", "active"}
      assert run["pending"]["task"] == nil
      assert %{"on" => "escalation", "question" => q} = run["pending"]["ladder"]["awaiting"]
      assert q["rung"] == "e" and "grant" in q["answers"] and "abandon" in q["answers"]
      assert FakeFacts.get("package", @key)["values"]["answer"] == "none"
      assert owner(@key) == ["ada"] and flow_state(@key) == "awaiting_decision"
      assert settle(c)["state"] == "awaiting_decision"
      assert owner(@key) == ["ada"]
      assert decisions() == []
    end

    test "acc. 6: handed back to its machinery with answer fresh: a fresh author on the original base, the machinery keeps it",
         c do
      {original, _} = escalated(c)
      tasks = length(run(c)["pending"]["tasks"])

      hand_back(@key, "mac-mini")
      put_values(@key, %{"answer" => "fresh"})
      fresh = settle(c)

      assert fresh["state"] == "fresh"
      next = "TK-#{@key}-#{tasks + 1}"
      assert %{"key" => ^next} = intent = fresh["pending"]["task"]
      assert intent["work"]["input"]["base"] == original
      refute Map.has_key?(intent["work"]["input"], "change_set")
      assert FakeFacts.get("task", next)["values"]["kind"] == "author"
      assert run(c)["pending"]["ladder"]["awaiting"] == nil

      # The machinery handed back stays: the move to fresh keeps it (preserve_kind).
      assert owner(@key) == ["mac-mini"] and flow_state(@key) == "fresh"
      assert decisions() == [] and flows(c) -- ["issue"] == [@name]
    end

    test "acc. 7: the supervisor's answer fresh alone runs the fresh author", c do
      escalated(c)
      tasks = length(run(c)["pending"]["tasks"])

      put_values(@key, %{"answer" => "fresh"})
      fresh = settle(c)
      next = "TK-#{@key}-#{tasks + 1}"
      assert {fresh["state"], fresh["pending"]["task"]["key"]} == {"fresh", next}
      assert FakeFacts.get("task", next)["values"]["kind"] == "author"
    end

    test "acc. 8: a worded option is a fresh author with the choice; abandon is stuck", c do
      escalated(c)
      hand_back(@key, "mac-mini")
      put_values(@key, %{"answer" => "grant"})
      fresh = settle(c)
      assert fresh["state"] == "fresh"
      assert %{"key" => _} = fresh["pending"]["task"]
      assert fresh["pending"]["ladder"]["choice"]["id"] == "grant"

      key = "PK-IS-Atlas-01-2"
      escalated(c, key)
      put_values(key, %{"answer" => "abandon"})
      stuck = settle(c, key)
      assert {stuck["state"], stuck["status"]} == {"stuck", "completed"}
      assert stuck["pending"]["task"] == nil
      assert decisions() == []
    end
  end

  describe "Flow asks the supervisor (F2-P: D1, D2, D3)" do
    setup :work_source

    test "D2: rung (e) writes the ladder's question on the package; retry is not offered",
         c do
      {_original, run} = escalated(c)
      assert run["state"] == "awaiting_decision"
      assert %{"question" => q} = run["pending"]["ladder"]["awaiting"]

      values = FakeFacts.get("package", @key)["values"]
      assert JSON.decode!(values["question"]) == q
      assert values["retry_step"] == "none"
      assert decisions() == []
    end

    test "D1: a safe default that touches no authority runs on with the machinery; the supervisor is only asked",
         c do
      {original, run} = escalated(c, @key, safe(@needs_access, []))

      # Not awaiting_decision: fresh, on the recommended option, the machinery keeps it.
      assert {run["state"], run["status"]} == {"fresh", "active"}
      assert run["last_input"]["outcome"] == "fresh"
      assert %{"key" => key} = intent = run["pending"]["task"]
      assert intent["loop"]["step"] == "fresh"
      assert intent["work"]["input"]["base"] == original
      assert FakeFacts.get("task", key)["values"]["kind"] == "author"
      assert run["pending"]["ladder"]["choice"]["id"] == "grant"
      assert owner(@key) == ["mac-mini"] and flow_state(@key) == "fresh"

      # It still asks: the question is the ladder's, with its continue step.
      assert %{"on" => "escalation", "question" => q} = run["pending"]["ladder"]["awaiting"]
      values = FakeFacts.get("package", @key)["values"]
      assert JSON.decode!(values["question"]) == q
      assert %{"step" => "fresh"} = q["continue"]
      assert decisions() == []

      # Safe, but it touches an authority: it waits, and the supervisor has it.
      other = "PK-IS-Atlas-01-2"
      {_, waits} = escalated(c, other, safe(@needs_access, ["credentials"]))
      assert {waits["state"], waits["pending"]["task"]} == {"awaiting_decision", nil}
      assert owner(other) == ["ada"]

      assert JSON.decode!(FakeFacts.get("package", other)["values"]["question"])["continue"] ==
               nil
    end

    test "D3: held after an abandoned review, retry goes back to reviewing: a review of the same result",
         c do
      {first, second, held} = abandoned_twice(c)
      assert %{"reason" => "abandoned", "question" => q} = held["pending"]["ladder"]["awaiting"]
      assert hd(q["answers"]) == "retry"
      values = FakeFacts.get("package", @key)["values"]
      assert JSON.decode!(values["question"]) == q
      assert values["retry_step"] == "review"

      hand_back(@key, "mac-mini")
      put_values(@key, %{"answer" => "retry"})
      retried = settle(c)
      assert retried["state"] == "reviewing"
      assert %{"key" => third} = intent = retried["pending"]["task"]
      assert third not in [first["key"], second]
      assert intent["loop"]["step"] == "review"
      assert FakeFacts.get("task", third)["values"]["kind"] == "review"
      assert intent["work"]["input"]["change_set"] == first["work"]["input"]["change_set"]
      assert intent["work"]["input"]["base"] == first["work"]["input"]["base"]
      assert retried["pending"]["ladder"]["awaiting"] == nil
      assert owner(@key) == ["mac-mini"]
      assert decisions() == []
    end
  end

  describe "an answer the ladder does not take asks again (F-1)" do
    setup :work_source

    test "a typo at rung (e): back to awaiting_decision, the answer reset, the supervisor asked again; nothing runs",
         c do
      {_original, escalated} = escalated(c)
      %{"question" => q} = escalated["pending"]["ladder"]["awaiting"]
      tasks = length(escalated["pending"]["tasks"])
      calls = FakeCode.calls(c.code)

      # Not offered: it goes to fresh by the model's label branch, and the ladder asks again.
      put_values(@key, %{"answer" => "frsh"})
      run = settle(c)

      assert {run["state"], run["status"]} == {"awaiting_decision", "active"}
      assert run["last_input"]["outcome"] == "escalate"
      assert run["pending"]["task"] == nil
      assert run["pending"]["ladder"]["awaiting"] == %{"on" => "escalation", "question" => q}
      values = FakeFacts.get("package", @key)["values"]
      assert values["answer"] == "none"
      assert JSON.decode!(values["question"]) == q
      assert values["retry_step"] == "none"
      assert owner(@key) == ["ada"] and flow_state(@key) == "awaiting_decision"
      assert FakeFacts.get("task", "TK-#{@key}-#{tasks + 1}") == nil
      assert FakeCode.calls(c.code) == calls
      assert settle(c)["state"] == "awaiting_decision"

      # Asked again, it is answered as before: the hand-back and an offered answer run on.
      hand_back(@key, "mac-mini")
      put_values(@key, %{"answer" => "grant"})
      fresh = settle(c)
      assert fresh["state"] == "fresh"
      assert %{"key" => _} = fresh["pending"]["task"]
      assert fresh["pending"]["ladder"]["choice"]["id"] == "grant"
      assert owner(@key) == ["mac-mini"]
      assert decisions() == []
    end

    test "fresh after an abandoned task (not offered) with a hand-back: held again, the supervisor has it; retry still runs",
         c do
      # Half a second in: held is entered within a second (Facts keeps since to the second).
      later(c, 500)
      {first, _second, held} = abandoned_twice(c)
      %{"question" => q} = awaiting = held["pending"]["ladder"]["awaiting"]
      refute "fresh" in q["answers"]
      tasks = length(held["pending"]["tasks"])

      # Handed back while held, in the second it was entered: it stays.
      hand_back(@key, "mac-mini", now(c))
      assert settle(c)["state"] == "held"
      assert owner(@key) == ["mac-mini"]
      # Answered a second later.
      later(c)
      put_values(@key, %{"answer" => "fresh"})
      again = settle(c)

      assert {again["state"], again["status"]} == {"held", "active"}
      assert again["last_input"]["outcome"] == "held"
      assert again["pending"]["task"] == nil
      assert again["pending"]["ladder"]["awaiting"] == awaiting
      values = FakeFacts.get("package", @key)["values"]
      assert values["answer"] == "none"
      assert JSON.decode!(values["question"]) == q
      assert values["retry_step"] == "review"
      # held → fresh → held in one reconcile: a new entry of held, so a move (B-3). The
      # hand-back was the earlier entry's: the supervisor has it again.
      assert owner(@key) == ["ada"] and flow_state(@key) == "held"
      assert FakeFacts.get("task", "TK-#{@key}-#{tasks + 1}") == nil
      assert settle(c)["state"] == "held"

      hand_back(@key, "mac-mini", now(c))
      put_values(@key, %{"answer" => "retry"})
      retried = settle(c)
      assert retried["state"] == "reviewing"
      assert %{"key" => _} = intent = retried["pending"]["task"]
      assert intent["work"]["input"]["change_set"] == first["work"]["input"]["change_set"]
      assert owner(@key) == ["mac-mini"]
      assert decisions() == []
    end

    test "an answer whose step is not the state's runs nothing: held again", c do
      issue_run(c, "ada")
      package(@key, "mac-mini", %{"answer" => "fresh"})
      question = %{"reason" => "stuck", "answers" => ["fresh", "abandon"], "options" => []}

      # A run in reviewing whose ladder waits on a question fresh answers: the ladder's step
      # is a fresh author, which does not run in reviewing.
      awaiting = %{"on" => "held", "reason" => "stuck", "task" => nil, "question" => question}
      waiting_run(c, @key, "reviewing", %{"version" => 2, "awaiting" => awaiting})
      # Presented in reviewing first, as the Engine's projection pass leaves it.
      assert {:ok, _} = Projection.project(c.runner, "package", @key)
      assert owner(@key) == ["mac-mini"] and flow_state(@key) == "reviewing"
      run = settle(c)

      assert {run["state"], run["pending"]["task"]} == {"held", nil}
      assert run["pending"]["ladder"]["awaiting"]["question"] == question
      values = FakeFacts.get("package", @key)["values"]
      assert values["answer"] == "none"
      assert JSON.decode!(values["question"]) == question
      assert owner(@key) == ["ada"]
      assert FakeFacts.get("task", @task) == nil
    end
  end

  describe "an answer while the loop runs on the default (Main's D1 ruling)" do
    setup :work_source

    test "another answer cancels the running default task and follows the answer; its result is never read",
         c do
      {original, run} = escalated(c, @key, safe(@needs_access, []))
      assert run["state"] == "fresh"
      %{"key" => default} = run["pending"]["task"]
      {lease, _offered} = running(@key)

      put_values(@key, %{"answer" => "fresh"})
      moved = settle(c)

      # Followed: a new author, plain fresh (no chosen option), on the original base.
      assert {moved["state"], moved["last_input"]["outcome"]} == {"fresh", "fresh"}
      assert %{"key" => next} = intent = moved["pending"]["task"]
      assert next != default
      assert intent["loop"]["step"] == "fresh"
      assert intent["work"]["input"]["base"] == original
      refute Map.has_key?(intent["work"]["input"], "change_set")
      assert moved["pending"]["ladder"]["awaiting"] == nil
      assert moved["pending"]["ladder"]["choice"] == nil

      # The default task: cancelled gracefully, recorded with no kind the ladder reads.
      assert [cancelled] = Enum.filter(moved["pending"]["tasks"], &(&1["key"] == default))
      assert {cancelled["outcome"], cancelled["answer"]} == {"cancelled", "fresh"}
      refute Map.has_key?(cancelled, "task_kind")
      # Store first, then cancel: Dispatch carries it out as it next reads the runs.
      Dispatch.sweep()
      values = FakeFacts.get("task", default)["values"]
      assert {values["lease_state"], values["lease_end_cause"]} == {"cancel_requested", "answer"}
      assert values["state"] == "cancelled"
      assert {:polled, %{cancel: [^lease]}} = holding(lease)

      # The Runtime ends it as cancelled: recorded; the run stays on the answer's author.
      assert {:recorded, _} = report(lease, 3, L.ended(nil, kind: :cancelled))
      drain(@key)
      after_end = settle(c)
      assert {after_end["state"], after_end["pending"]["task"]["key"]} == {"fresh", next}
      assert owner(@key) == ["mac-mini"]
      assert decisions() == []
    end

    test "abandon while the default runs: the task is cancelled, and the package is stuck", c do
      {_original, run} = escalated(c, @key, safe(@needs_access, []))
      %{"key" => default} = run["pending"]["task"]
      {lease, _offered} = running(@key)
      assert "abandon" in run["pending"]["ladder"]["awaiting"]["question"]["answers"]

      put_values(@key, %{"answer" => "abandon"})
      stuck = settle(c)

      assert {stuck["state"], stuck["status"]} == {"stuck", "completed"}
      assert stuck["last_input"]["outcome"] == "abandon"
      assert stuck["pending"]["task"] == nil
      assert stuck["pending"]["ladder"]["awaiting"] == nil

      # Cancelled gracefully, its result never read.
      assert [cancelled] = Enum.filter(stuck["pending"]["tasks"], &(&1["key"] == default))
      assert {cancelled["outcome"], cancelled["answer"]} == {"cancelled", "abandon"}
      refute Map.has_key?(cancelled, "task_kind")
      # Store first, then cancel: Dispatch carries it out as it next reads the runs.
      Dispatch.sweep()
      values = FakeFacts.get("task", default)["values"]
      assert {values["lease_state"], values["lease_end_cause"]} == {"cancel_requested", "answer"}
      assert {:polled, %{cancel: [^lease]}} = holding(lease)

      # Nothing more runs: no other task fact, and the end is final.
      assert FakeFacts.get("task", "TK-#{@key}-#{length(stuck["pending"]["tasks"]) + 1}") == nil
      assert settle(c)["state"] == "stuck"
      assert decisions() == []
    end

    test "an answer while the default's lease ended without a result (offered again) is read: it is followed, the old task never offered again",
         c do
      {original, run} = escalated(c, @key, safe(@needs_access, []))
      %{"key" => default} = run["pending"]["task"]
      {lease, _offered} = running(@key)

      # Returned: no result, so the task is offered again as a fresh lease (`:retry`).
      assert {:recorded, _} = report(lease, 3, L.ended(nil, kind: :returned))
      drain(@key)
      assert settle(c)["pending"]["task"]["key"] == default

      put_values(@key, %{"answer" => "fresh"})
      moved = settle(c)
      assert moved["state"] == "fresh"
      assert %{"key" => next} = intent = moved["pending"]["task"]
      assert next != default
      assert intent["work"]["input"]["base"] == original
      assert [cancelled] = Enum.filter(moved["pending"]["tasks"], &(&1["key"] == default))
      assert {cancelled["outcome"], cancelled["answer"]} == {"cancelled", "fresh"}
      refute Map.has_key?(cancelled, "task_kind")

      # Only the answer's author is offered; the default never again.
      Dispatch.sweep()
      assert {:polled, %{leases: leases}} = poll(@mini)
      assert Enum.map(leases, & &1.work.work_key) == [next]
      assert FakeFacts.get("task", default)["values"]["state"] == "cancelled"
    end

    test "an answer the question does not offer while the default runs: the work goes on, the question stays open",
         c do
      {_original, run} = escalated(c, @key, safe(@needs_access, []))
      intent = run["pending"]["task"]
      {lease, _offered} = running(@key)

      put_values(@key, %{"answer" => "frsh"})
      same = settle(c)
      Dispatch.sweep()

      assert {same["state"], same["pending"]["task"]} == {"fresh", intent}
      assert same["pending"]["ladder"]["awaiting"]["on"] == "escalation"
      assert FakeFacts.get("task", intent["key"])["values"]["lease_state"] == "started"
      assert {:polled, %{cancel: []}} = holding(lease)
    end

    test "the default answer is recorded and changes nothing: the same task runs on, uncancelled",
         c do
      {_original, run} = escalated(c, @key, safe(@needs_access, []))
      intent = run["pending"]["task"]
      {lease, offered} = running(@key)

      put_values(@key, %{"answer" => "grant"})
      same = settle(c)

      assert {same["state"], same["pending"]["task"]} == {"fresh", intent}
      assert same["pending"]["ladder"]["answered"] == "grant"
      assert same["pending"]["ladder"]["awaiting"] == nil
      assert same["pending"]["ladder"]["choice"]["id"] == "grant"
      assert FakeFacts.get("task", intent["key"])["values"]["lease_state"] == "started"
      assert {:polled, %{cancel: []}} = holding(lease)

      # It ends as always: its result is reviewed next.
      finish(@key, lease: {lease, offered}, started: true, files: @author, check: 0)
      review = settle(c)
      assert review["state"] == "reviewing"
      assert review["pending"]["task"]["loop"]["reviewed"] == intent["key"]
      assert owner(@key) == ["mac-mini"]
    end

    test "an answer after the default task ended is a normal answer: the result is taken, nothing ended is cancelled",
         c do
      {original, run} = escalated(c, @key, safe(@needs_access, []))
      %{"key" => default} = run["pending"]["task"]

      # Ended (its result reported), then answered before the run took the end.
      finish(@key, files: @author, check: 0)
      put_values(@key, %{"answer" => "fresh"})
      moved = settle(c)

      # Its end was taken as always: the result is the task's own, with its kind.
      assert [ended] = Enum.filter(moved["pending"]["tasks"], &(&1["key"] == default))
      assert {ended["task_kind"], ended["outcome"]} == {"author", "completed"}
      values = FakeFacts.get("task", default)["values"]
      assert values["lease_state"] == "done" and values["lease_end_cause"] in [nil, ""]
      assert values["state"] == "completed"

      # The question was still open, so the answer was read on the next step (the review
      # of the default's result, which never got a lease) and followed.
      assert moved["state"] == "fresh"
      assert %{"key" => next} = intent = moved["pending"]["task"]
      assert next != default
      assert intent["work"]["input"]["base"] == original
      refute Map.has_key?(intent["work"]["input"], "change_set")
      assert moved["pending"]["ladder"]["awaiting"] == nil

      assert [%{"key" => review}] =
               Enum.filter(moved["pending"]["tasks"], &(&1["outcome"] == "cancelled"))

      review = FakeFacts.get("task", review)["values"]
      assert {review["kind"], review["state"], review["lease_id"]} == {"review", "cancelled", nil}

      assert decisions() == []
    end

    test "an answer to an earlier question is not this one's: asking resets it, and the default runs on",
         c do
      # A stale fresh on the package while it is diagnosed.
      {_original, run} = escalated(c, @key, safe(@needs_access, []), "fresh")
      intent = run["pending"]["task"]
      assert run["state"] == "fresh"
      assert FakeFacts.get("package", @key)["values"]["answer"] == "none"

      {_lease, _offered} = running(@key)
      same = settle(c)
      assert same["pending"]["task"] == intent
      assert same["pending"]["ladder"]["awaiting"]["on"] == "escalation"
      assert FakeFacts.get("task", intent["key"])["values"]["lease_state"] == "started"
    end
  end

  # The run store's world: Facts, the clock, the work source's processes on a fake Code.
  defp work_source(_context) do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    # The model's tests start no platform app; Flow's run store talks over the Bus.
    environment = Application.get_env(:atlas_bus, :environment)
    Application.put_env(:atlas_bus, :environment, "test")
    on_exit(fn -> restore_env(:atlas_bus, :environment, environment) end)
    {:ok, _} = Application.ensure_all_started(:atlas_bus)
    dir = Path.join(System.tmp_dir!(), "package-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    start_supervised!(FakeFacts)
    {:ok, clock} = ManualClock.start_link(@now)
    clock = {ManualClock, clock}
    :ok = AtlasBus.attach("flow")

    FakeFacts.put("machinery", %{"key" => "mac-mini", "values" => %{"name" => "mac-mini"}})
    FakeFacts.put("agent", %{"key" => "coordinator", "values" => %{"name" => "coordinator"}})
    FakeFacts.put("person", %{"key" => "ada"})
    FakeFacts.put("issue", %{"key" => @issue, "values" => %{"title" => "The goal"}})

    runner = runner()
    assert runner.refusal == nil

    # The work source: the result store, Bases on Code (a fake holding develop), Dispatch
    # and Delivery, which casts its reconciles to the test process.
    code = start_supervised!({FakeCode, %{}}, id: :code)
    FakeCode.put(code, @repository, "develop", "rev_1", %{"README.md" => "# Atlas\n"})

    start_supervised!({Results, dir: dir, clock: clock, sweep_ms: 86_400_000, pins: fn -> [] end})

    start_supervised!({Bases, client: FakeCode.client(code), clock: clock})

    start_supervised!(
      {Dispatch,
       model: Model.AtlasEyra,
       actors: @actors,
       clock: clock,
       poll_wait: 0,
       sweep_ms: nil,
       resync_ms: nil}
    )

    start_supervised!(
      {Delivery, model: Model.AtlasEyra, actors: @actors, clock: clock, engine: self()}
    )

    %{runner: runner, clock: clock, code: code}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  # The issue's run, in its span `build` (state `working`), supervised by `supervisor` (a
  # person's key, or nil): as Flow keeps it once someone picked it up.
  defp issue_run(c, supervisor) do
    config = c.runner.config
    flow = Enum.find(Model.AtlasEyra.subflows(:test), &(&1.name() == "issue"))

    run = %{
      "flow" => "issue",
      "subject_kind" => "issue",
      "subject_key" => @issue,
      "generation" => 1,
      "definition_sha256" => flow.digest(),
      "state" => "working",
      "entry" => 1,
      "entered_at" => DateTime.to_iso8601(@now),
      "status" => "active",
      "deadlines" => %{"version" => 1},
      "pending" => %{"version" => 1, "writes" => []},
      "input_cursor" => 0,
      "last_input" => %{"version" => 1},
      "blocked_reason" => ""
    }

    relation = config["supervision"]["relation"]

    FakeFacts.put(config["kind"], %{
      "key" => Run.key("issue", "issue", @issue, 1),
      "version" => 0,
      "values" => Store.encode(config, run),
      "links" => if(supervisor, do: %{relation => [supervisor]}, else: %{})
    })
  end

  # A package whose run holds its version-2 intent (its base asked for first, unless Bases
  # holds it already).
  defp intended(c, key \\ @key) do
    if reconcile(c, key)["pending"]["task"] == nil do
      assert_receive {:reconcile, "package", ^key}, 2_000
    end

    run = reconcile(c, key)
    assert %{"version" => 2} = run["pending"]["task"]
    run
  end

  defp poll({id, _} = client), do: WorkSource.poll(client, L.poll_input(id, [], @offer))

  # The mac-mini's poll holding `lease`, offered nothing new: its renewals and cancels.
  defp holding(lease), do: WorkSource.poll(@mini, L.poll_input("mac-mini", [lease], %{}))

  # The lease of the package `key`'s task, accepted and started, its work not ended.
  defp running(key) do
    {lease, _} = leased = lease!(key)
    assert {:recorded, _} = report(lease, 1, %{state: :accepted})
    assert {:recorded, _} = report(lease, 2, %{state: :started})
    leased
  end

  defp report(lease, revision, report),
    do: WorkSource.report(@mini, %{lease_id: lease, revision: revision, report: report})

  # A package of the issue, as Flow makes one, and its Assignment handed (by someone other
  # than Flow) to `owner`: a machinery, or the coordinator agent.
  defp package(key, owner, values \\ %{}) do
    values =
      %{
        "title" => "The parser",
        "instructions" => "Write the parser.",
        "acceptance" => "It parses."
      }
      |> Map.merge(values)
      |> Map.reject(fn {_, v} -> v == nil end)

    FakeFacts.put("package", %{
      "key" => key,
      "values" => values,
      "links" => %{"package_of" => ["IS-Atlas-01"], "assignment" => ["AS-" <> key]}
    })

    FakeFacts.put("assignment", %{
      "key" => "AS-" <> key,
      "values" => %{"of" => key},
      "links" => %{"assigned_to" => [owner]},
      "origins" => %{"assigned_to" => %{"by" => "someone", "position" => 1}}
    })
  end

  defp put_values(key, values) do
    fact = FakeFacts.get("package", key)

    FakeFacts.put(
      "package",
      Map.merge(fact, %{
        "values" => Map.merge(fact["values"], values),
        "version" => (fact["version"] || 0) + 1
      })
    )
  end

  # The supervisor links the package's Assignment back to its machinery, by hand; `since`
  # is when Facts stored the link, as it keeps it (to the second), if the test needs it.
  defp hand_back(key, machinery, since \\ nil) do
    assignment = FakeFacts.get("assignment", "AS-" <> key)
    origin = %{"by" => "ada", "position" => 2, "since" => since}

    FakeFacts.put(
      "assignment",
      Map.merge(assignment, %{
        "links" => %{"assigned_to" => [machinery]},
        "origins" => %{"assigned_to" => Map.reject(origin, fn {_, v} -> v == nil end)},
        "version" => (assignment["version"] || 0) + 1
      })
    )
  end

  # The clock's now, as Facts writes a link's since (to the second); and a second later.
  defp now(c) do
    {ManualClock, clock} = c.clock
    clock |> ManualClock.now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp later(c, ms \\ 1_000) do
    {ManualClock, clock} = c.clock
    ManualClock.advance(clock, ms)
  end

  defp owner(key), do: FakeFacts.get("assignment", "AS-" <> key)["links"]["assigned_to"]
  defp flow_state(key), do: FakeFacts.get("assignment", "AS-" <> key)["values"]["flow_state"]

  # A package of the issue on the mac-mini, whose run holds its first author's intent.
  defp started(c, key \\ @key) do
    package(key, "mac-mini")
    run = intended(c, key)
    assert {:ok, _} = Projection.project(c.runner, "package", key)
    run
  end

  # Author and two fixes, all failing their check, then a diagnosis that needs access
  # (`block`): rung (e), with `stale` (an earlier answer) on the package while it is
  # diagnosed. The first author's base, and the escalated run.
  defp escalated(c, key \\ @key, block \\ @needs_access, stale \\ nil) do
    issue_run(c, "ada")
    original = started(c, key)["pending"]["task"]["work"]["input"]["base"]
    finish(key, files: @author, check: 1)

    for _ <- 1..2 do
      assert settle(c, key)["state"] == "fixing"
      assert owner(key) == ["mac-mini"]
      finish(key, files: @fixed, check: 1)
    end

    assert settle(c, key)["state"] == "diagnosing"
    assert owner(key) == ["mac-mini"]
    if stale, do: put_values(key, %{"answer" => stale})
    finish(key, answer: diagnosis(block))
    {original, settle(c, key)}
  end

  # A review abandoned (its assignment moved away while its issue had no supervisor, so
  # it was the machinery's, E1), retried once, abandoned again: held (D3); then picked up
  # again. The first review's intent, the second's key, and the held run.
  defp abandoned_twice(c) do
    issue_run(c, "ada")
    started(c)
    finish(@key, files: @author, check: 0)
    issue_run(c, nil)
    review = settle(c)
    assert review["state"] == "reviewing"
    first = review["pending"]["task"]

    # Moved away while it is reviewed: abandoned, and started once more.
    hand_back(@key, "coordinator")
    assert settle(c)["state"] == "reviewing"
    hand_back(@key, "mac-mini")
    again = settle(c)
    assert again["state"] == "reviewing"
    assert %{"key" => second} = again["pending"]["task"]
    assert second != first["key"]

    # Abandoned again: held.
    hand_back(@key, "coordinator")
    held = settle(c)
    assert {held["state"], held["pending"]["task"]} == {"held", nil}
    issue_run(c, "ada")
    {first, second, settle(c)}
  end

  # A run of the package on the current definition, in `state`, holding `ladder`.
  defp waiting_run(c, key, state, ladder) do
    run = %{
      "flow" => @name,
      "subject_kind" => "package",
      "subject_key" => key,
      "generation" => 1,
      "definition_sha256" => flow(:test).digest(),
      "state" => state,
      "entry" => 1,
      "entered_at" => DateTime.to_iso8601(@now),
      "status" => "active",
      "deadlines" => %{"version" => 1, "timers" => []},
      "pending" => %{"version" => 1, "writes" => [], "ladder" => ladder},
      "input_cursor" => 0,
      "last_input" => %{"version" => 1},
      "blocked_reason" => ""
    }

    FakeFacts.put(c.runner.config["kind"], %{
      "key" => Run.key(@name, "package", key, 1),
      "version" => 0,
      "values" => Store.encode(c.runner.config, run),
      "links" => %{}
    })
  end

  # The diagnosis `block` with its recommended option safe to continue on, touching
  # `touches`.
  defp safe(block, touches) do
    update_in(
      block,
      ["decision"],
      &Map.merge(&1, %{"safe_to_continue" => true, "touches" => touches})
    )
  end

  # The lease the mac-mini is offered, worked to its end: accepted, started, ended with
  # `files` (none: no change set) on the lease's base, the check's exit status (`:check`
  # given as nil: a check with none; left out: no check) and `answer`, `kind`, `reason`;
  # every missing blob put, and Delivery's casts taken.
  defp finish(key, opts) do
    {lease, offered} = Keyword.get_lazy(opts, :lease, fn -> lease!(key) end)
    files = Keyword.get(opts, :files, [])
    change_set = if files != [], do: L.change_set(files, offered.input.base.base_id)

    check =
      case Keyword.fetch(opts, :check) do
        :error -> []
        {:ok, nil} -> [check: %{exit_status: nil, output_tail: "tail"}]
        {:ok, status} -> [check: %{exit_status: status, output_tail: "tail #{status}"}]
      end

    ended = L.ended(change_set, check ++ Keyword.take(opts, [:answer, :kind, :reason]))

    # `started: true`: `running/1` accepted and started it already.
    if !opts[:started] do
      assert {:recorded, _} = report(lease, 1, %{state: :accepted})
      assert {:recorded, _} = report(lease, 2, %{state: :started})
    end

    assert {:recorded, answer} = report(lease, 3, ended)

    for sha <- Map.get(answer, :missing, []) do
      {_path, bytes} = Enum.find(files, fn {_, b} -> L.sha256(b) == sha end)

      assert :stored =
               WorkSource.put_blob(@mini, %{
                 lease_id: lease,
                 sha256: sha,
                 size: byte_size(bytes),
                 content: [bytes]
               })
    end

    assert_receive {:"$gen_cast", {:reconcile, "package", ^key}}, 2_000
    drain(key)
    lease
  end

  # The one lease of the package `key` the mac-mini is offered.
  defp lease!(key) do
    assert {:polled, %{leases: leases}} = poll(@mini)
    prefix = "TK-#{key}-"

    assert [%{lease_id: lease, work: offered}] =
             Enum.filter(leases, &String.starts_with?(&1.work.work_key, prefix))

    {lease, offered}
  end

  # Delivery's further casts of this end, if any (already in the mailbox: no wait).
  defp drain(key) do
    receive do
      {:"$gen_cast", {:reconcile, "package", ^key}} -> drain(key)
    after
      0 -> :ok
    end
  end

  # Reconciles until the run holds an intent or rests (a state's entry and its next
  # intent may take two rounds), then projects it, as the Engine does after a round.
  defp settle(c, key \\ @key, rounds \\ 4) do
    run = reconcile(c, key)

    cond do
      run["pending"]["task"] != nil or rounds == 0 -> projected(c, key, run)
      run == reconcile(c, key) -> projected(c, key, run)
      true -> settle(c, key, rounds - 1)
    end
  end

  defp projected(c, key, run) do
    assert {:ok, _} = Projection.project(c.runner, "package", key)
    run
  end

  defp run(c, key \\ @key) do
    fact = FakeFacts.get(c.runner.config["kind"], Run.key(@name, "package", key, 1))
    {:ok, run} = Store.decode(c.runner.config, fact)
    run
  end

  defp flows(c) do
    {:ok, %{runs: runs}} = Store.plan(c.runner.config, c.runner.flows)
    runs |> Enum.map(& &1["flow"]) |> Enum.uniq() |> Enum.sort()
  end

  # A run of the package on an earlier definition (`digest`), in `state`.
  defp old_run(c, key, digest, state, status) do
    run = %{
      "flow" => @name,
      "subject_kind" => "package",
      "subject_key" => key,
      "generation" => 1,
      "definition_sha256" => digest,
      "state" => state,
      "entry" => 1,
      "entered_at" => DateTime.to_iso8601(@now),
      "status" => status,
      "deadlines" => %{"version" => 1, "timers" => []},
      "pending" => %{"version" => 1, "writes" => []},
      "input_cursor" => 0,
      "last_input" => %{"version" => 1},
      "blocked_reason" => ""
    }

    FakeFacts.put(c.runner.config["kind"], %{
      "key" => Run.key(@name, "package", key, 1),
      "version" => 0,
      "values" => Store.encode(c.runner.config, run),
      "links" => %{}
    })
  end

  # A review's answer, ending with its verdict block.
  defp verdict(verdict, findings \\ []),
    do:
      "I looked at it.\n\n```json\n" <>
        JSON.encode!(%{"verdict" => verdict, "findings" => findings}) <> "\n```\n"

  # A diagnose task's answer, ending with its diagnosis block.
  defp diagnosis(block), do: "Here is why.\n\n```json\n" <> JSON.encode!(block) <> "\n```\n"

  # The decision facts Facts holds: none, while Flow writes no decision.
  defp decisions do
    %{"facts" => facts} = AtlasFlow.Talk.transition_read("decision", %{"plain" => true})
    facts
  end

  defp reconcile(c, key \\ @key) do
    config = c.runner.config
    flows = c.runner.flows
    {:ok, %{runs: known}} = Store.plan(config, flows)
    now = AtlasFlow.Runs.Clock.now(c.clock)
    {:ok, runs} = Store.reconcile_subjects(config, flows, now, known, [{"package", key}])
    assert [run] = Enum.filter(runs, &(&1["subject_key"] == key and &1["flow"] == @name))
    run
  end
end
