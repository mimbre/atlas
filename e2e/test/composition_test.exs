defmodule AtlasE2E.CompositionTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 120_000
  @root Path.expand("../..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas-composition-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp_r!(Path.join(@root, "bin"), Path.join(dir, "bin"))
    # Code is shared; all selected description files and mutable stores are private.
    for folder <- ["beam", "bff", "clients", "tools"],
        do: File.ln_s!(Path.join(@root, folder), Path.join(dir, folder))

    sockets = for _ <- 1..2, do: elem(:gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}]), 1)
    [rela_port, control_port] = Enum.map(sockets, &elem(:inet.port(&1), 1))
    Enum.each(sockets, &:gen_tcp.close/1)

    bin =
      System.get_env("ATLAS_E2E_RELA_BIN") ||
        Path.join(System.user_home!(), ".local/share/atlas/test/bin")

    github = AtlasE2E.GitHub.start()
    File.mkdir_p!(Path.join(dir, "stub"))

    settings = %{
      "env" => "test",
      "tui_user" => "tester",
      "control" => %{"host" => "127.0.0.1", "port" => control_port},
      "rela" => %{
        "url" => "http://127.0.0.1:#{rela_port}/api/v1",
        "port" => rela_port,
        "data" => Path.join(dir, "store/rela"),
        "bin" => bin,
        "extra" => "rela/atlas.json"
      },
      "state" => %{"data" => Path.join(dir, "store/beam")},
      "flow" => %{"tick_seconds" => 1},
      "connectors" => %{
        "github" => %{
          "api" => github,
          "token_command" => ["echo", AtlasE2E.GitHub.token()],
          "every_seconds" => 1
        }
      },
      "runtime" => %{
        "machine" => "fixture",
        "agents" => %{"runner" => %{"port" => "stub"}},
        "stub_dir" => Path.join(dir, "stub"),
        "round_seconds" => 1,
        "lease_seconds" => 1
      }
    }

    file = Path.join(dir, "test.json")
    File.write!(file, JSON.encode!(settings))
    env = [{"ATLAS_ENV_FILE", file}, {"ATLAS_NO_UPDATE", "1"}, {"MIX_ENV", "dev"}]
    ctx = %{dir: dir, env: env}

    on_exit(fn ->
      ops(ctx, ["stop", "--rela"])
      if Process.whereis(AtlasE2E.GitHub), do: Agent.stop(AtlasE2E.GitHub)
      File.rm_rf!(dir)
    end)

    ctx
  end

  defp atlas(ctx, args), do: run(ctx, "bin/atlas", args)
  defp ops(ctx, args), do: run(ctx, "bin/atlas-ops", args)

  defp run(ctx, command, args) do
    System.cmd(Path.join(ctx.dir, command), args ++ ["--env", "test"],
      env: ctx.env,
      stderr_to_stdout: true
    )
  end

  defp command(ctx, args) do
    {out, status} = atlas(ctx, args ++ ["--json"])
    assert status == 0, out

    json =
      out
      |> String.split("\n")
      |> Enum.find(&(String.starts_with?(&1, "{") or String.starts_with?(&1, "[")))

    assert json, out
    JSON.decode!(json)
  end

  defp done?(ctx, key) do
    Enum.any?(command(ctx, ["get", key])["fields"], fn [label, value] ->
      label == "Progress" and String.starts_with?(value, "Done")
    end)
  end

  defp start(ctx, profile) do
    python = System.get_env("ATLAS_CONFIG_PYTHON") || "python3"

    {out, status} =
      System.cmd(
        python,
        [Path.join(@root, "rela/tests/profiles.py"), profile, Path.join(ctx.dir, "rela")],
        stderr_to_stdout: true
      )

    assert status == 0, out
    File.cp_r!(Path.join(@root, "rela/scripts"), Path.join(ctx.dir, "rela/scripts"))
    {out, status} = ops(ctx, ["restart"])
    assert status == 0, out
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("private composition did not reach expected state")
      true -> Process.sleep(100) && eventually(fun, tries - 1)
    end
  end

  test "foundation alone serves Control tools without software or Eyra", ctx do
    start(ctx, "foundation")
    kinds = command(ctx, ["help"]) |> Enum.map(& &1["kind"])

    assert Enum.sort(kinds) ==
             ~w(agent assignment decision interaction interaction_receipt person turn worker_execution)

    tools = command(ctx, ["tools"]) |> JSON.encode!()

    for name <- ["scene", "use_case", "issue", "pull_request", "accepted_by"],
        do: refute(tools =~ name)

    person = command(ctx, ["put", "person", "--name", "Tester"])
    assert person["key"] == "tester"

    # IS-124: the real CLI/Control/State chain preserves the scope guard. The smoke
    # client reads this private composition and creates no guidance records.
    before = Path.wildcard(Path.join(ctx.dir, "store/rela/entities/**/*.md"))
    python = System.get_env("ATLAS_CONFIG_PYTHON") || "python3"

    {out, status} =
      System.cmd(
        python,
        [
          Path.join(@root, "fly/smoke-reads.py"),
          Path.join(ctx.dir, "bin/atlas"),
          Path.join(ctx.dir, "rela/atlas.json"),
          "test",
          "private-foundation"
        ],
        env: ctx.env,
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "smoke: person: 1"

    for kind <- ["worker_execution", "interaction", "interaction_receipt"],
        do: assert(out =~ "#{kind}: scoped-read guard verified")

    assert before == Path.wildcard(Path.join(ctx.dir, "store/rela/entities/**/*.md"))
  end

  test "incident uses stub turns and merged Issues, with independent person resolution", ctx do
    start(ctx, "incident")
    kinds = command(ctx, ["help"]) |> Enum.map(& &1["kind"])
    assert "incident" in kinds
    refute "scene" in kinds
    refute "use_case" in kinds
    tools = command(ctx, ["tools"]) |> JSON.encode!()
    for name <- ["scene", "use_case", "accepted_by"], do: refute(tools =~ name)

    for {kind, name} <- [{"person", "Tester"}, {"agent", "Coordinator"}, {"agent", "Runner"}],
        do: command(ctx, ["put", kind, "--name", name])

    incident = command(ctx, ["put", "incident", "--title", "Restore exports"])["key"]
    issue = command(ctx, ["put", "issue", "--in", incident, "--title", "Repair timeout"])["key"]
    assert issue == "IS-Maint-01"
    eventually(fn -> command(ctx, ["list", "turn"]) != [] end)
    turn = command(ctx, ["list", "turn"]) |> hd() |> Map.fetch!("key")
    File.write!(Path.join(ctx.dir, "stub/runner"), "end")

    eventually(fn ->
      command(ctx, ["get", turn])["fields"] |> Enum.member?(["State", "Ended"])
    end)

    url = "https://github.com/example/incident-fixture/pull/1"

    AtlasE2E.GitHub.put(url, %{
      "title" => "Repair timeout",
      "state" => "open",
      "draft" => false,
      "merged" => false,
      "html_url" => url
    })

    command(ctx, ["put", "pull_request", "--in", issue, "--url", url])
    # Resolve service while its software follow-up is still open: unlike Eyra acceptance.
    command(%{ctx | env: ctx.env ++ [{"ATLAS_AS", "tester"}]}, [
      "set",
      incident,
      "resolved_by=tester"
    ])

    assert done?(ctx, incident)

    AtlasE2E.GitHub.put(url, %{
      "title" => "Repair timeout",
      "state" => "closed",
      "draft" => false,
      "merged" => true,
      "html_url" => url
    })

    eventually(fn -> done?(ctx, issue) end)
    assert done?(ctx, incident)
  end
end
