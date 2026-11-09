"""Bundle an already-built AtlasMac for explicitly configured local development use."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="new .app path; never overwritten")
    parser.add_argument("--env", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--provenance", type=Path, required=True, help="existing source/build provenance")
    parser.add_argument("--info-plist", type=Path, help="existing public metadata to preserve")
    args = parser.parse_args()
    if not args.env or not args.host or not 1 <= args.port <= 65535:
        parser.error("nonempty env/host and port in 1...65535 are required")
    if not args.binary.is_file() or not os.access(args.binary, os.X_OK):
        parser.error("binary must be an already-built executable file")
    if not args.provenance.is_file():
        parser.error("source/build provenance file is required")
    if args.output.suffix != ".app" or args.output.exists():
        parser.error("output must be a new .app path")

    info = {}
    if args.info_plist:
        with args.info_plist.open("rb") as source:
            info = plistlib.load(source)
    info.setdefault("CFBundleIdentifier", "local.atlas.console")
    info.setdefault("CFBundleName", "Atlas Console")
    info.setdefault("CFBundleDisplayName", "Atlas Console")
    info.update(CFBundleExecutable="AtlasLauncher", CFBundlePackageType="APPL",
                AtlasLocalDevelopment=True)
    argv = ["--env", args.env, "--host", args.host, "--port", str(args.port)]
    launcher = (
        '#!/bin/sh\nset -eu\n'
        'macos=$(CDPATH= cd -P "$(/usr/bin/dirname "$0")" && pwd)\n'
        'exec "$macos/AtlasMac" ' + shlex.join(argv) + '\n'
    )
    # Read inputs before creating output, and refuse to replace any existing bundle.
    provenance = args.provenance.read_bytes()
    record = {"local_development": True, "binary_sha256": digest(args.binary),
              "source_provenance_sha256": hashlib.sha256(provenance).hexdigest(),
              "launcher_argv": argv}
    args.output.mkdir(parents=True)
    try:
        contents = args.output / "Contents"
        macos = contents / "MacOS"
        resources = contents / "Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        shutil.copy2(args.binary, macos / "AtlasMac")
        (macos / "AtlasLauncher").write_text(launcher)
        (macos / "AtlasLauncher").chmod(0o755)
        with (contents / "Info.plist").open("wb") as output:
            plistlib.dump(info, output)
        (resources / "SourceProvenance.txt").write_bytes(provenance)
        (resources / "LocalPackaging.json").write_text(json.dumps(record, indent=2) + "\n")
    except BaseException:
        shutil.rmtree(args.output)
        raise
    print(args.output)


if __name__ == "__main__":
    main()
