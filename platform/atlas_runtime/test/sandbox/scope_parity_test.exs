defmodule AtlasRuntime.Sandbox.ScopeParityTest do
  # S6 A1: AtlasRuntime.Sandbox.Scope decides every row of test/fixtures/s6/scope/*.json on the
  # facts of the real helper (`workspace facts dedicated|folder`), and must reach the result the
  # legacy Go decision reached (host/workspace/s6_scope_parity_test.go, which wrote `expect`).
  #
  # The row conventions are the Go test's: the baseline env below plus the row's env ("{unset}"
  # unsets), input.records written after the fs spec, and record digests abstracted to
  # {sha256:<dest>}. Not async: the helper inherits this VM's environment, which each row sets.
  use ExUnit.Case, async: false

  alias AtlasRuntime.S6Fixture
  alias AtlasRuntime.Sandbox.{Facts, Scope}

  @scope Path.join(S6Fixture.dir(), "scope")
  @tables ["dedicated", "folder"]

  for table <- @tables do
    path = Path.join(@scope, table <> ".json")
    @external_resource path

    for row <- S6Fixture.load_table!(path)["rows"] do
      @row row
      @table table
      if reason = row["elixir"], do: @tag(skip: "legacy-only: #{reason}")

      test "#{table} row #{row["id"]}" do
        {root, places} = S6Fixture.build_row!(@row)
        input = S6Fixture.substitute_value(places, @row["input"])
        write_records!(input)
        result = with_row_env(places, @row, fn -> decide(@table, input) end)
        result = table_value(result, places, input)

        refute JSON.encode!(result) =~ root
        assert result == @row["expect"]
      end
    end
  end

  test "a system Codex config is refused like a project one" do
    # /etc/codex/config.toml cannot be created by a test, so the Go table has no row for it;
    # this decides on real facts with that one candidate reported present.
    {_root, places} =
      S6Fixture.build_row!(%{"id" => "etc", "fs" => [dir("{user}"), git("{tmp}/repo")]})

    facts =
      with_row_env(places, %{}, fn ->
        Facts.fetch("dedicated", [S6Fixture.substitute(places, "{tmp}/repo")])
      end)

    assert is_map(Scope.dedicated(facts))

    candidates = facts["codex_config"]["candidates"]
    assert %{"path" => "/etc/codex/config.toml", "exists" => false} = List.last(candidates)

    etc =
      put_in(
        facts["codex_config"]["candidates"],
        List.replace_at(candidates, -1, %{"path" => "/etc/codex/config.toml", "exists" => true})
      )

    assert Scope.dedicated(etc) ==
             {:error, "Dedicated repository cannot load project or system Codex config"}

    # The same candidate is skipped when it is the user's own (ignored) Codex config.
    ignored = put_in(etc["codex_config"]["ignored"], %{"path" => "/etc/codex/config.toml"})
    assert is_map(Scope.dedicated(ignored))
  end

  test "a Runtime-chosen folder is not decided before S6 C0d" do
    assert_raise ArgumentError, "Runtime-chosen folder scopes are decided from S6 C0d on", fn ->
      Scope.folder(%{}, {:runtime_chosen, "w1"})
    end
  end

  defp decide("dedicated", %{"origin" => %{"runtime_chosen" => %{"work" => work}}, "path" => path})
       when is_binary(work),
       do: Scope.dedicated(Facts.fetch("dedicated", [path]))

  defp decide("folder", %{"origin" => "client_named", "dest" => dest, "home" => home}),
    do: Scope.folder(Facts.fetch("folder", [dest, home]), :client_named)

  defp dir(path), do: %{"path" => path, "type" => "dir"}
  defp git(path), do: %{"path" => path, "type" => "git"}

  # The scope, or {"error": text}, abstracted like the Go test abstracts it.
  defp table_value(result, places, input) do
    value =
      case result do
        {:error, text} when is_binary(text) -> %{"error" => text}
        scope when is_map(scope) -> scope
      end

    digests =
      for %{"dest" => dest} <- Map.get(input, "records", []),
          into: %{},
          do: {sha256(dest), "{sha256:#{S6Fixture.abstract(places, dest)}}"}

    places |> S6Fixture.abstract_value(value) |> replace_digests(digests)
  end

  defp replace_digests(value, digests) when is_binary(value),
    do:
      Enum.reduce(digests, value, fn {digest, name}, acc -> String.replace(acc, digest, name) end)

  defp replace_digests(value, digests) when is_list(value),
    do: Enum.map(value, &replace_digests(&1, digests))

  defp replace_digests(value, digests) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, replace_digests(item, digests)} end)

  defp replace_digests(value, _digests), do: value

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  # input.records: files named by a destination's digest, which a static fs spec cannot name.
  defp write_records!(input) do
    for %{"store" => store, "home" => home, "dest" => dest, "content" => content} <-
          Map.get(input, "records", []) do
      path =
        case store do
          "materialization" -> Path.join([home, "materializations", sha256(dest) <> ".json"])
          "preparation" -> Path.join([home, "preparations", sha256(dest), "result.json"])
        end

      mkdirs!(Path.dirname(path))
      File.write!(path, content)
      File.chmod!(path, 0o644)
    end
  end

  defp mkdirs!(dir) do
    unless match?({:ok, _}, File.lstat(dir)) do
      mkdirs!(Path.dirname(dir))
      File.mkdir!(dir)
      File.chmod!(dir, 0o755)
    end
  end

  # The baseline env of every scope row (s6ScopeEnv in the Go test), then the row's env; every
  # other GIT_* variable is unset. The previous environment is restored afterwards.
  defp with_row_env(places, row, fun) do
    baseline = %{
      "HOME" => S6Fixture.substitute(places, "{user}"),
      "XDG_CONFIG_HOME" => S6Fixture.substitute(places, "{user}/config"),
      "CODEX_HOME" => S6Fixture.substitute(places, "{user}/.codex"),
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => "/dev/null"
    }

    row_env =
      Map.new(Map.get(row, "env", %{}), fn {k, v} -> {k, S6Fixture.substitute(places, v)} end)

    env = Map.merge(baseline, row_env)
    git = for {name, _} <- System.get_env(), String.starts_with?(name, "GIT_"), do: name
    names = Enum.uniq(git ++ Map.keys(env))
    previous = Map.new(names, &{&1, System.get_env(&1)})

    try do
      Enum.each(git, &System.delete_env/1)

      Enum.each(env, fn
        {name, "{unset}"} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
