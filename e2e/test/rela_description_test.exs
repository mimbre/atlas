defmodule AtlasE2E.RelaDescriptionTest do
  # IS-Atlas-73: `atlas-ops restart` restarts rela when rela runs an older description than
  # the build, its data kept, and refuses when the build's description would leave data
  # without one. On a private instance (free ports, data in a temporary folder), never on
  # env/test.json's or env/prod.json's.
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  @root Path.expand("../..", __DIR__)

  # An older description: this build's, and a kind it no longer has.
  @gone """
    e2e_gone:
      label: Gone
      plural: e2e_gones
      aliases: [gone]
      id_type: manual
      id_prefix: "G-"
      description: A kind this build no longer has.
      properties:
        title: { type: string, required: true }
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas-rela-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    [rela_port, control_port] = free_ports(2)

    bin =
      System.get_env("ATLAS_E2E_RELA_BIN") ||
        Path.join(System.user_home!(), ".local/share/atlas/test/bin")

    settings = %{
      "env" => "test",
      "control" => %{"host" => "127.0.0.1", "port" => control_port},
      "rela" => %{
        "url" => "http://127.0.0.1:#{rela_port}/api/v1",
        "port" => rela_port,
        "data" => Path.join(dir, "rela"),
        "bin" => bin
      },
      "facts" => %{"data" => Path.join(dir, "beam")},
      "reconcile_seconds" => 5
    }

    file = Path.join(dir, "test.json")
    File.write!(file, JSON.encode!(settings))

    env = [
      {"ATLAS_ENV_FILE", file},
      {"ATLAS_NO_UPDATE", "1"},
      {"MIX_ENV", "dev"},
      {"ATLAS_RELA_PORT", "#{rela_port}"},
      {"ATLAS_RELA_DATA", Path.join(dir, "rela")},
      {"ATLAS_RELA_BIN", bin},
      {"ATLAS_TEST_ROOT", dir}
    ]

    on_exit(fn ->
      ops(env, ["stop", "--rela"])
      File.rm_rf!(dir)
    end)

    %{dir: dir, env: env, url: settings["rela"]["url"]}
  end

  defp ops(env, args),
    do:
      System.cmd(Path.join(@root, "bin/atlas-ops"), args ++ ["--env", "test"],
        env: env,
        stderr_to_stdout: true
      )

  # rela started as the scripts start it, but from a copy of rela/ whose description has
  # one kind more: what an earlier build left running.
  defp start_older_rela(%{dir: dir, env: env}) do
    old = Path.join(dir, "old-rela")
    File.mkdir_p!(old)
    File.cp_r!(Path.join(@root, "rela"), old)

    schema = Path.join(old, "schema.yaml")

    File.write!(
      schema,
      File.read!(schema) <> "\nentities:\n" <> @gone
    )

    # Its manifest records the changed schema.yaml, as the build that made it wrote it.
    manifest = Path.join(old, "atlas.manifest.json")
    sha = :crypto.hash(:sha256, File.read!(schema)) |> Base.encode16(case: :lower)
    record = JSON.decode!(File.read!(manifest)) |> put_in(["inputs", "schema.yaml"], sha)
    File.write!(manifest, JSON.encode!(record))

    {out, status} =
      System.cmd(Path.join(old, "scripts/start-bg.sh"), [], env: env, stderr_to_stdout: true)

    assert status == 0, out
  end

  defp kinds(url) do
    {json, 0} = System.cmd("curl", ["-fsS", url <> "/_schema"])
    json |> JSON.decode!() |> Map.fetch!("entities") |> Map.keys()
  end

  defp put(url, plural, id, title) do
    body = JSON.encode!(%{"id" => id, "properties" => %{"title" => title}})

    {_, 0} =
      System.cmd("curl", [
        "-fsS",
        "-X",
        "POST",
        "-H",
        "content-type: application/json",
        "-d",
        body,
        "#{url}/#{plural}"
      ])
  end

  test "rela on an older description is restarted on the build's; its data stays", ctx do
    start_older_rela(ctx)
    assert "e2e_gone" in kinds(ctx.url)
    put(ctx.url, "scenes", "SC-Atlas-01", "Kept across the restart")

    {out, 0} = ops(ctx.env, ["status"])

    assert out =~
             "description: older than this build's; atlas-ops restart --env test restarts rela"

    {out, status} = ops(ctx.env, ["restart"])
    assert status == 0, out

    assert out =~
             "atlas-ops: rela test ran an older description; restarted it on this build's (its data stays)"

    assert out =~ "atlas-ops: core ready"

    refute "e2e_gone" in kinds(ctx.url)
    assert "flow_run" in kinds(ctx.url)
    assert "flow_input" in kinds(ctx.url)
    {scene, 0} = System.cmd("curl", ["-fsS", ctx.url <> "/scenes/SC-Atlas-01"])
    assert scene =~ "Kept across the restart"

    {out, 0} = ops(ctx.env, ["status"])
    assert out =~ "description: this build's"

    # Nothing to do the second time.
    {out, 0} = ops(ctx.env, ["restart"])
    refute out =~ "older description"
  end

  test "include-only changes restart rela and preserve stored files byte for byte", ctx do
    {out, status} = ops(ctx.env, ["restart"])
    assert status == 0, out
    put(ctx.url, "scenes", "SC-Atlas-01", "Kept across an include-only restart")
    put(ctx.url, "use_cases", "UC-Atlas-01", "Kept child")

    {_, 0} =
      System.cmd("curl", [
        "-fsS",
        "-X",
        "PATCH",
        "-H",
        "content-type: application/json",
        "-d",
        JSON.encode!(%{
          "relations" => %{
            "in_scene" => %{"data" => [%{"type" => "scene", "id" => "SC-Atlas-01"}]}
          }
        }),
        ctx.url <> "/use_cases/UC-Atlas-01"
      ])

    data = Path.join(ctx.dir, "rela")
    # Stop the private core to avoid background reconciliation changing fixtures.
    ops(ctx.env, ["stop"])
    before = stored_files(data)
    included = Path.join(data, "modules/foundation/schema.yaml")
    File.write!(included, File.read!(included) <> "\n# earlier build's include\n")
    {out, 0} = ops(ctx.env, ["status"])
    assert out =~ "older than this build's"
    {out, status} = ops(ctx.env, ["restart"])
    assert status == 0, out
    assert out =~ "restarted it on this build's"
    for {file, contents} <- before, do: assert(File.read!(file) == contents)
    {out, 0} = ops(ctx.env, ["status"])
    assert out =~ "description: this build's"
  end

  defp stored_files(data) do
    for part <- ["entities", "relations"],
        file <- Path.wildcard(Path.join([data, part, "**", "*.md"])),
        into: %{},
        do: {file, File.read!(file)}
  end

  test "a description that would leave data without one is not started: it names it", ctx do
    start_older_rela(ctx)
    put(ctx.url, "e2e_gones", "G-1", "Data of a kind this build no longer has")

    {out, status} = ops(ctx.env, ["restart"])
    assert status == 1, out

    assert out =~
             "atlas-ops: rela test runs an older description, and this build's no longer describes data it holds:"

    assert out =~ "e2e_gone"
    assert out =~ "then: atlas-ops restart --env test"
    refute out =~ "core ready"

    # rela was left as it was, on its own description, with its data.
    assert "e2e_gone" in kinds(ctx.url)
  end

  defp free_ports(n) do
    sockets = for _ <- 1..n, do: elem(:gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}]), 1)
    ports = Enum.map(sockets, fn s -> elem(:inet.port(s), 1) end)
    Enum.each(sockets, &:gen_tcp.close/1)
    ports
  end
end
