Code.require_file("spec_rows.exs", __DIR__)

defmodule AtlasRuntime.Sandbox.SpecSecurityTest do
  # S6 package A2e, plan §6: the security properties of the Elixir specs, checked on every
  # Elixir row of test/fixtures/s6/spec/ independently of the expected values (parity is
  # spec_parity_test.exs). Paths are compared in their abstract form ({home}, {user}, …).
  # Not async: the rows' facts are fetched under the rows' environments.
  use ExUnit.Case, async: false

  alias AtlasRuntime.SpecRows
  alias AtlasRuntime.Sandbox.{HomeLayout, Spec}

  for path <- SpecRows.table_paths(), do: @external_resource(path)

  setup_all do
    specs =
      for {table, row} <- SpecRows.elixir_rows() do
        {table <> " " <> row["id"], row, SpecRows.run(row).got}
      end

    %{specs: for({name, row, %{"spec" => spec}} <- specs, do: {name, row, spec})}
  end

  test "the rows decide a spec where the table has one", %{specs: specs} do
    with_spec =
      for {_, row} <- SpecRows.elixir_rows(), Map.has_key?(row["expect"], "spec"), do: row["id"]

    assert Enum.map(specs, fn {_, row, _} -> row["id"] end) == with_spec
    assert length(specs) >= 50
  end

  # SP1: the deny set equals the table's expect.spec, the legacy Go set after P0 (TestS6RenderParity
  # asserts it against the legacy Go entry lists, whose sensitiveHomeNames ends with the atomic temps).
  test "SP1 deny sets equal the expected (legacy after P0) deny sets", %{specs: specs} do
    for {name, row, spec} <- specs do
      assert deny_set(spec) == deny_set(row["expect"]["spec"]), name
    end
  end

  # SP2: every HomeLayout name is denied: the whole home, or each denied name by path where
  # the home contains the workspace. The one form that denies the sockets alone is a plain
  # Claude read-only turn below the home: no Bash, file tools confined by --restricted and
  # Read rules on the sockets (claude.go:483-486; A2g report, finding 3). It is listed, so a
  # new exception fails.
  test "SP2 every home name is denied in every spec", %{specs: specs} do
    exceptions =
      for {name, _row, spec} <- specs, not home_denied?(spec) do
        assert spec["harness"] == "claude" and spec["claude"]["settings"]["sandbox"] == nil, name
        assert spec["home_names"] == HomeLayout.sockets(), name
        assert spec["claude"]["tools"] == ["Read", "Glob", "Grep"], name

        for socket <- HomeLayout.sockets(),
            do: assert(denied?(spec, spec["runtime_home"] <> "/" <> socket), name)

        name
      end

    assert exceptions == ["claude.json claude.plain-read-only-below-home"]
  end

  # Claude denies a managed repository's home whole to Bash reads and re-allows the repository
  # (claude.go:253-257); a Codex profile cannot, so it denies every name by path, the atomic
  # temps included (P0 fix decision), and lists them all as its home_names.
  test "SP2 a Codex managed repository denies every HomeLayout denied name and atomic temp by path, the chain excepted",
       %{specs: specs} do
    managed =
      for {name, row, spec} <- specs,
          spec["harness"] == "codex",
          row["input"]["scope"]["profile"] == "dedicated-repository",
          inside?(spec["runtime_home"] <> "/workers", spec["workspace"]["root"]),
          do: {name, spec}

    assert length(managed) >= 5

    for {name, spec} <- managed do
      home = spec["runtime_home"]
      refute denied?(spec, home), name

      assert spec["home_names"] == HomeLayout.managed_denied(), name

      for entry <- HomeLayout.managed_denied(),
          do: assert(denied?(spec, home <> "/" <> entry), "#{name}: #{entry}")

      refute denied?(spec, home <> "/workers"), name
    end
  end

  # SP3: no socket reachable: Codex Unix sockets only the turn's scratch, Claude only the private
  # temp, never all sockets.
  test "SP3 Unix sockets only in the turn's own scratch or private temp", %{specs: specs} do
    for {name, _, spec} <- specs do
      case spec do
        %{"codex" => %{"network" => network}} ->
          assert network["unix_sockets"] in [[], [spec["scratch"]]], name

          if network["unix_sockets"] != [],
            do:
              assert(
                String.starts_with?(spec["scratch"], spec["runtime_home"] <> "/scratch/"),
                name
              )

        %{"claude" => %{"settings" => %{"sandbox" => %{"network" => network}}}} ->
          assert network["allowAllUnixSockets"] == false, name
          assert Map.get(network, "allowUnixSockets", []) -- [Spec.temporary_token()] == [], name

        %{"claude" => _} ->
          :ok
      end
    end
  end

  # SP4: inside the home only the turn's own scratch and a Runtime-chosen root are written; no
  # write inside a credential path; the inspector is never writable. A client-named workspace
  # inside the home (plain workspace-write below it) is today's legacy grant, which render
  # refuses (B8 b, the row's change "B8b"); it is the only one.
  test "SP4 writes stay out of the home, the credentials and the inspector", %{specs: specs} do
    violations =
      for {name, row, spec} <- specs,
          path <- writes(spec),
          inside?(spec["runtime_home"], path),
          not (spec["scratch"] != "" and inside?(spec["scratch"], path)),
          not (spec["workspace"]["origin"] == "runtime_chosen" and
                 inside?(spec["workspace"]["root"], path)),
          do: {name, row["change"], path}

    assert violations == [
             {"codex.json codex.plain-workspace-write-below-home", "B8b", "{home}/workers/w1"}
           ]

    credentials = Enum.map(Spec.credential_paths(), &("{user}/" <> &1))

    for {name, row, spec} <- specs, path <- writes(spec) do
      for credential <- credentials, do: refute(inside?(credential, path), "#{name}: #{path}")
      inspector = row["input"]["inspector"]
      if inspector, do: refute(inside?(path, inspector), "#{name}: inspector in #{path}")
    end
  end

  # SP5: no backend token or client list reaches a worker; ATLAS_RUNTIME_HOME is always unset
  # first; clients.json is a denied name.
  test "SP5 the environment carries no backend token and unsets ATLAS_RUNTIME_HOME", %{
    specs: specs
  } do
    assert HomeLayout.class("clients.json") == :denied

    for {name, _, spec} <- specs do
      env = spec["env"]
      assert "ATLAS_RUNTIME_HOME" in env["unset"], name
      names = for [variable, _] <- env["set"], do: variable
      refute "ATLAS_RUNTIME_BACKEND_TOKEN" in names, name

      refute Enum.any?(env["set"], fn [_, value] -> String.contains?(value, "clients.json") end),
             name
    end
  end

  # SP6 (IS-Atlas-56): an agent's network is its machine's route to Control and no other host.
  # An agent in a materialized folder (the work folder of every task a Runtime runs) reaches
  # Control on this machine's loopback (`bin/atlas`: 127.0.0.1:control.port, kept open by
  # the machine's Fly proxy) and names no host: Codex's loopback table, Claude's empty
  # strict allowlist with loopback. A dedicated repository reaches Git's hosts only, a plain
  # turn nothing. No spec allows any other host, or every host.
  test "SP6 an agent reaches Control's loopback route and no other host", %{specs: specs} do
    git = ["github.com", "api.github.com"]

    folders =
      for {name, row, spec} <- specs,
          spec["runner"] == nil,
          get_in(row, ["input", "scope", "profile"]) == "materialized-folder" do
        case spec do
          %{"codex" => %{"network" => network}} ->
            assert network["mode"] == "loopback", name
            assert network["domains"] == [], name
            assert network["local_binding"] == true, name

          %{"claude" => %{"settings" => %{"sandbox" => %{"network" => network}}}} ->
            assert network["allowedDomains"] == [], name
            assert network["strictAllowlist"] == true, name
            assert network["allowLocalBinding"] == true, name
        end

        name
      end

    assert Enum.any?(folders, &String.starts_with?(&1, "codex.json")), "no Codex folder row"
    assert Enum.any?(folders, &String.starts_with?(&1, "claude.json")), "no Claude folder row"

    for {name, _row, spec} <- specs do
      case spec do
        %{"codex" => %{"network" => %{"mode" => "domains", "domains" => domains}}} ->
          assert domains -- (git ++ ["registry.npmjs.org"]) == [], name

        %{"codex" => %{"network" => %{"mode" => mode, "domains" => []}}} ->
          assert mode in ["none", "loopback"], name

        %{"claude" => %{"settings" => %{"sandbox" => %{"network" => network}}}} ->
          assert network["allowedDomains"] -- git == [], name
          refute "*" in network["allowedDomains"], name

        %{"claude" => %{"settings" => %{"sandbox" => nil}}} ->
          :ok

        %{"claude" => %{"settings" => settings}} ->
          refute Map.has_key?(settings, "sandbox") and settings["sandbox"] != nil, name
      end
    end
  end

  # Deny and write sets

  defp deny_set(%{"codex" => codex}) do
    for {path, "none"} <- first_access(codex["entries"]), into: MapSet.new(), do: path
  end

  defp deny_set(%{"claude" => %{"settings" => settings}}) do
    filesystem = get_in(settings, ["sandbox", "filesystem"]) || %{}

    %{
      deny_read: MapSet.new(filesystem["denyRead"] || []),
      deny_write: MapSet.new(filesystem["denyWrite"] || []),
      rules: MapSet.new(settings["permissions"]["deny"] || [])
    }
  end

  defp first_access(entries) do
    Enum.reduce(entries, %{}, fn [path, access], acc -> Map.put_new(acc, path, access) end)
  end

  defp denied?(%{"codex" => codex}, path), do: first_access(codex["entries"])[path] == "none"

  defp denied?(%{"claude" => %{"settings" => settings}}, path) do
    ("Read(/" <> path <> ")") in (settings["permissions"]["deny"] || []) or
      path in (get_in(settings, ["sandbox", "filesystem", "denyRead"]) || [])
  end

  defp home_denied?(%{"runtime_home" => home} = spec) do
    denied?(spec, home) or
      (inside?(home, spec["workspace"]["root"]) and
         Enum.all?(HomeLayout.managed_denied(), &denied?(spec, home <> "/" <> &1)))
  end

  defp writes(%{"codex" => codex}),
    do: for({path, "write"} <- first_access(codex["entries"]), do: path)

  defp writes(%{"claude" => %{"settings" => settings}}),
    do: get_in(settings, ["sandbox", "filesystem", "allowWrite"]) || []

  defp inside?(dir, path), do: Spec.within?(dir, path)
end
