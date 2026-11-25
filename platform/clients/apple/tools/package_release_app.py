"""The Mac app's release (IS-Atlas-66), for the release job of .github/workflows/ci.yml.

  contract <Contract.swift>   print the contract version the app speaks (Contract.version)
  bundle ...                  make `Atlas Console.app` of an already-built AtlasMac, with
                              its release in Info.plist (revision, build, contract, feed)
  feed ...                    write the feed naming a release, unless the current feed
                              already names a later one (exit 3)

It builds, signs and publishes nothing itself: the job runs swift build, codesign and gh.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import sys

IDENTIFIER = "co.eyra.atlas.console"
NAME = "Atlas Console"
NOT_NEWER = 3


def contract(args):
    found = re.search(r'static let version = "(\d+\.\d+\.\d+)"', args.file.read_text())
    if not found:
        sys.exit(f"{args.file} names no contract version")
    print(found.group(1))


def info(args):
    """The bundle's Info.plist: what the app is, where it connects and its release."""
    return {
        "CFBundleIdentifier": IDENTIFIER,
        "CFBundleName": NAME,
        "CFBundleDisplayName": NAME,
        "CFBundleExecutable": "AtlasMac",
        "CFBundlePackageType": "APPL",
        "CFBundleInfoDictionaryVersion": "6.0",
        # The version names the revision, as prod's image label does (master-<commit>).
        "CFBundleShortVersionString": f"master-{args.revision[:12]}",
        "CFBundleVersion": str(args.build),
        "LSMinimumSystemVersion": "14.0",
        "LSApplicationCategoryType": "public.app-category.developer-tools",
        "NSHighResolutionCapable": True,
        "AtlasRevision": args.revision,
        "AtlasContract": args.contract,
        "AtlasUpdateFeed": args.feed_url,
        "AtlasControl": {"env": args.env, "host": args.host, "port": args.port},
    }


def bundle(args):
    if not re.fullmatch(r"[0-9a-f]{40}", args.revision):
        sys.exit("--revision must be a full commit hash")
    if args.build < 1 or not re.fullmatch(r"\d+\.\d+\.\d+", args.contract):
        sys.exit("--build must be positive and --contract x.y.z")
    if not args.feed_url.startswith("https://"):
        sys.exit("--feed-url must be https")
    if not 1 <= args.port <= 65535 or not args.env or not args.host:
        sys.exit("nonempty --env/--host and --port in 1...65535 are required")
    if not args.binary.is_file():
        sys.exit(f"{args.binary} is no built AtlasMac")
    if args.output.name != f"{NAME}.app" or args.output.exists():
        sys.exit(f"--output must be a new path named {NAME}.app")
    args.output.mkdir(parents=True)
    try:
        macos = args.output / "Contents" / "MacOS"
        macos.mkdir(parents=True)
        (args.output / "Contents" / "Resources").mkdir()
        shutil.copy2(args.binary, macos / "AtlasMac")
        (macos / "AtlasMac").chmod(0o755)
        with (args.output / "Contents" / "Info.plist").open("wb") as out:
            plistlib.dump(info(args), out)
    except BaseException:
        shutil.rmtree(args.output)
        raise
    print(args.output)


def feed(args):
    digest = hashlib.sha256(args.zip.read_bytes()).hexdigest()
    entry = {"revision": args.revision, "build": args.build, "contract": args.contract,
             "url": args.url, "sha256": digest}
    if args.current and args.current.is_file():
        try:
            current = json.loads(args.current.read_text())
        except ValueError:
            current = {}
        if isinstance(current.get("build"), int) and current["build"] >= args.build:
            print(f"the feed already names build {current['build']} ({current.get('revision', '?')[:12]}); "
                  f"build {args.build} is not newer", file=sys.stderr)
            sys.exit(NOT_NEWER)
    args.output.write_text(json.dumps(entry, indent=2) + "\n")
    print(json.dumps(entry))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    c = commands.add_parser("contract")
    c.add_argument("file", type=Path)
    c.set_defaults(run=contract)

    b = commands.add_parser("bundle")
    b.add_argument("--binary", type=Path, required=True)
    b.add_argument("--output", type=Path, required=True)
    b.add_argument("--revision", required=True)
    b.add_argument("--build", type=int, required=True)
    b.add_argument("--contract", required=True)
    b.add_argument("--feed-url", required=True)
    b.add_argument("--env", default="prod")
    b.add_argument("--host", default="127.0.0.1")
    b.add_argument("--port", type=int, default=7593)
    b.set_defaults(run=bundle)

    f = commands.add_parser("feed")
    f.add_argument("--revision", required=True)
    f.add_argument("--build", type=int, required=True)
    f.add_argument("--contract", required=True)
    f.add_argument("--url", required=True)
    f.add_argument("--zip", type=Path, required=True)
    f.add_argument("--current", type=Path, help="the feed published now, if any")
    f.add_argument("--output", type=Path, required=True)
    f.set_defaults(run=feed)

    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
