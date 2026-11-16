#!/usr/bin/env python3
"""Read-only deployment probes through the ordinary Control/CLI path.

The packaged description (whose manifest deploy.sh checks on both machines) maps
guidance roles to kinds. These kinds must return their typed unscoped-read guard;
all other advertised kinds must return an ordinary list. This does not prove
positive scoped reads of stored guidance; private Facts fixtures cover those.
"""
import json
import os
import subprocess
import sys
from pathlib import Path


class SmokeFailure(Exception):
    pass


def detail(value):
    if isinstance(value, dict):
        text = str(value.get("error") or value.get("refused") or "unexpected object")
        return f"{value['code']}: {text}" if value.get("code") else text
    return "unexpected " + type(value).__name__


def command(atlas, environment, *args):
    try:
        result = subprocess.run(
            [atlas, *args, "--json", "--env", environment],
            capture_output=True, text=True, timeout=60,
            env={**os.environ, "ATLAS_NO_UPDATE": "1"},
        )
    except subprocess.TimeoutExpired as error:
        raise SmokeFailure(f"{' '.join(args)}: CLI timed out") from error
    except OSError as error:
        raise SmokeFailure(f"{' '.join(args)}: cannot run CLI: {error}") from error
    try:
        answer = json.loads(result.stdout)
    except (ValueError, TypeError) as error:
        raise SmokeFailure(
            f"{' '.join(args)}: malformed JSON (CLI exit {result.returncode}); "
            + result.stderr.strip()
        ) from error
    return result.returncode, answer, result.stderr.strip()


def run(atlas, description_file, environment, app):
    try:
        description = json.loads(Path(description_file).read_text())
        guidance = description.get("guidance", {})
    except (OSError, ValueError, AttributeError) as error:
        raise SmokeFailure(f"cannot read packaged description: {error}") from error
    if not isinstance(guidance, dict):
        raise SmokeFailure("packaged guidance declarations must be an object")

    restricted = set()
    for role, spec in guidance.items():
        if role not in ("execution", "interaction", "receipt"):
            raise SmokeFailure(f"unsupported guidance role {role}")
        if not isinstance(spec, dict) or not isinstance(spec.get("kind"), str) or not spec["kind"]:
            raise SmokeFailure(f"guidance role {role} has no kind")
        if spec["kind"] in restricted:
            raise SmokeFailure(f"guidance kind {spec['kind']} has duplicate roles")
        restricted.add(spec["kind"])

    status, answer, stderr = command(atlas, environment, "help")
    if status != 0 or not isinstance(answer, list) or not answer:
        raise SmokeFailure(f"Control on {app} answered no valid kinds: {detail(answer)}; {stderr}")
    if any(not isinstance(row, dict) or not isinstance(row.get("kind"), str) or not row["kind"] for row in answer):
        raise SmokeFailure("Control advertised malformed kinds")
    kinds = [row["kind"] for row in answer]
    if len(kinds) != len(set(kinds)):
        raise SmokeFailure("Control advertised duplicate kinds")
    missing = restricted - set(kinds)
    if missing:
        raise SmokeFailure("packaged guidance kinds not advertised by Control: " + ", ".join(sorted(missing)))
    print(f"smoke: Control on {app} answers over the private network; kinds: {' '.join(kinds)}", flush=True)

    for kind in kinds:
        status, answer, stderr = command(atlas, environment, "list", kind)
        if kind in restricted:
            if not (status == 2 and isinstance(answer, dict)
                    and set(answer) == {"error", "code"}
                    and answer["code"] == "exact_identity_required"
                    and isinstance(answer["error"], str) and answer["error"]):
                raise SmokeFailure(f"{kind}: expected typed scoped-read guard, got CLI exit {status}: {detail(answer)}; {stderr}")
            print(f"smoke: {kind}: scoped-read guard verified (exact_identity_required; records not enumerated)", flush=True)
        else:
            if status != 0 or not isinstance(answer, list):
                raise SmokeFailure(f"listing {kind} failed (CLI exit {status}): {detail(answer)}; {stderr}")
            print(f"smoke: {kind}: {len(answer)}", flush=True)
    print(f"smoke: {environment} on Fly answers", flush=True)


if __name__ == "__main__":
    try:
        run(*sys.argv[1:])
    except SmokeFailure as failure:
        print(f"smoke: {failure}", file=sys.stderr)
        sys.exit(1)
