"""Private packaging/launcher checks: never execute AtlasMac or contact Control."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

HELPER = Path(__file__).with_name("package_local_app.py")


class LocalAppTest(unittest.TestCase):
    def test_bundle_launcher_forwards_only_explicit_configuration_after_move(self):
        with tempfile.TemporaryDirectory(prefix="atlas package private ") as temp:
            root = Path(temp)
            binary = root / "already built stand-in"
            # Shell fixture only. It records exact arguments and exits with a known code.
            binary.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ARGV_RECORD"\nexit 23\n')
            binary.chmod(0o755)
            provenance = root / "source provenance.txt"
            provenance.write_text("SYNTHETIC PRIVATE FIXTURE; never a product binary\n")
            info = root / "existing Info.plist"
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "local.atlas.console",
                                            "CFBundleExecutable": "OldEntry",
                                            "ExistingPublicMetadata": "preserved"}))
            app = root / "staged app" / "Atlas Console.app"
            env = "private env 'quoted' $(false)"
            host = "private host with spaces"
            command = [sys.executable, str(HELPER), "--binary", str(binary),
                       "--output", str(app), "--provenance", str(provenance),
                       "--info-plist", str(info), "--env", env, "--host", host,
                       "--port", "17593"]
            packaged = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(packaged.returncode, 0, packaged.stderr)
            # A second packaging attempt must not overwrite an existing bundle.
            refused = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(refused.returncode, 0)
            moved = root / "moved folder with spaces" / "Atlas Console.app"
            moved.parent.mkdir()
            app.rename(moved)
            binary.unlink()
            contents = moved / "Contents"
            metadata = plistlib.loads((contents / "Info.plist").read_bytes())
            self.assertEqual(metadata["CFBundleIdentifier"], "local.atlas.console")
            self.assertEqual(metadata["ExistingPublicMetadata"], "preserved")
            self.assertTrue(metadata["AtlasLocalDevelopment"])
            self.assertEqual(metadata["CFBundlePackageType"], "APPL")
            record = root / "recorded argv.txt"
            result = subprocess.run([str(contents / "MacOS" / metadata["CFBundleExecutable"]),
                                     "--env", "unapproved override", "-psn_0_123"],
                                    cwd="/", env={**os.environ, "ARGV_RECORD": str(record)},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 23, result.stderr)
            expected = ["--env", env, "--host", host, "--port", "17593"]
            self.assertEqual(record.read_text().splitlines(), expected)
            resources = contents / "Resources"
            self.assertEqual((resources / "SourceProvenance.txt").read_bytes(), provenance.read_bytes())
            manifest = json.loads((resources / "LocalPackaging.json").read_text())
            self.assertEqual(manifest["launcher_argv"], expected)
            self.assertEqual(manifest["binary_sha256"], hashlib.sha256(
                (contents / "MacOS/AtlasMac").read_bytes()).hexdigest())
            print("Private stand-in only: relocated bundle, exact argv, metadata, digest, exit 23; PASS")

    def test_invalid_endpoint_creates_no_bundle(self):
        with tempfile.TemporaryDirectory(prefix="atlas package invalid ") as temp:
            root = Path(temp)
            output = root / "Rejected.app"
            result = subprocess.run([sys.executable, str(HELPER), "--binary", str(HELPER),
                                     "--provenance", str(HELPER), "--output", str(output),
                                     "--env", "private", "--host", "localhost", "--port", "0"],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("port in 1...65535", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
