#!/usr/bin/env python3
"""Update a local Console from the tested master tree, without interrupting it."""
import copy
import ctypes
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

REPO = "https://github.com/mimbre/atlas.git"
API = "https://api.github.com/repos/mimbre/atlas/actions/runs?branch=master&event=push&per_page=50"
APP = Path.home() / "Applications/Atlas Console.app"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def output(*args):
    return run(*args, stdout=subprocess.PIPE).stdout.strip()


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def tested_revision(revision):
    # deploy-prod is gated on the repository's tested-tree and all applicable CI jobs.
    def get(url):
        request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "atlas-console-local-update"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    runs = get(API)["workflow_runs"]
    for item in runs:
        if (item["head_sha"] != revision or item["name"] != "CI"
                or item["status"] != "completed" or item.get("conclusion") != "success"):
            continue
        jobs = get(item["jobs_url"] + "?per_page=100")["jobs"]
        if any(job["name"] == "Deploy prod on Fly, and a smoke check" and job["conclusion"] == "success" for job in jobs):
            return
    raise RuntimeError("no successful completed CI run with successful prod gate for master " + revision)


def metadata(app):
    if app.is_symlink() or not app.is_dir():
        raise RuntimeError("target must be an existing, non-symlink app")
    contents = app / "Contents"
    for path in (contents, contents / "MacOS", contents / "Resources",
                 contents / "Info.plist", contents / "MacOS/AtlasMac",
                 contents / "MacOS/AtlasLauncher", contents / "Resources/LocalPackaging.json",
                 contents / "Resources/SourceProvenance.txt"):
        if path.is_symlink():
            raise RuntimeError(f"refusing symlink in managed bundle path: {path}")
    with (contents / "Info.plist").open("rb") as f:
        info = plistlib.load(f)
    record = json.loads((contents / "Resources/LocalPackaging.json").read_text())
    argv = record.get("launcher_argv")
    if (not info.get("AtlasLocalDevelopment") or not info.get("CFBundleIdentifier")
            or info.get("CFBundleExecutable") != "AtlasLauncher"
            or not isinstance(info.get("AtlasGitCommit"), str)
            or not re.fullmatch(r"[0-9a-f]{40}", info["AtlasGitCommit"])
            or not isinstance(argv, list) or len(argv) != 6
            or argv[::2] != ["--env", "--host", "--port"]
            or not all(isinstance(x, str) and x for x in argv)
            or record.get("binary_sha256") != sha(contents / "MacOS/AtlasMac")):
        raise RuntimeError("installed bundle is not a recognized intact local Console")
    return info, record


def running(app):
    # pgrep matches the absolute executable path, not unrelated apps with the same name.
    path = str(app / "Contents/MacOS/AtlasMac")
    result = subprocess.run(["/usr/bin/pgrep", "-f", "^" + re.escape(path) + r"( |$)"], stdout=subprocess.DEVNULL)
    if result.returncode not in (0, 1):
        raise RuntimeError("could not determine whether Console is running")
    return result.returncode == 0


