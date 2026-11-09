defmodule AtlasE2E.SmokeTest do
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas-smoke-#{System.unique_integer([:positive])}")
    for folder <- ["bin", "env", "rela"], do: File.mkdir_p!(Path.join(dir, folder))
    on_exit(fn -> File.rm_rf!(dir) end)
    File.cp_r!(Path.join(@root, "fly"), Path.join(dir, "fly"))

    File.write!(
      Path.join(dir, "env/test.json"),
      JSON.encode!(%{
        "fly" => %{"app" => "private-fixture"},
        "control" => %{"port" => 0}
      })
    )

    guidance =
      for {role, kind} <- [
            {"execution", "trace_log"},
            {"interaction", "note_log"},
            {"receipt", "proof_log"}
          ],
          into: %{},
          do: {role, %{"kind" => kind}}

    File.write!(Path.join(dir, "rela/atlas.json"), JSON.encode!(%{"guidance" => guidance}))

    executable(
      dir,
      "bin/fly",
      "#!/bin/sh\necho '{\"Machines\":[{\"image_ref\":{\"tag\":\"fixture\"}}]}'\n"
    )

    executable(dir, "bin/atlas", """
    #!/usr/bin/env python3
    import json, os, sys
    args = sys.argv[1:]
    with open(os.environ['SMOKE_CALLS'], 'a') as f: f.write(json.dumps(args) + '\\n')
    if args[0] == 'help': print(os.environ.get('SMOKE_HELP', json.dumps([{'kind': k} for k in json.loads(os.environ['SMOKE_KINDS'])])))
    elif args[0] == 'list':
        if args[1] in json.loads(os.environ['SMOKE_SCOPED']):
            if 'SMOKE_REPLY' in os.environ: print(os.environ['SMOKE_REPLY'])
            else: print(json.dumps({'error': os.environ.get('SMOKE_ERROR_TEXT', 'requires an exact identity'), 'code': os.environ.get('SMOKE_ERROR_CODE', 'exact_identity_required')}))
            sys.exit(int(os.environ.get('SMOKE_EXIT', '2')))
        elif os.environ.get('SMOKE_LIST_ERROR'):
            print(json.dumps({'error': os.environ['SMOKE_LIST_ERROR']}))
        else: print('[{}, {}]')
    else: raise SystemExit('unexpected command (no writes allowed): ' + repr(args))
    """)

    # Smoke operates nothing: any atlas-ops call is noted, and fails the test below.
    executable(dir, "bin/atlas-ops", """
    #!/usr/bin/env python3
    import json, os, sys
    with open(os.environ['SMOKE_CALLS'], 'a') as f: f.write(json.dumps(['atlas-ops'] + sys.argv[1:]) + '\\n')
    """)

    %{dir: dir}
  end

  defp executable(dir, name, text) do
    file = Path.join(dir, name)
    File.write!(file, text)
    File.chmod!(file, 0o755)
  end

  defp smoke(dir, extra \\ []) do
    env =
      Map.new([
        {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
        {"SMOKE_CALLS", Path.join(dir, "calls.jsonl")},
        {"SMOKE_KINDS", JSON.encode!(["box", "trace_log", "note_log", "proof_log"])},
        {"SMOKE_SCOPED", JSON.encode!(["trace_log", "note_log", "proof_log"])}
      ])
      |> then(&(Enum.into(extra, &1) |> Map.to_list()))

    System.cmd("bash", [Path.join(dir, "fly/smoke.sh"), "test", "fixture"],
      env: env,
      stderr_to_stdout: true
    )
  end

  test "ordinary lists and all renamed role guards are positively checked", %{dir: dir} do
    {out, status} = smoke(dir)
    assert status == 0, out
    assert out =~ "smoke: box: 2"

    for kind <- ["trace_log", "note_log", "proof_log"] do
      assert out =~ "#{kind}: scoped-read guard verified"
      assert File.read!(Path.join(dir, "calls.jsonl")) =~ ~s(["list", "#{kind}")
    end

    refute File.read!(Path.join(dir, "calls.jsonl")) =~ "atlas-ops"
  end

  test "ordinary-only compositions retain ordinary smoke", %{dir: dir} do
    File.write!(Path.join(dir, "rela/atlas.json"), "{}")
    {out, status} = smoke(dir, [{"SMOKE_KINDS", ~s(["box"])}, {"SMOKE_SCOPED", "[]"}])
    assert status == 0, out
    assert out =~ "smoke: box: 2"
  end

  test "new ordinary kinds are listed alongside restricted roles", %{dir: dir} do
    {out, status} =
      smoke(dir, [{"SMOKE_KINDS", ~s(["box","trace_log","note_log","proof_log","new_kind"])}])

    assert status == 0, out
    assert out =~ "smoke: new_kind: 2"
    assert File.read!(Path.join(dir, "calls.jsonl")) =~ ~s(["list", "new_kind")
  end

  test "duplicate role kinds are not treated as a valid guard declaration", %{dir: dir} do
    File.write!(
      Path.join(dir, "rela/atlas.json"),
      ~s({"guidance":{"execution":{"kind":"box"},"receipt":{"kind":"box"}}})
    )

    {out, status} = smoke(dir)
    assert status != 0
    assert out =~ "duplicate roles"
  end

  test "ordinary failure keeps the kind and cause rather than a jq error", %{dir: dir} do
    {out, status} = smoke(dir, [{"SMOKE_LIST_ERROR", "backend unavailable"}])
    assert status != 0
    assert out =~ "box"
    assert out =~ "backend unavailable"
    refute out =~ "jq: error"
  end

  for {name, extra} <- [
        {"timeout", [{"SMOKE_ERROR_CODE", "timeout"}, {"SMOKE_ERROR_TEXT", "timed out"}]},
        {"unavailable",
         [{"SMOKE_ERROR_CODE", "store_error"}, {"SMOKE_ERROR_TEXT", "backend unavailable"}]},
        {"unknown failure", [{"SMOKE_ERROR_CODE", "unknown_kind"}]},
        {"text that imitates a typed guard",
         [{"SMOKE_REPLY", ~s({"error":":exact_identity_required"})}]},
        {"malformed JSON", [{"SMOKE_REPLY", "not-json"}]},
        {"unexpected list success", [{"SMOKE_REPLY", "[]"}, {"SMOKE_EXIT", "0"}]},
        {"error object with success exit", [{"SMOKE_EXIT", "0"}]},
        {"transport failure with guard code", [{"SMOKE_EXIT", "73"}]}
      ] do
    test "restricted role rejects #{name}", %{dir: dir} do
      {out, status} = smoke(dir, unquote(extra))
      assert status != 0
      assert out =~ "trace_log"
      refute out =~ "scoped-read guard verified"
      refute out =~ "jq: error"
    end
  end

  test "a declared role missing from Control is a packaging mismatch", %{dir: dir} do
    {out, status} = smoke(dir, [{"SMOKE_KINDS", ~s(["box"])}])
    assert status != 0
    assert out =~ "not advertised"
  end

  test "unknown guidance roles fail rather than becoming exclusions", %{dir: dir} do
    File.write!(Path.join(dir, "rela/atlas.json"), ~s({"guidance":{"unknown":{"kind":"box"}}}))
    {out, status} = smoke(dir)
    assert status != 0
    assert out =~ "guidance"
  end

  test "malformed help output fails clearly before listing", %{dir: dir} do
    {out, status} = smoke(dir, [{"SMOKE_HELP", ~s({"error":"description unavailable"})}])
    assert status != 0
    assert out =~ "description unavailable"
    refute File.read!(Path.join(dir, "calls.jsonl")) =~ ~s(["list")
    refute out =~ "jq: error"
  end
end
