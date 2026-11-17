Code.require_file("spec_rows.exs", __DIR__)

defmodule AtlasRuntime.Sandbox.PreparationParityTest do
  # S6 package A6: AtlasRuntime.Sandbox.Preparation decides every row of
  # test/fixtures/s6/prepare/ as the checked-in expect says (B2), which the Go tests assert
  # against the legacy decision: plan.json and ready.json in TestS6PrepareParity and
  # TestS6PrepareReadiness (host/workspace/s6_prepare_parity_test.go), runner.json in
  # TestS6PrepareRunnerParity (host/host/s6_prepare_runner_parity_test.go). Facts come from
  # the real helper (`workspace facts prepare`) under the row's environment, so the tests
  # change the process environment and are not async.
  use ExUnit.Case, async: false

  alias AtlasRuntime.{S6Fixture, SpecRows}
  alias AtlasRuntime.Sandbox.{Facts, Preparation, Spec}

  @tables ["plan.json", "ready.json", "runner.json"]
  @dir Path.join(S6Fixture.dir(), "prepare")

  for table <- @tables, do: @external_resource(Path.join(@dir, table))

  rows =
    for table <- @tables,
        row <- S6Fixture.load_table!(Path.join(@dir, table))["rows"],
        do: {table, row}

  for {table, row} <- rows do
    @table table
    @row row
    if reason = row["elixir"], do: @tag(skip: reason)

    test "#{table} #{row["id"]}" do
      assert decide(@table, @row) == @row["expect"]
    end
  end

  test "every prepare row is asserted here; none is legacy-only" do
    counts =
      for table <- @tables do
        rows = S6Fixture.load_table!(Path.join(@dir, table))["rows"]
        assert Enum.all?(rows, &(not Map.has_key?(&1, "elixir")))
        {table, length(rows)}
      end

    assert counts == [{"plan.json", 84}, {"ready.json", 36}, {"runner.json", 21}]
  end

  describe "the setup spec of a plan (A2e's Spec.codex_sandbox(:setup, …), A2g's setup rows)" do
    for id <- ["runner.ci-runs", "runner.run-runs"] do
      @id id
      test "#{id}: the planned run's setup spec writes exactly its outputs and scratch, with the A2g row's network" do
        row = runner_row(@id)
        {places, input, environment} = set_up(row)
        step = step(input)

        facts =
          SpecRows.with_env(environment, fn ->
            Facts.fetch(
              "prepare",
              [input["dest"], input["home"], input["path"]],
              Preparation.facts_input(step)
            )
          end)

        {:ok, plan} = Preparation.plan(step, facts, env: caller(environment), now: "{now}")
        scratch = Path.join([input["home"], "scratch", "prepare-s6"])
        File.mkdir_p!(scratch)

        scope = %{
          "home" => input["home"],
          "profile" => "materialized-folder",
          "repositories" => facts["folder"]["repositories"],
          "root" => facts["folder"]["root"],
          "snapshot_id" => facts["folder"]["snapshot_id"],
          "version" => 1
        }

        request = Preparation.setup_request(plan, scope, scratch)

        launch =
          SpecRows.with_env(environment, fn ->
            Facts.fetch("launch", [], Spec.facts_input(request))
          end)

        assert {:ok, spec} = Spec.codex_sandbox(:setup, request, launch)
        writes = for [path, "write"] <- spec["codex"]["entries"], do: path
        assert writes == plan["writable"] ++ [scratch]
        assert request["argv"] == plan["argv"]
        assert hd(plan["argv"]) == Path.join(places["tmp"], "bin/npm")

        a2g = a2g_spec(plan["setup_row"])
        assert a2g["kind"] == "setup" and a2g["runner"] == "codex-sandbox"

        for key <- ["profile", "base", "network", "network_proxy", "web_search"],
            do: assert(spec["codex"][key] == a2g["codex"][key], key)

        assert spec["runtime_home"] == input["home"]
        assert spec["env"] == a2g["env"]
      end
    end
  end

  describe "the facts kind prepare (B4)" do
    test "reports the lockfile raw, without applying the registry rule" do
      row = Enum.find(rows("plan.json"), &(&1["id"] == "ci.lock-git-resolved"))
      {_places, input, _env} = set_up(row)

      facts =
        Facts.fetch(
          "prepare",
          [input["dest"], input["home"], input["path"]],
          Preparation.facts_input(:npm_ci)
        )

      package = facts["lockfile"]["packages"]["node_modules/x"]
      assert package["resolved"] == "git+https://registry.npmjs.org/x.git"
      assert package["url"]["scheme"] == "git+https"
      refute Map.has_key?(facts["lockfile"], "error")
    end

    test "lstats exactly the outputs passed in" do
      row = Enum.find(rows("plan.json"), &(&1["id"] == "run.ok"))
      {_places, input, _env} = set_up(row)

      facts =
        Facts.fetch("prepare", [input["dest"], input["home"], input["path"]], %{
          "outputs" => ["repo/app/s6-only-here"],
          "tools" => []
        })

      assert facts["outputs"] == [
               %{
                 "output" => "repo/app/s6-only-here",
                 "chain" => [
                   %{"rel" => "repo", "type" => "dir"},
                   %{"rel" => "repo/app", "type" => "dir"},
                   %{"rel" => "repo/app/s6-only-here", "type" => "absent"}
                 ]
               }
             ]

      assert facts["tools"] == []
    end

    test "refuses only a malformed request" do
      assert_raise RuntimeError, "use workspace facts prepare DEST HOME PATH", fn ->
        Facts.fetch("prepare", ["/a"])
      end
    end
  end

  # Running a row

  defp decide("plan.json", row) do
    {places, input, _environment} = set_up(row)
    step = step(input)

    facts =
      Facts.fetch(
        "prepare",
        [input["dest"], input["home"], input["path"]],
        Preparation.facts_input(step)
      )

    case Preparation.begin_record(step, facts, now: "{now}") do
      {:ok, record} -> abstract(places, input, %{"record" => record})
      {:error, text} -> abstract(places, input, %{"error" => text})
    end
  end

  defp decide("ready.json", row) do
    {places, input, _environment} = set_up(row)

    result =
      case Preparation.load(%{"raw" => input["record"]}, input["home"], input["dest"]) do
        {:error, text} ->
          %{"error" => text}

        {:ok, record} ->
          if Preparation.ready?(record),
            do: %{"ready" => true},
            else: %{
              "ready" => false,
              "not_ready" => Preparation.not_ready_text(record, input["home"])
            }
      end

    abstract(places, input, result)
  end

  defp decide("runner.json", row) do
    {places, input, environment} = set_up(row)
    step = step(input)

    facts =
      SpecRows.with_env(environment, fn ->
        Facts.fetch(
          "prepare",
          [input["dest"], input["home"], input["path"]],
          Preparation.facts_input(step)
        )
      end)

    result =
      case Preparation.plan(step, facts, env: caller(environment), now: "{now}") do
        {:ok, plan} -> %{"run" => plan}
        {:repeat, result, error} -> %{"repeat" => %{"result" => result, "error" => error}}
        {:error, text} -> %{"error" => text}
      end

    abstract(places, input, result)
  end

  defp step(%{"step" => "npm-ci"}), do: :npm_ci
  defp step(%{"step" => "npm-run"} = input), do: {:npm_run, input["script"], input["outputs"]}

  # The caller's environment as the runner reads it: unset names are absent.
  defp caller(environment),
    do: for({name, value} <- environment, value != "", into: %{}, do: {name, value})

  # Set-up, as the Go tests set a row up: the tree, the materialization record and the recorded
  # preparation result (with its private diagnostics directory), each named by the hash of the
  # folder's path. Runner rows get HOME={user} and PATH={tmp}/bin before the row's env.
  defp set_up(row) do
    {root, places} = S6Fixture.build_row!(row)

    for dir <- [places["home"], places["user"], Path.join(root, "bin"), Path.join(root, "log")],
        do: File.mkdir_p!(dir)

    input = S6Fixture.substitute_value(places, row["input"])

    if materialized = input["materialized"] do
      write!(
        Path.join([input["home"], "materializations", hash(materialized["dest"]) <> ".json"]),
        %{"destination" => materialized["dest"], "snapshot_id" => materialized["snapshot_id"]}
      )
    end

    if recorded = input["recorded"] do
      write!(Preparation.result_path(input["home"], input["dest"]), recorded)

      private =
        Path.join(Path.dirname(Preparation.result_path(input["home"], input["dest"])), "private")

      File.mkdir!(private)
      File.chmod!(private, 0o700)
    end

    environment =
      %{"HOME" => "{user}", "PATH" => "{tmp}/bin"}
      |> Map.merge(row["env"] || %{})
      |> Map.new(fn {name, value} -> {name, S6Fixture.substitute(places, value)} end)

    {places, input, environment}
  end

  defp write!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    File.write!(path, JSON.encode!(value))
    File.chmod!(path, 0o600)
  end

  defp hash(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)

  defp abstract(places, input, value) do
    token = "{sha256:" <> S6Fixture.abstract(places, input["dest"]) <> "}"
    digest = hash(input["dest"])

    places
    |> S6Fixture.abstract_value(value)
    |> map_strings(&String.replace(&1, digest, token))
  end

  defp map_strings(value, f) when is_binary(value), do: f.(value)
  defp map_strings(value, f) when is_list(value), do: Enum.map(value, &map_strings(&1, f))

  defp map_strings(value, f) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, map_strings(item, f)} end)

  defp map_strings(value, _f), do: value

  defp rows(table), do: S6Fixture.load_table!(Path.join(@dir, table))["rows"]
  defp runner_row(id), do: Enum.find(rows("runner.json"), &(&1["id"] == id))

  defp a2g_spec(id) do
    row =
      S6Fixture.dir()
      |> Path.join("spec/codex_sandbox.json")
      |> S6Fixture.load_table!()
      |> Map.fetch!("rows")
      |> Enum.find(&(&1["id"] == id))

    row["expect"]["spec"]
  end
end
