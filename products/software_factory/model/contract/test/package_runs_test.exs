defmodule Model.PackageRunsTest do
  @moduledoc """
  F1.4 on the lease path (M3 A4): the package subflow on Flow's durable runs, through the
  composition. A package waits for its instructions, then is authored by one author task
  for the machinery its Assignment names (role developer, `deep_coding`, a base of the
  Code repository's `develop`, `bin/check` after the work), offered through Flow's work
  source to a Runtime of its issue's human supervisor, and ends `authored`,
  `check_failed` or `stuck`. It is run by `AtlasFlow.Runs.Store` as the composition
  selects it, with `AtlasFlow.FakeFacts`, the work source's processes (Dispatch,
  Delivery, the result store, Bases on `AtlasFlow.FakeCode`) and a manual clock, and
  presented on its Assignment (`AtlasFlow.Runs.Projection`). Structure, not wording.
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

  defp flow(env), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == @name))
  defp runner, do: AtlasFlow.Model.load(Model.AtlasEyra, :test, @actors)

  describe "the definition" do
    test "selected in both environments, runnable: waiting, authoring and its three ends" do
      for env <- @envs do
        runner = AtlasFlow.Model.load(Model.AtlasEyra, env, %{"decider" => "someone"})
        assert runner.refusal == nil
        assert Map.has_key?(runner.config["selection"], @name)

        f = flow(env)
        assert Run.validate(f) == :ok
        assert f.subject() == "package"
        assert f.initial() == "waiting"
        assert Enum.sort(f.states()) == ~w(authored authoring check_failed stuck waiting)
        assert Enum.filter(f.states(), &f.final?/1) == ~w(authored check_failed stuck)
        assert f.mechanism("waiting") == nil
        assert Enum.all?(f.states(), &(f.timers(&1) == []))

        # waiting: on to authoring once it has its instructions, and not before.
        assert f.next("waiting", %{"title" => "Build it"}, nil) == :stay
        assert f.next("waiting", %{"instructions" => ""}, nil) == :stay
        assert f.next("waiting", %{"instructions" => "Do it."}, nil) == {:to, "authoring"}

        # authoring: each task result leads where the plan says; abandoned is stuck.
        for {result, to} <- [
              {"completed", "authored"},
              {"check_failed", "check_failed"},
              {"stuck", "stuck"},
              {"abandoned", "stuck"}
            ] do
          assert f.next("authoring", %{"task_result" => result}, :result) == {:to, to}
        end
      end
    end

    test "authoring is one author task: developer, deep_coding, the base, bin/check" do
      for env <- @envs do
        assert {:task, spec} = flow(env).mechanism("authoring")

        assert Map.drop(spec, ["instructions"]) == %{
                 "kind" => "author",
                 "role" => "developer",
                 "profile" => "deep_coding",
                 "cost_class" => "standard",
                 # A Code repository and its base's reference, never a URL or a path (D44).
                 "input" => %{"repository" => @repository, "base" => "develop"},
                 "check" => ["bin/check"],
                 "fields" => ["title", "instructions", "acceptance"],
                 "records" => %{"kind" => "task", "relation" => "task_of"},
                 "machinery" => "machinery",
                 "field" => "task_result"
               }

        # The standard text: the worker rules, the affected tests, the answer's end.
        assert spec["instructions"] =~ "boundary greps"
        assert spec["instructions"] =~ "no web search"
        assert spec["instructions"] =~ "Run the tests of every system you change."
        assert spec["instructions"] =~ "End your answer with"
      end
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
    setup do
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

      start_supervised!(
        {Results, dir: dir, clock: clock, sweep_ms: 86_400_000, pins: fn -> [] end}
      )

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

    test "the state path: waiting, one author task offered to the supervisor's Runtime, authored",
         c do
      issue_run(c, "ada")
      package(@key, "mac-mini")

      # Its base is asked of Code first; once Bases has it, the intent is made.
      assert reconcile(c)["pending"]["task"] == nil
      assert_receive {:reconcile, "package", @key}, 2_000
      {:ok, base} = Bases.cached(@repository, "develop")
      authoring = reconcile(c)
      assert {authoring["state"], authoring["status"]} == {"authoring", "active"}

      assert %{"version" => 2, "key" => @task, "machinery" => "mac-mini"} =
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
      assert work.after_check == %{command: ["bin/check"]}
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
      assert assignment["links"]["assigned_to"] == ["mac-mini"]

      assert {:recorded, _} = report(lease, 1, %{state: :accepted})
      assert {:recorded, _} = report(lease, 2, %{state: :started})
      assert reconcile(c)["state"] == "authoring"
      assert {:recorded, _} = report(lease, 3, L.ended(nil, check: %{exit_status: 0}))
      assert_receive {:"$gen_cast", {:reconcile, "package", @key}}

      done = reconcile(c)
      assert {done["state"], done["status"]} == {"authored", "completed"}
      assert [%{"key" => @task, "outcome" => "completed"}] = done["pending"]["tasks"]
      assert FakeFacts.get("task", @task)["values"]["state"] == "completed"
      # Its attempt ran on the machinery the Runtime's id names.
      assert FakeFacts.get("task_attempt", "TA-#{@task}-1")["links"]["ran_on"] == ["mac-mini"]

      # Ended: nothing is expected of anyone any more.
      assert {:ok, _} = Projection.project(c.runner, "package", @key)
      values = FakeFacts.get("assignment", "AS-" <> @key)["values"]
      assert values["expected"] in [nil, ""] and values["flow_state"] in [nil, ""]
    end

    test "a failed or unfinished check is check_failed; another end, or moved away, is stuck",
         c do
      issue_run(c, "ada")

      ends = [
        {"PK-IS-Atlas-01-1", &report(&1, 3, L.ended(nil, check: %{exit_status: 1})),
         "check_failed"},
        {"PK-IS-Atlas-01-2", &report(&1, 3, L.ended(nil, check: %{timed_out: true})),
         "check_failed"},
        {"PK-IS-Atlas-01-3", &report(&1, 3, L.ended(nil, kind: :failed, reason: "time_limit")),
         "stuck"},
        {"PK-IS-Atlas-01-4", &report(&1, 3, L.ended(nil, kind: :crashed)), "stuck"},
        {"PK-IS-Atlas-01-5", fn _ -> away("TK-PK-IS-Atlas-01-5-1") end, "stuck"}
      ]

      for {key, finish, outcome} <- ends do
        package(key, "mac-mini")
        intended(c, key)
        assert {:polled, %{leases: [%{lease_id: lease}]}} = poll(@mini)
        assert {:recorded, _} = report(lease, 1, %{state: :accepted})
        assert {:recorded, _} = report(lease, 2, %{state: :started})
        finish.(lease)
        ended = reconcile(c, key)
        assert {ended["state"], ended["status"]} == {outcome, "completed"}, key
      end

      assert [%{"outcome" => "abandoned"}] = reconcile(c, "PK-IS-Atlas-01-5")["pending"]["tasks"]
    end

    test "a refused work is stuck", c do
      issue_run(c, "ada")
      package(@key, "mac-mini")
      intended(c)
      assert {:polled, %{leases: [%{lease_id: lease}]}} = poll(@mini)
      assert {:recorded, _} = report(lease, 1, %{state: :refused, reason: :unsupported_profile})
      assert {"stuck", "completed"} == then(reconcile(c), &{&1["state"], &1["status"]})
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

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  # The issue's run, in its span `build` (state `author`), supervised by `supervisor` (a
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
      "state" => "author",
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

  defp poll({id, _} = client),
    do: WorkSource.poll(client, L.poll_input(id, [], %{"deep_coding" => 1}))

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
    FakeFacts.put("package", %{fact | "values" => Map.merge(fact["values"], values)})
  end

  # The package's Assignment handed to the coordinator: its task is left.
  defp away(task) do
    "TK-" <> rest = task
    key = String.replace_suffix(rest, "-1", "")
    assignment = FakeFacts.get("assignment", "AS-" <> key)
    FakeFacts.put("assignment", put_in(assignment, ["links", "assigned_to"], ["coordinator"]))
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
