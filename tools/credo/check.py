#!/usr/bin/env python3
"""Run Credo on tracked Elixir snapshots, or compare the index with HEAD."""
import collections
import difflib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

TOOL_DIR = Path(__file__).resolve().parent
EXCLUDED = {"tmp", "deps", "_build", "generated"}
NO_BASELINE = object()


def git(*args, input=None):
    return subprocess.run(["git", *args], input=input, stdout=subprocess.PIPE, check=True).stdout


def included(path):
    parts = path.split(b"/")
    return (parts[0] in (b"platform", b"products") and
            not EXCLUDED.intersection(os.fsdecode(p) for p in parts[1:-1]) and
            not any(p.startswith(b".") for p in parts[1:-1]) and
            path.endswith((b".ex", b".exs")))

def entries(index):
    data = git("ls-files", "--stage", "-z", "--", "platform", "products") if index else git(
        "ls-tree", "-r", "-z", "HEAD", "--", "platform", "products")
    result = {}
    for entry in data.split(b"\0"):
        if not entry:
            continue
        meta, path = entry.split(b"\t", 1)
        if not included(path):
            continue
        fields = meta.split()
        mode, oid = fields[0], fields[1 if index else 2]
        if mode not in (b"100644", b"100755") or (index and fields[2] != b"0"):
            raise ValueError(f"unsupported or unmerged Elixir source: {os.fsdecode(path)}")
        result[path] = oid
    return result


def materialize(files, directory):
    if not files:
        return
    process = subprocess.Popen(["git", "cat-file", "--batch"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE)
    # Communicate avoids deadlock when snapshots exceed the pipe buffer.
    output, _ = process.communicate(b"".join(oid + b"\n" for oid in files.values()))
    if process.returncode:
        raise ValueError("git cat-file failed")
    offset = 0
    for path, oid in files.items():
        end = output.index(b"\n", offset)
        header = output[offset:end].split()
        if len(header) != 3 or header[0] != oid or header[1] != b"blob":
            raise ValueError(f"could not read blob for {os.fsdecode(path)}")
        size = int(header[2])
        offset = end + 1
        content = output[offset:offset + size]
        if len(content) != size or output[offset + size:offset + size + 1] != b"\n":
            raise ValueError("incomplete git cat-file output")
        offset += size + 1
        target = directory / os.fsdecode(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)


def analyze(files, directory):
    if not files:
        return []
    materialize(files, directory)
    command = ["mix", "credo", "suggest", "--working-dir", str(directory),
               "--format", "json", "--all", "--strict", "--crash-on-error",
               "**/*.{ex,exs}", "**/.*.{ex,exs}"]
    env = dict(os.environ, MAX_FILES=str(len(files) + 1))
    result = subprocess.run(command, cwd=TOOL_DIR, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    # Credo encodes finding categories as status bits; a valid JSON result is needed even then.
    try:
        payload = json.loads(result.stdout)
        issues = payload["issues"]
        if not isinstance(issues, list) or result.returncode < 0 or result.returncode & ~31:
            raise ValueError("invalid Credo result")
        if result.stderr:
            raise ValueError(result.stderr.decode(errors="replace"))
    except (ValueError, KeyError, TypeError) as error:
        raise ValueError(f"Credo failed ({result.returncode}): {error}\n"
                         f"{result.stdout.decode(errors='replace')}\n"
                         f"{result.stderr.decode(errors='replace')}") from error
    for issue in issues:
        path = Path(issue["filename"])
        if path.is_absolute():
            issue["filename"] = str(path.relative_to(directory))
    return issues


def key(issue):
    return json.dumps(issue, sort_keys=True, ensure_ascii=True)


def baseline_line(issue, previous, current, root, mappings):
    path = os.fsencode(issue["filename"])
    if path not in previous or path not in current:
        return NO_BASELINE
    line = issue["line_no"]
    if previous[path] == current[path]:
        return line
    if not isinstance(line, int) or line < 1:
        return NO_BASELINE
    if path not in mappings:
        old_lines = (root / "head" / os.fsdecode(path)).read_bytes().splitlines(keepends=True)
        new_lines = (root / "index" / os.fsdecode(path)).read_bytes().splitlines(keepends=True)
        # shortcut: repeated identical lines can map ambiguously; use syntax-aware matching if needed.
        blocks = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False).get_matching_blocks()
        mappings[path] = {
            new_start + offset + 1: old_start + offset + 1
            for old_start, new_start, length in blocks
            for offset in range(length)
        }
    return mappings[path].get(line, NO_BASELINE)


def main():
    if sys.argv[1:] not in (["all"], ["staged"]):
        raise ValueError("usage: python3 tools/credo/check.py {all|staged}")
    os.chdir(os.fsdecode(git("rev-parse", "--show-toplevel").strip()))
    current = entries(True)
    if not current:
        raise ValueError("no tracked product Elixir files in the index")
    previous = entries(False) if sys.argv[1] == "staged" else None
    if previous == current:
        print("Credo: no staged product Elixir changes")
        return 0
    with tempfile.TemporaryDirectory(prefix="atlas-credo-") as temp:
        root = Path(temp)
        new = analyze(current, root / "index")
        if previous is not None:
            old = collections.Counter(key(issue) for issue in analyze(previous, root / "head"))
            mappings = {}
            introduced = []
            for issue in new:
                old_line = baseline_line(issue, previous, current, root, mappings)
                fingerprint = key({**issue, "line_no": old_line}) if old_line is not NO_BASELINE else None
                if fingerprint is not None and old[fingerprint]:
                    old[fingerprint] -= 1
                else:
                    introduced.append(issue)
            new = introduced
    for issue in new:
        print(f"{issue['filename']}:{issue['line_no']}:{issue['column']}: "
              f"{issue['check']}: {issue['message']}")
    print(f"Credo: {len(current)} tracked index files, {len(new)} "
          f"{'introduced ' if previous is not None else ''}findings")
    return int(bool(new))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Credo gate error: {error}", file=sys.stderr)
        sys.exit(2)
