#!/usr/bin/env python3
"""Private transfer rehearsal: real loopback Atlas/rela; local-only Fly transport.

No Fly CLI is invoked. Only the literal rehearsal-core/rehearsal-rela names are
accepted by the transport. All stores, process files and copied binaries live in a
new output directory. Runtime and external connectors are absent from all settings.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SELF = Path(__file__).resolve()


def run(args, env=None, check=True):
    result = subprocess.run([str(a) for a in args], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and result.returncode:
        raise RuntimeError(f"{args}: exit {result.returncode}\n{result.stdout}")
    return result


def environment(file):
    env = dict(os.environ, ATLAS_ENV_FILE=str(file), ATLAS_NO_UPDATE="1",
               ELIXIR_ERL_OPTIONS="+S 1:1", MIX_ENV="dev")
    # No model, cloud or keychain credentials are required.
    for key in ("GITHUB_TOKEN", "FLY_API_TOKEN", "ATLAS_BUS_LINK_TOKEN",
                "ATLAS_RUNTIME_FILE", "ATLAS_RUNTIME_HOME"):
        env.pop(key, None)
    return env


def atlas(file, *args, check=True):
    return run([ROOT / "bin/atlas", *args, "--env", "test"],
               environment(file), check=check)


def ops(file, *args, check=True):
    return run([ROOT / "bin/atlas-ops", *args, "--env", "test"],
               environment(file), check=check)


def rela_environment(file):
    config = json.loads(file.read_text())
    env = environment(file)
    env.update(ATLAS_TEST_ROOT=str(Path(config["rela"]["data"]).parent),
               ATLAS_RELA_DATA=config["rela"]["data"],
               ATLAS_RELA_BIN=config["rela"]["bin"],
               ATLAS_RELA_PORT=str(config["rela"]["port"]))
    return env


def ports():
    sockets = [socket.socket() for _ in range(2)]
    for sock in sockets:
        sock.bind(("127.0.0.1", 0))
    values = [sock.getsockname()[1] for sock in sockets]
    for sock in sockets:
        sock.close()
    return values


def settings(folder, binary):
    folder.mkdir(parents=True, exist_ok=True)
    rela_port, control_port = ports()
    file = folder / "test.json"
    file.write_text(json.dumps({
        "env": "test", "tui_user": "rehearsal",
        "control": {"host": "127.0.0.1", "port": control_port},
        "rela": {"url": f"http://127.0.0.1:{rela_port}/api/v1",
                 "port": rela_port, "data": str(folder / "rela"),
                 "bin": str(binary), "extra": "rela/atlas.json"},
        "state": {"data": str(folder / "beam")},
        "connectors": {}, "reconcile_seconds": 1,
        "flow": {"tick_seconds": 1}
    }, indent=2))
    return file


def manifest(folder):
    return run([ROOT / "fly/manifest.sh", folder]).stdout


def transport():
    # This executable replaces fly only inside the rehearsal subprocess environment.
    state = json.loads(Path(os.environ["ATLAS_REHEARSAL_STATE"]).read_text())
    args = sys.argv[1:]
    app = args[args.index("-a") + 1]
    if app not in ("rehearsal-core", "rehearsal-rela"):
        raise RuntimeError(f"refusing non-rehearsal app: {app}")
    folder = Path(state["destination"])
    role = "core" if app.endswith("-core") else "rela"
    volume = folder / role
    volume.mkdir(exist_ok=True)
    with Path(state["events"]).open("a") as log:
        log.write(json.dumps({"app": app, "args": args}) + "\n")

    def mapped(value):
        # Only the test copies' fixed absolute mount paths are remapped.
        return value.replace("/tmp/", str(volume / "tmp") + "/").replace(
            "/data", str(volume)).replace("/app", str(ROOT))

    if args[0] == "status":
        held = (volume / "hold").exists()
        print(json.dumps({"Machines": [{"id": app, "state": "started",
              "checks": [{"status": "critical" if held else "passing"}]}]}))
    elif args[:2] == ["ssh", "console"]:
        command = mapped(args[args.index("-C") + 1])
        result = run(["bash", "-c", command], check=False)
        sys.stdout.write(result.stdout)
        sys.exit(result.returncode)
    elif args[:2] == ["ssh", "sftp"]:
        action = args[2]
        first, second = args[-2:]
        if action == "put":
            shutil.copyfile(first, mapped(second))
        elif action == "get":
            shutil.copyfile(mapped(first), second)
        else:
            raise RuntimeError("unsupported sftp operation")
    elif args[:2] == ["machine", "restart"]:
        file = Path(state["destination_file"])
        if role == "core":
            ops(file, "stop")
        else:
            # Only rela's machine restarts: its scripts, as Fly runs them, not the core too.
            stopped = run([ROOT / "rela/scripts/stop.sh"], rela_environment(file), check=False)
            if stopped.returncode and "no pid file" not in stopped.stdout:
                raise RuntimeError(stopped.stdout)
        # Execute an isolated copy of the actual boot-time archive application.
        # Only mount paths change; the production script itself is not modified.
        script = mapped((ROOT / "fly/apply-move.sh").read_text())
        run(["bash", "-c", script, "apply-move", "beam" if role == "core" else "rela"])
        if not (volume / "hold").exists():
            if role == "core":
                ops(file, "restart")
            else:
                run([ROOT / "rela/scripts/start-bg.sh"], rela_environment(file))
    else:
        raise RuntimeError(f"unsupported transport call: {args}")


def rehearse(output, binary):
    output.mkdir(parents=True, exist_ok=False)
    # Copy executables only; never read or copy the user's test dataset.
    local_bin = output / "bin"
    local_bin.mkdir()
    for name in ("rela", "rela-server"):
        shutil.copy2(binary / name, local_bin / name)
    source_file = settings(output / "source", local_bin)
    destination = output / "destination"
    destination_file = settings(destination, local_bin)
    config = json.loads(destination_file.read_text())
    (destination / "core").mkdir()
    (destination / "rela").mkdir()
    config["rela"]["data"] = str(destination / "rela/rela")
    config["state"]["data"] = str(destination / "core/beam")
    destination_file.write_text(json.dumps(config, indent=2))
    for role in ("core", "rela"):
        (destination / role / "tmp").mkdir()

    fake_bin = output / "transport"
    fake_bin.mkdir()
    fake = fake_bin / "fly"
    fake.symlink_to(SELF)
    events = output / "transport.jsonl"
    state = output / "transport-state.json"
    state.write_text(json.dumps({"destination": str(destination),
                                "destination_file": str(destination_file),
                                "events": str(events)}))
    env = environment(destination_file)
    env.update(PATH=str(fake_bin) + os.pathsep + env["PATH"],
               ATLAS_REHEARSAL_STATE=str(state), ATLAS_ENV="test",
               ATLAS_FLY_APP="rehearsal-core", ATLAS_FLY_RELA_APP="rehearsal-rela",
               ATLAS_FLY_LOCAL=str(output / "transfer"),
               ATLAS_FLY_IN_USE="false")
    (output / "transfer/bin").mkdir(parents=True)
    for name in ("rela", "rela-server"):
        shutil.copy2(local_bin / name, output / "transfer/bin" / name)

    def transfer(script, *args, check=True):
        result = run([ROOT / "fly" / script, *args], env, check=False)
        with (output / "commands.log").open("a") as log:
            log.write(f"\n$ {script} {' '.join(map(str, args))}\n")
            log.write(result.stdout)
        if check and result.returncode:
            raise RuntimeError(result.stdout)
        return result

    def record(file, *args):
        result = atlas(file, *args, "--json")
        data = json.loads(result.stdout.splitlines()[-1])
        return data

    def key(item):
        return item.get("key") or item["id"]

    files = [source_file, destination_file]
    try:
        ops(source_file, "restart")
        record(source_file, "put", "agent", "--name", "Coordinator")
        scene = record(source_file, "put", "scene", "--title", "Synthetic source",
                       "--description", "Offline transfer baseline")
        scene_key = key(scene)
        uc = record(source_file, "put", "use_case", "--in", scene_key,
                    "--title", "Synthetic use case", "--description", "Transfer links")
        issue = record(source_file, "put", "issue", "--in", key(uc),
                       "--title", "Synthetic issue", "--description", "Preserve ownership")
        assignment_key = "AS-" + key(issue)
        baseline = {k: record(source_file, "get", k)
                    for k in (scene_key, key(uc), key(issue), assignment_key)}
        assert baseline[assignment_key]["origins"], "fixture needs State link provenance"
        ops(destination_file, "restart")
        record(destination_file, "put", "scene",
                          "--title", "Previous destination", "--description", "Keep me")
        ops(source_file, "stop", "--rela")
        backup = output / "source-backup"
        backup.mkdir()
        for name in ("rela", "beam"):
            shutil.copytree(source_file.parent / name, backup / name)
        before = {name: manifest(backup / name) for name in ("rela", "beam")}

        # The live-replacement guard must refuse before any transport call.
        env["ATLAS_FLY_IN_USE"] = "true"
        refused = transfer("move-to-fly.sh", "--from", backup, check=False)
        assert refused.returncode != 0 and "--replace-live" in refused.stdout
        assert not events.exists(), "refused replacement contacted destination"
        env["ATLAS_FLY_IN_USE"] = "false"
        transfer("fetch-from-fly.sh", "--to", output / "destination-before", "--hold")
        assert all((destination / role / "hold").exists() for role in ("core", "rela"))
        assert any((output / "destination-before/rela/entities/scenes").glob("*.md"))
        before_dry = events.read_text().splitlines()
        transfer("move-to-fly.sh", "--from", backup, "--dry-run")
        dry_calls = [json.loads(line)["args"] for line in events.read_text().splitlines()[len(before_dry):]]
        assert all(args[:2] == ["ssh", "console"] for args in dry_calls), dry_calls
        moved = transfer("move-to-fly.sh", "--from", backup)
        assert "every file of rela/ arrived as sent" in moved.stdout
        assert "every file of beam/ arrived as sent" in moved.stdout
        for name, role in (("rela", "rela"), ("beam", "core")):
            assert (destination / role / f"{name}.manifest").read_text() == before[name]
            assert manifest(backup / name) == before[name], "source backup mutated"

        # Compare user-visible fields and associations via Control, not the data API.
        for code, old in baseline.items():
            current = record(destination_file, "get", code)
            assert current == old, f"post-boot Control record differs: {code}"
        (output / "baseline-control.json").write_text(json.dumps(baseline, indent=2))

        # A later authoritative write must survive rollback; arrival proof stays fixed.
        latest = record(destination_file, "set", scene_key,
                        "description=Latest destination write, after arrival")
        assert latest != baseline[scene_key]
        assert (destination / "rela/rela.manifest").read_text() == before["rela"]
        transfer("fetch-from-fly.sh", "--to", output / "latest-backup", "--hold")
        assert manifest(output / "latest-backup/rela") != before["rela"]
        rollback_file = settings(output / "rollback", local_bin)
        files.append(rollback_file)
        for name in ("rela", "beam"):
            shutil.copytree(output / "latest-backup" / name, rollback_file.parent / name)
        ops(rollback_file, "restart")
        restored = record(rollback_file, "get", scene_key)
        assert restored == latest, "rollback lost latest authoritative write"
        (output / "latest-control.json").write_text(json.dumps(restored, indent=2))
        assert all((destination / role / "hold").exists() for role in ("core", "rela"))
        for name in ("rela", "beam"):
            assert manifest(backup / name) == before[name]

        # Protect against accidentally dropping a hold before destination rela replacement.
        calls = [json.loads(line) for line in events.read_text().splitlines()]
        restarts = [c["app"] for c in calls if c["args"][:2] == ["machine", "restart"]]
        assert restarts == ["rehearsal-core", "rehearsal-rela",
                            "rehearsal-rela", "rehearsal-core",
                            "rehearsal-core", "rehearsal-rela"], restarts
        print("PASS: live replacement refused without transport; dry run did not upload or restart")
        print("PASS: destination held core-first; transfer restarted rela-first")
        print("PASS: both arrival manifests match immutable source backup")
        print("PASS: four linked records, including Assignment provenance, match through post-boot Control")
        print("PASS: later write differs from arrival snapshot and survives latest-data rollback")
        print("PASS: old source unchanged; destination remains held; no Runtime or external connectors")
        for name, value in before.items():
            (output / f"source-{name}.manifest").write_text(value)
        print(f"Evidence: {output}")
    finally:
        for file in reversed(files):
            ops(file, "stop", "--rela", check=False)


if __name__ == "__main__":
    if Path(sys.argv[0]).name == "fly":
        transport()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--output", required=True, type=Path,
                            help="new directory for synthetic stores and evidence")
        parser.add_argument("--rela-bin", required=True, type=Path,
                            help="read-only source of pinned rela executables, not data")
        args = parser.parse_args()
        rehearse(args.output.resolve(), args.rela_bin.resolve())