def swap(left, right):
    # Atomic exchange: neither bundle disappears, even if Finder launches concurrently.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameatx_np
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-2, os.fsencode(left), -2, os.fsencode(right), 0x00000002):  # AT_FDCWD, RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def update(app):
    app = app.absolute()
    info, record = metadata(app)
    original = copy.deepcopy((info, record))
    run("codesign", "--verify", "--strict", str(app))
    if running(app):
        print("Deferred: Console is running; quit it normally to allow an update.")
        return
    # No shared checkout is changed; preserve the existing updater's worktree and app.
    with tempfile.TemporaryDirectory(prefix="atlas-console-source-") as tmp:
        source = Path(tmp) / "source"
        run("git", "clone", "--quiet", "--no-checkout", "--single-branch", "--branch", "master", REPO, str(source))
        rev = output("git", "-C", str(source), "rev-parse", "refs/remotes/origin/master")
        installed = info["AtlasGitCommit"]
        run("git", "-C", str(source), "cat-file", "-e", installed + "^{commit}")
        run("git", "-C", str(source), "merge-base", "--is-ancestor", installed, rev)
        if rev == installed:
            print("Up to date: " + rev)
            return
        tested_revision(rev)
        run("git", "-C", str(source), "checkout", "--quiet", "--detach", rev)
        run(str(source / "bin/generate"), "model", cwd=source)
        package = source / "platform/clients/apple"
        run("swift", "test", "--package-path", str(package))
        run("swift", "build", "-c", "release", "--product", "AtlasMac", "--package-path", str(package))
        binary = Path(output("swift", "build", "-c", "release", "--show-bin-path", "--package-path", str(package))) / "AtlasMac"
        # A changed target, newer master, or running app prevents installing stale work.
        if metadata(app) != original:
            raise RuntimeError("installed bundle changed during build")
        latest = output("git", "ls-remote", REPO, "refs/heads/master").split()[0]
        if latest != rev:
            raise RuntimeError("master changed during build; retry")
        if running(app):
            print("Deferred: Console is running; quit it normally to allow an update.")
            return
        # Keep the old bundle in this unique directory after the atomic swap. It may
        # contain user-added files and can be restored manually; never delete it.
        stage = Path(tempfile.mkdtemp(prefix=".atlas-console-update-", dir=app.parent))
        candidate = stage / "Atlas Console.app"
        try:
            shutil.copytree(app, candidate, symlinks=True)
            contents = candidate / "Contents"
            shutil.copy2(binary, contents / "MacOS/AtlasMac")
            info["AtlasGitCommit"] = rev
            info["CFBundleGetInfoString"] = f"master {rev[:8]} local build; not a distribution release"
            with (contents / "Info.plist").open("wb") as f:
                plistlib.dump(info, f)
            provenance = (f"source: {REPO} master\ngit_commit: {rev}\n"
                          f"build: swift test; swift build -c release --product AtlasMac\n"
                          f"built: {datetime.datetime.now(datetime.timezone.utc).isoformat()}\n")
            provenance_bytes = provenance.encode()
            (contents / "Resources/SourceProvenance.txt").write_bytes(provenance_bytes)
            record["binary_sha256"] = sha(contents / "MacOS/AtlasMac")
            record["source_provenance_sha256"] = hashlib.sha256(provenance_bytes).hexdigest()
            (contents / "Resources/LocalPackaging.json").write_text(json.dumps(record, indent=2) + "\n")
            run("codesign", "--force", "--sign", "-", str(candidate))
            run("codesign", "--verify", "--strict", str(candidate))
            if running(app) or metadata(app) != original:
                raise RuntimeError("Console started or its bundle changed; retry")
            if output("git", "ls-remote", REPO, "refs/heads/master").split()[0] != rev:
                raise RuntimeError("master changed during staging; retry")
            if running(app):
                raise RuntimeError("Console started during staging; retry")
            swap(app, candidate)
        except BaseException:
            # The exchange may already have succeeded, even if interrupted; never
            # delete this directory because it could now contain the original app.
            previous = stage / "uninstalled-or-previous-bundle"
            try:
                if candidate.exists():
                    candidate.rename(previous)
            except OSError:
                previous = candidate
            print(f"Update interrupted or failed; retained staging at {previous}", file=sys.stderr)
            raise
        previous = stage / "previous-bundle"
        try:
            candidate.rename(previous)
        except OSError as error:
            print(f"Installed {rev}, but could not rename backup {candidate}: {error}", file=sys.stderr)
            return
        print(f"Installed {rev}; previous bundle retained at {previous}")


def main():
    os.environ["PATH"] = os.pathsep.join([
        str(Path.home() / ".asdf/shims"), "/opt/homebrew/bin",
        os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
    ])
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    # The lock is separate from the app, and never removes or modifies existing services.
    lock_dir = Path.home() / "Library/Caches"
    lock_dir.mkdir(parents=True, exist_ok=True)
    with (lock_dir / "atlas-console-update.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            update(APP)
        except Exception as error:
            print(f"Console update failed: {error}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
