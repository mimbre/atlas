defmodule AtlasRuntime.Sandbox.RepositoryParityTest do
  # S6 package A4: AtlasRuntime.Sandbox.Repository decides every row of the shared tables in
  # test/fixtures/s6/repository as the legacy Go code does (host/workspace,
  # TestS6RepositoryRequestParity and TestS6RepositoryPlanParity):
  #
  #   * request.json: request/4 on the facts of `workspace facts repository` == expect;
  #   * plan.json: plan/3 == expect.plan, the plan Go's RunPlan executes to the same git argv
  #     log, outcome and marker as legacy workspace.Prepare.
  #
  # The facts come from the real helper (ATLAS_RUNTIME_EXECUTABLE, built by test_helper.exs) on
  # the row's tree. Not async: git is kept off the user's and system config through the
  # environment the helper inherits, as on the Go side (s6GitEnv).
  use ExUnit.Case, async: false

  alias AtlasRuntime.S6Fixture
  alias AtlasRuntime.Sandbox.{Facts, Repository}

  @dir Path.join(S6Fixture.dir(), "repository")
  @external_resource Path.join(@dir, "request.json")
  @external_resource Path.join(@dir, "plan.json")
  @request_rows S6Fixture.load_table!(Path.join(@dir, "request.json"))["rows"]
  @plan_rows S6Fixture.load_table!(Path.join(@dir, "plan.json"))["rows"]

  defp git_env(places) do
    env = %{
      "HOME" => places["user"],
      "XDG_CONFIG_HOME" => places["user"] <> "/config",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "CODEX_HOME" => places["user"] <> "/.codex"
    }

    previous = Map.new(env, fn {name, _} -> {name, System.get_env(name)} end)
    System.put_env(env)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp facts(home, url, branch) do
    {args, input} = Repository.facts_request(home, url, branch)
    Facts.fetch("repository", args, input)
  end

  defp result({:ok, value}, key), do: %{key => value}
  defp result({:error, text}, _key), do: %{"error" => text}

  for row <- @request_rows, not String.starts_with?(Map.get(row, "elixir", ""), "skip:") do
    @row row
    test "request row #{row["id"]}" do
      {root, places} = S6Fixture.build_row!(@row)
      git_env(places)

      %{"home" => home, "url" => url, "branch" => branch} =
        S6Fixture.substitute_value(places, @row["input"])

      got =
        Repository.request(home, url, branch, facts(home, url, branch))
        |> result("request")
        |> then(&S6Fixture.abstract_value(places, &1))

      refute JSON.encode!(got) =~ root
      assert got == @row["expect"]
    end
  end

  for row <- @plan_rows, not String.starts_with?(Map.get(row, "elixir", ""), "skip:") do
    @row row
    test "plan row #{row["id"]}" do
      {root, places} = S6Fixture.build_row!(@row)
      git_env(places)

      %{"scope" => scope, "repository" => repository} =
        S6Fixture.substitute_value(places, @row["input"])

      decided =
        with {:ok, home} <- Repository.plan_home(scope, repository) do
          facts = facts(home, repository["url"], repository["branch"])
          Repository.plan(scope, repository, facts)
        end

      got = decided |> result("plan") |> then(&S6Fixture.abstract_value(places, &1))
      got = if Map.has_key?(got, "plan"), do: got["plan"], else: got

      refute JSON.encode!(got) =~ root
      assert got == @row["expect"]["plan"]
    end
  end

  test "the tables have no legacy-only rows (every row is asserted on both sides)" do
    assert Enum.filter(@request_rows ++ @plan_rows, &Map.has_key?(&1, "elixir")) == []
  end

  test "facts_request asks for the managed path only when the URL names one" do
    assert Repository.facts_request("/h", "https://github.com/Eyra/Atlas.git", "b") ==
             {["/h", "b"], %{"paths" => ["repositories/eyra/atlas"]}}

    assert Repository.facts_request("/h", "https://example.com/a/b", "b") ==
             {["/h", "b"], %{"paths" => []}}
  end

  test "the facts kind refuses malformed arguments and input" do
    assert_raise RuntimeError, "workspace facts repository requires home and branch", fn ->
      Facts.fetch("repository", ["/h"])
    end

    assert_raise RuntimeError,
                 ~s(workspace facts repository: stdin must be {"paths": [...]}),
                 fn ->
                   Facts.fetch("repository", ["/h", "b"], %{"names" => []})
                 end
  end
end
