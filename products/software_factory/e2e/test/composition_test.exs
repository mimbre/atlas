defmodule AtlasE2E.CompositionTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 120_000
  @root Path.expand("../../../..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas-composition-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp_r!(Path.join(@root, "bin"), Path.join(dir, "bin"))
    # Code is shared; all selected description files and mutable stores are private.
    # The checkout's layout with its code linked, as before the move. The folders that hold
    # something private, the umbrella's apps and the model are real folders here, their other
    # entries linked: the Rela scripts (platform/atlas_facts/rela) find the private project
    # (products/software_factory/model/targets/rela) beside them, and the umbrella, its apps and the
    # model see one another at the same paths. The umbrella builds in the checkout's _build.
    File.mkdir_p!(Path.join(@root, "products/software_factory/_build"))

    apps =
      for name <- File.ls!(Path.join(@root, "platform")),
          String.starts_with?(name, "atlas_"),
          do: "platform/" <> name

    real = [
      "platform",
      "products/software_factory",
      "products/software_factory/model",
      "products/software_factory/model/contract" | apps
    ]

    private = [
      "platform/atlas_facts/rela",
      "products/software_factory/model/targets",
      "products/software_factory/environments",
      "products/software_factory/e2e"
    ]

    for folder <- real,
        name <- File.ls!(Path.join(@root, folder)),
        path = Path.join(folder, name),
        path not in real and path not in private do
      File.mkdir_p!(Path.join(dir, folder))
      File.ln_s!(Path.join(@root, path), Path.join(dir, path))
    end

    sockets = for _ <- 1..2, do: elem(:gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}]), 1)
    [rela_port, control_port] = Enum.map(sockets, &elem(:inet.port(&1), 1))
    Enum.each(sockets, &:gen_tcp.close/1)

    bin = AtlasE2E.Instance.rela_bin!()

    github = AtlasE2E.GitHub.start()

    settings = %{
      "env" => "test",
      "tui_user" => "tester",
      # Who decides what a person decides (the model names only the role).
      "actors" => %{"decider" => "tester"},
      "control" => %{"host" => "127.0.0.1", "port" => control_port},
      "rela" => %{
        "url" => "http://127.0.0.1:#{rela_port}/api/v1",
        "port" => rela_port,
        "data" => Path.join(dir, "store/rela"),
        "bin" => bin
      },
      "facts" => %{"data" => Path.join(dir, "store/beam")},
      "flow" => %{"tick_seconds" => 1},
      "connectors" => %{
        "github" => %{
          "api" => github,
          "token_command" => ["echo", AtlasE2E.GitHub.token()],
          "every_seconds" => 1
        }
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

  # Read the private native store directly: Control deliberately refuses unscoped
  # guidance reads. Markdown paths are empty with the SQLite backend.
  defp stored_records(ctx) do
    settings = Path.join(ctx.dir, "test.json") |> File.read!() |> JSON.decode!()
    url = settings["rela"]["url"]
    {schema, 0} = System.cmd("curl", ["-fsS", url <> "/_schema"])

    for {kind, spec} <- JSON.decode!(schema)["entities"], into: %{} do
      {json, 0} = System.cmd("curl", ["-fsS", url <> "/" <> spec["plural"]])
      response = JSON.decode!(json)
      records = response["data"]
      assert is_list(records)
      assert response["meta"]["has_more"] == false
      {kind, Enum.sort_by(records, & &1["id"])}
    end
  end

  # The profiles are private compositions of the model (products/software_factory/model/contract/profiles), compiled
  # in its test environment only; mix model.gen writes the Rela project of one.
  @profiles %{
    "foundation" => "Model.Profiles.Foundation",
    "incident" => "Model.Profiles.Incident"
  }

  defp start(ctx, profile) do
    {out, status} =
      System.cmd(
        "mix",
        [
          "model.gen",
          "--contract",
          @profiles[profile],
          "--out",
          Path.join(ctx.dir, "products/software_factory/model/targets/rela")
        ],
        cd: Path.join(@root, "products/software_factory/model/contract"),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    File.mkdir_p!(Path.join(ctx.dir, "platform/atlas_facts/rela"))

    File.cp_r!(
      Path.join(@root, "platform/atlas_facts/rela/scripts"),
      Path.join(ctx.dir, "platform/atlas_facts/rela/scripts")
    )

    # Flow and Gates run the profile itself (the compiled model), not Model.AtlasEyra.
    settings = Path.join(ctx.dir, "test.json")

    File.write!(
      settings,
      settings
      |> File.read!()
      |> JSON.decode!()
      |> Map.put("model", @profiles[profile])
      |> JSON.encode!()
    )

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
             ~w(agent assignment decision flow_input flow_run gate_verdict interaction interaction_receipt machinery person task task_attempt to_do turn worker_execution)

    tools = command(ctx, ["tools"]) |> JSON.encode!()

    for name <- ["scene", "use_case", "issue", "pull_request", "accepted_by"],
        do: refute(tools =~ name)

    person = command(ctx, ["put", "person", "--name", "Tester"])
    assert person["key"] == "tester"

    # IS-124: the real CLI/Control/Facts chain preserves the scope guard. The smoke
    # client reads this private composition and creates no guidance records.
    before = stored_records(ctx)
    assert Enum.any?(before["person"], &(&1["id"] == "tester"))
    python = System.get_env("ATLAS_CONFIG_PYTHON") || "python3"

    {out, status} =
      System.cmd(
        python,
        [
          Path.join(@root, "platform/ops/smoke-reads.py"),
          Path.join(ctx.dir, "bin/atlas"),
          Path.join(ctx.dir, "products/software_factory/model/targets/rela/atlas.json"),
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

    assert before == stored_records(ctx)
  end

  test "incident uses merged Issues, with independent person resolution", ctx do
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
