"""The Swift package of Control's contract, AtlasControlKit, as published in
github.com/mimbre/atlas-swift: one tag per contract version (the `version` of
platform/atlas_control/backend/contract/lib/contract.ex). `bin/generate atlas` writes the
package into platform/atlas_control/backend/targets/swift; the app depends on its tag.

  version                      print the contract version
  publish <package> <remote>   when the remote has no tag of the version: push <package>
                               to its main branch and tag it with the version; when it
                               has one, do nothing

Paths starting with a dot (.build, .swiftpm, .git) are not part of the package.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile

CONTRACT = Path(__file__).resolve().parents[4] / "platform/atlas_control/backend/contract/lib/contract.ex"
AUTHOR = ["-c", "user.name=github-actions[bot]",
          "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com"]


def version(contract=CONTRACT):
    found = re.search(r'^\s*version "(\d+\.\d+\.\d+)"', contract.read_text(), re.MULTILINE)
    if not found:
        sys.exit(f"{contract} declares no contract version")
    return found.group(1)


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


def files(root):
    """The package's files, relative path to bytes."""
    return {p.relative_to(root).as_posix(): p.read_bytes()
            for p in sorted(root.rglob("*"))
            if p.is_file() and not any(part.startswith(".") for part in p.relative_to(root).parts)}


def publish(args):
    package = args.package.resolve()
    tag = version(args.contract)
    if not (package / "Package.swift").is_file():
        sys.exit(f"{package} holds no Package.swift: run bin/generate atlas")
    if git("ls-remote", "--tags", args.remote, f"refs/tags/{tag}").strip():
        print(f"{tag} is published already; nothing to publish")
        return
    with tempfile.TemporaryDirectory() as tmp:
        clone = Path(tmp) / "atlas-swift"
        git("clone", "--quiet", args.remote, str(clone))
        git("checkout", "--quiet", "-B", "main", cwd=clone)
        for path in files(clone):
            (clone / path).unlink()
        for path, content in files(package).items():
            (clone / path).parent.mkdir(parents=True, exist_ok=True)
            (clone / path).write_bytes(content)
        git("add", "--all", cwd=clone)
        message = f"AtlasControlKit {tag}" + (f"\n\nGenerated from mimbre/atlas@{args.source}." if args.source else "")
        git(*AUTHOR, "commit", "--quiet", "--allow-empty", "-m", message, cwd=clone)
        git(*AUTHOR, "tag", "-a", tag, "-m", f"AtlasControlKit {tag}", cwd=clone)
        git("push", "--quiet", "origin", "main", f"refs/tags/{tag}", cwd=clone)
    print(f"published {tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--contract", type=Path, default=CONTRACT, help=argparse.SUPPRESS)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("version").set_defaults(run=lambda args: print(version(args.contract)))
    p = commands.add_parser("publish")
    p.add_argument("package", type=Path)
    p.add_argument("remote")
    p.add_argument("--source", help="the mimbre/atlas revision the package was generated at")
    p.set_defaults(run=publish)
    args = parser.parse_args()
    try:
        args.run(args)
    except subprocess.CalledProcessError as error:
        sys.exit(f"git {' '.join(error.cmd[1:])} failed: {error.stderr.strip()}")


if __name__ == "__main__":
    main()
