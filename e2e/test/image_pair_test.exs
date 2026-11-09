defmodule AtlasE2E.ImagePairTest do
  use ExUnit.Case, async: false
  @root Path.expand("../..", __DIR__)
  @old_rela "registry.fly.io/fixture-rela@sha256:#{String.duplicate("a", 64)}"
  @old_core "registry.fly.io/fixture-core@sha256:#{String.duplicate("b", 64)}"

  defp executable(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/bash\n" <> body)
    File.chmod!(path, 0o700)
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas-pair-#{System.unique_integer([:positive])}")

    for sub <- ["fly", "env", "rela/scripts", "model/contract", "bin", "remote"] do
      File.mkdir_p!(Path.join(dir, sub))
    end

    on_exit(fn -> File.rm_rf!(dir) end)

    for name <- ["deploy.sh", "image-pair.sh"],
        do: File.cp!(Path.join(@root, "fly/#{name}"), Path.join(dir, "fly/#{name}"))

    File.chmod!(Path.join(dir, "fly/image-pair.sh"), 0o700)

    File.write!(
      Path.join(dir, "env/test.json"),
      JSON.encode!(%{
        "fly" => %{"app" => "fixture-core", "rela_app" => "fixture-rela"},
        "control" => %{"host_env" => "ATLAS_CONTROL_TEST_HOST"}
      })
    )

    File.write!(Path.join(dir, "rela/atlas.manifest.json"), "{}")
    File.write!(Path.join(dir, "rela/data-entry.yaml"), "fixture")
    File.write!(Path.join(dir, "rela/scripts/config.py"), "print('fixture')\n")
    File.write!(Path.join(dir, "fly/check-fits.sh"), "fixture")
    File.write!(Path.join(dir, "remote/fixture-rela"), @old_rela)
    File.write!(Path.join(dir, "remote/fixture-core"), @old_core)
    File.write!(Path.join(dir, "authority"), "latest authoritative data")

    File.write!(
      Path.join(dir, "held-clients-and-proxy"),
      "previous compatible checkout and proxy configuration"
    )

    executable(Path.join(dir, "bin/mix"), "exit 0\n")
    executable(Path.join(dir, "fly/smoke.sh"), "[ \"$PROOF_FAIL\" != smoke ] || exit 23\n")

    executable(Path.join(dir, "held-smoke"), """
    [ "$(cat "$PROOF_PAIR/remote/fixture-rela")" = '#{@old_rela}' ] || exit 81
    [ "$(cat "$PROOF_PAIR/remote/fixture-core")" = '#{@old_core}' ] || exit 82
    [ -s "$PROOF_PAIR/held-clients-and-proxy" ] || exit 83
    echo held-client-and-proxy-reachable >> "$PROOF_PAIR/calls"
    """)

    executable(Path.join(dir, "bin/flyctl"), """
    echo "$*" >> "$PROOF_PAIR/calls"
    args=("$@"); app=""; side=""; image=""; cfg=""
    for ((i=0; i<${#args[@]}; i++)); do
      case "${args[$i]}" in
        -a) app="${args[$((i+1))]}" ;;
        --image) image="${args[$((i+1))]}" ;;
        --machine-config) cfg="${args[$((i+1))]}" ;;
        --config) case "${args[$((i+1))]}" in *rela.toml) app=fixture-rela ;; *) app=fixture-core ;; esac ;;
      esac
    done
    case "$1 $2" in
      'secrets list') echo '[{"Name":"TS_AUTHKEY"}]' ;;
      'machine list')
        saved=$(cat "$PROOF_PAIR/remote/$app")
        digest="${saved##*@}"
        state=started
        volume="${PROOF_VOLUME:-current-data}"
        [ ! -e "$PROOF_PAIR/stopped-$app" ] || state=stopped
        jq -n --arg app "$app" --arg digest "$digest" --arg state "$state" --arg volume "$volume" \
          '[{id:$app,state:$state,image_ref:{registry:"registry.fly.io",repository:$app,digest:$digest},config:{image:("registry.fly.io/"+$app+"@"+$digest),env:{PAIR_CONFIG:"previous"},services:[],mounts:[{volume:$volume,path:"/data"}]}}]' ;;
      'machine stop') touch "$PROOF_PAIR/stopped-$app" ;;
      'machine update')
        [ "${PROOF_RECOVERY_FAIL:-}" != "$app" ] || exit 31
        cp "$cfg" "$PROOF_PAIR/restored-$app.config.json"
        printf '%s' "$image" > "$PROOF_PAIR/remote/$app"
        rm -f "$PROOF_PAIR/stopped-$app" ;;
      'deploy '*)
        printf 'registry.fly.io/%s@sha256:%s' "$app" '#{String.duplicate("c", 64)}' > "$PROOF_PAIR/remote/$app"
        [ "$PROOF_FAIL" != "${app#fixture-}" ] || exit 24 ;;
      'status '*)
        if [ "$PROOF_FAIL" = validation ]; then tag=wrong; else tag=candidate; fi
        jq -n --arg tag "$tag" '{Machines:[{image_ref:{tag:$tag}}]}' ;;
      'ssh '*)
        case "$*" in
          *'test -e /data/hold'*) exit 1 ;;
          *'description.sh fits'*) [ "$PROOF_FAIL" != preflight ] || exit 25 ;;
          *sha256sum*) shasum -a 256 "$PROOF_PAIR/rela/atlas.manifest.json" ;;
        esac ;;
      *) exit 99 ;;
    esac
    """)

    %{dir: dir}
  end

  defp run(dir, script, args, extra \\ []) do
    System.cmd("bash", [Path.join(dir, "fly/#{script}") | args],
      env:
        [
          {"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")},
          {"PROOF_PAIR", dir},
          {"ATLAS_CONTROL_TEST_HOST", "core.security-fixture.ts.net"},
          {"ATLAS_DEPLOY_RECOVERY", Path.join(dir, "record")},
          {"PROOF_FAIL", "none"},
          {"ATLAS_FLY_TOKEN_CORE", nil},
          {"ATLAS_FLY_TOKEN_RELA", nil},
          {"FLY_API_TOKEN", nil}
        ] ++ extra,
      stderr_to_stdout: true
    )
  end

  for boundary <- ["preflight", "rela", "core", "validation", "smoke"] do
    test "#{boundary} failure retains the captured immutable pair and supports explicit compatible recovery",
         %{dir: dir} do
      boundary = unquote(boundary)

      assert {output, status} =
               run(dir, "deploy.sh", ["test", "candidate"], [{"PROOF_FAIL", boundary}])

      assert status != 0, output
      assert File.read!(Path.join(dir, "record/rela.image")) == @old_rela <> "\n"
      assert File.read!(Path.join(dir, "record/core.image")) == @old_core <> "\n"
      calls = File.read!(Path.join(dir, "calls"))

      assert length(Regex.scan(~r/^deploy /m, calls)) ==
               (case boundary do
                  "preflight" -> 0
                  "rela" -> 1
                  _ -> 2
                end)

      assert {_, denied} = run(dir, "image-pair.sh", ["recover", Path.join(dir, "record")])
      assert denied != 0

      assert {out, 0} =
               run(dir, "image-pair.sh", ["recover", Path.join(dir, "record")], [
                 {"ATLAS_RECOVERY_COMPATIBLE", "1"},
                 {"ATLAS_RECOVERY_SMOKE", Path.join(dir, "held-smoke")}
               ])

      assert out =~ "client holds remain"

      for side <- ["rela", "core"] do
        assert File.read!(Path.join(dir, "restored-fixture-#{side}.config.json")) ==
                 File.read!(Path.join(dir, "record/#{side}.config.json"))
      end

      assert File.read!(Path.join(dir, "authority")) == "latest authoritative data"

      assert File.read!(Path.join(dir, "held-clients-and-proxy")) ==
               "previous compatible checkout and proxy configuration"
    end
  end

  test "failed recovery retains holds and can be rerun with the same saved pair", %{dir: dir} do
    assert {_, 23} = run(dir, "deploy.sh", ["test", "candidate"], [{"PROOF_FAIL", "smoke"}])

    options = [
      {"ATLAS_RECOVERY_COMPATIBLE", "1"},
      {"ATLAS_RECOVERY_SMOKE", Path.join(dir, "held-smoke")}
    ]

    assert {_, 31} =
             run(
               dir,
               "image-pair.sh",
               ["recover", Path.join(dir, "record")],
               options ++ [{"PROOF_RECOVERY_FAIL", "fixture-core"}]
             )

    refute File.read!(Path.join(dir, "calls")) =~ "held-client-and-proxy-reachable"
    assert {_, 0} = run(dir, "image-pair.sh", ["recover", Path.join(dir, "record")], options)
  end

  test "changed data mounts refuse recovery before any machine stop or update", %{dir: dir} do
    assert {_, 23} = run(dir, "deploy.sh", ["test", "candidate"], [{"PROOF_FAIL", "smoke"}])

    assert {out, status} =
             run(dir, "image-pair.sh", ["recover", Path.join(dir, "record")], [
               {"ATLAS_RECOVERY_COMPATIBLE", "1"},
               {"ATLAS_RECOVERY_SMOKE", Path.join(dir, "held-smoke")},
               {"PROOF_VOLUME", "another-authoritative-volume"}
             ])

    assert status != 0
    assert out =~ "refusing to reattach a previous volume"
    calls = File.read!(Path.join(dir, "calls"))
    refute calls =~ "machine stop"
    refute calls =~ "machine update"
    assert File.read!(Path.join(dir, "authority")) == "latest authoritative data"
  end
end
