defmodule Model.PackageRunsTest do
  @moduledoc """
  F1.4: the package subflow on Flow's durable runs, through the composition. A package
  waits for its instructions, then is authored by one author task on the machinery its
  Assignment names (role developer, `deep_coding`, a repository workspace on `develop`,
  `bin/check` after the work), and ends `authored`, `check_failed` or `stuck`. It is run
  by `AtlasFlow.Runs.Store` as the composition selects it, with `AtlasFlow.FakeFacts` and
  a fake `AtlasFlow.Runtime.Client` (`AtlasFlow.FakeRuntime`), and presented on its
  Assignment (`AtlasFlow.Runs.Projection`).
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.{FakeFacts, FakeRuntime, ManualClock}
  alias AtlasFlow.Runs.{Projection, Run, Store}

  @now ~U[2026-11-17 09:00:00Z]
  @envs [:prod, :test]
  @name "package"
  @key "PK-IS-Atlas-01-1"
  @task "TK-PK-IS-Atlas-01-1-1"

  defp flow(env), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == @name))
  defp runner, do: AtlasFlow.Model.load(Model.AtlasEyra, :test, %{"decider" => "someone"})

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
                 # A repository and its base, never a path on the machinery (D44).
                 "input" => %{
                   "repository" => "https://github.com/mimbre/atlas.git",
                   "base" => "develop"
                 },
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
      machinery = Application.get_env(:atlas_flow, :machinery)
      client = Application.get_env(:atlas_flow, :runtime_client)

      Application.put_env(:atlas_flow, :machinery, %{
        "mac-mini" => %{url: "http://127.0.0.1:9", token_env: "ATLAS_FLOW_PACKAGE_TEST_TOKEN"}
      })

      Application.put_env(:atlas_flow, :runtime_client, FakeRuntime)

      on_exit(fn ->
        restore(:machinery, machinery)
        restore(:runtime_client, client)
      end)

      start_supervised!(FakeFacts)
      start_supervised!(FakeRuntime)
      clock = start_supervised!({ManualClock, @now})
      :ok = AtlasBus.attach("flow")

      FakeFacts.put("machinery", %{"key" => "mac-mini", "values" => %{"name" => "mac-mini"}})
      FakeFacts.put("agent", %{"key" => "coordinator", "values" => %{"name" => "coordinator"}})
      FakeFacts.put("issue", %{"key" => "IS-Atlas-01", "values" => %{"title" => "The goal"}})

      runner = runner()
      assert runner.refusal == nil
      %{runner: runner, clock: clock}
    end

    test "the state path: waiting, one author task on the machinery, authored", c do
      package(@key, "mac-mini")
      authoring = reconcile(c)
      assert {authoring["state"], authoring["status"]} == {"authoring", "active"}

      assert %{"key" => @task, "machinery" => "mac-mini", "work_id" => "w-1"} =
               authoring["pending"]["task"]

      # The task record, intent first, belongs to the package.
      record = FakeFacts.get("task", @task)
      assert record["links"]["task_of"] == [@key]

      assert Map.take(record["values"], ~w(kind role profile client_key work_id)) == %{
               "kind" => "author",
               "role" => "developer",
               "profile" => "deep_coding",
               "client_key" => @task,
               "work_id" => "w-1"
             }

      assert JSON.decode!(record["values"]["input"]) == %{
               "repository" => "https://github.com/mimbre/atlas.git",
               "base" => "develop"
             }

      # One submit, under the task's key: a repository on develop, bin/check after it.
      assert [[@task, request]] = FakeRuntime.calls(:submit)

      assert request["workspace"] == %{
               "kind" => "repository",
               "url" => "https://github.com/mimbre/atlas.git",
               "branch" => "flow/" <> @task,
               "base" => "develop"
             }

      assert request["after_check"] == %{"command" => ["bin/check"]}
      assert {request["profile"], request["cost_class"]} == {"deep_coding", "standard"}
      assert request["title"] == "author " <> @key
      assert request["instructions"] =~ ~r/\ABuild the package below/

      assert request["instructions"] =~
               "\n\n## title\n\nThe parser\n\n## instructions\n\nWrite the parser.\n\n## acceptance\n\nIt parses."

      # Presented on its Assignment; the machinery it was handed to keeps it.
      assert {:ok, _} = Projection.project(c.runner, "package", @key)
      assignment = FakeFacts.get("assignment", "AS-" <> @key)
      assert assignment["values"]["flow_state"] == "authoring"
      assert assignment["values"]["expected"] == "Author it on the machinery"
      assert assignment["links"]["assigned_to"] == ["mac-mini"]

      FakeRuntime.move(@task, "running")
      assert reconcile(c)["state"] == "authoring"

      FakeRuntime.completed(@task)
      done = reconcile(c)
      assert {done["state"], done["status"]} == {"authored", "completed"}
      assert [%{"key" => @task, "outcome" => "completed"}] = done["pending"]["tasks"]
      assert FakeFacts.get("task", @task)["values"]["state"] == "completed"
      assert length(FakeRuntime.calls(:submit)) == 1

      # Ended: nothing is expected of anyone any more.
      assert {:ok, _} = Projection.project(c.runner, "package", @key)
      values = FakeFacts.get("assignment", "AS-" <> @key)["values"]
      assert values["expected"] in [nil, ""] and values["flow_state"] in [nil, ""]
    end

    test "a failed or unfinished check is check_failed; another end, or moved away, is stuck",
         c do
      ends = [
        {"PK-IS-Atlas-01-1", &FakeRuntime.completed(&1, %{"exit_status" => 1}), "check_failed"},
        {"PK-IS-Atlas-01-2",
         &FakeRuntime.completed(&1, %{"exit_status" => nil, "timed_out" => true}),
         "check_failed"},
        {"PK-IS-Atlas-01-3", &FakeRuntime.finish(&1, "failed", %{"reason" => "time_limit"}),
         "stuck"},
        {"PK-IS-Atlas-01-4", &FakeRuntime.finish(&1, "crashed"), "stuck"},
        {"PK-IS-Atlas-01-5", &away/1, "stuck"}
      ]

      for {key, finish, outcome} <- ends do
        package(key, "mac-mini")
        assert reconcile(c, key)["state"] == "authoring"
        finish.("TK-#{key}-1")
        ended = reconcile(c, key)
        assert {ended["state"], ended["status"]} == {outcome, "completed"}, key
      end

      assert [%{"outcome" => "abandoned"}] = reconcile(c, "PK-IS-Atlas-01-5")["pending"]["tasks"]
    end

    test "without its instructions it waits; nothing is sent until they are set", c do
      package(@key, "mac-mini", %{"instructions" => nil})
      waiting = reconcile(c)
      assert {waiting["state"], waiting["status"]} == {"waiting", "active"}
      assert FakeRuntime.calls() == []
      assert FakeFacts.get("task", @task) == nil

      # Nothing is expected of anyone while it waits, so the machinery keeps it.
      assert {:ok, _} = Projection.project(c.runner, "package", @key)
      assert FakeFacts.get("assignment", "AS-" <> @key)["links"]["assigned_to"] == ["mac-mini"]

      put_values(@key, %{"instructions" => "Write the parser."})
      authoring = reconcile(c)
      assert authoring["state"] == "authoring"
      assert authoring["pending"]["task"]["work_id"] == "w-1"

      # The move to authoring is what it first presents: the machinery keeps it (E1).
      assert {:ok, _} = Projection.project(c.runner, "package", @key)
      assignment = FakeFacts.get("assignment", "AS-" <> @key)
      assert assignment["links"]["assigned_to"] == ["mac-mini"]
      assert assignment["values"]["expected"] == "Author it on the machinery"
    end

    test "not assigned to a machinery: no task, nothing sent (E1)", c do
      package(@key, "coordinator")
      run = reconcile(c)
      assert {run["state"], run["status"]} == {"authoring", "active"}
      assert run["pending"]["task"] == nil
      assert FakeRuntime.calls() == []
      assert FakeFacts.get("task", @task) == nil
    end
  end

  defp restore(key, value), do: restore_env(:atlas_flow, key, value)

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

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
    now = ManualClock.now(c.clock)
    {:ok, runs} = Store.reconcile_subjects(config, flows, now, known, [{"package", key}])
    assert [run] = Enum.filter(runs, &(&1["subject_key"] == key and &1["flow"] == @name))
    run
  end
end
