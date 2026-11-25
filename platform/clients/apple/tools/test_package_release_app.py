"""The release packager (no Swift build, signing or network)."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).with_name("package_release_app.py")
REVISION = "0123456789abcdef0123456789abcdef01234567"


def run(*args):
    return subprocess.run([sys.executable, "-B", str(TOOL), *args], capture_output=True, text=True)


class ReleaseAppTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.binary = self.dir / "AtlasMac"
        self.binary.write_bytes(b"\xcf\xfa\xed\xfe stand-in")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.dir)

    def bundle(self, *extra):
        return run("bundle", "--binary", str(self.binary), "--output", str(self.dir / "Atlas Console.app"),
                   "--revision", REVISION, "--build", "42", "--contract", "0.24.0",
                   "--feed-url", "https://github.com/o/r/releases/download/atlas-console/feed.json", *extra)

    def test_the_bundle_names_its_release(self):
        result = self.bundle()
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.dir / "Atlas Console.app"
        with (app / "Contents" / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
        self.assertEqual(info["CFBundleExecutable"], "AtlasMac")
        self.assertEqual(info["CFBundleShortVersionString"], "master-0123456789ab")
        self.assertEqual(info["CFBundleVersion"], "42")
        self.assertEqual(info["AtlasRevision"], REVISION)
        self.assertEqual(info["AtlasContract"], "0.24.0")
        self.assertEqual(info["AtlasControl"], {"env": "prod", "host": "127.0.0.1", "port": 7593})
        self.assertEqual((app / "Contents" / "MacOS" / "AtlasMac").read_bytes(), self.binary.read_bytes())

    def test_an_existing_bundle_is_never_replaced(self):
        self.assertEqual(self.bundle().returncode, 0)
        self.assertNotEqual(self.bundle().returncode, 0)

    def test_a_short_revision_is_refused(self):
        result = run("bundle", "--binary", str(self.binary), "--output", str(self.dir / "Atlas Console.app"),
                     "--revision", "0123456", "--build", "1", "--contract", "0.24.0", "--feed-url", "https://x/feed.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.dir / "Atlas Console.app").exists())

    def feed(self, build, current=None):
        zip_file = self.dir / "a.zip"
        zip_file.write_bytes(b"zip")
        args = ["feed", "--revision", REVISION, "--build", str(build), "--contract", "0.24.0",
                "--url", "https://x/a.zip", "--zip", str(zip_file), "--output", str(self.dir / "feed.json")]
        if current:
            args += ["--current", str(current)]
        return run(*args)

    def test_the_feed_names_the_release_and_its_digest(self):
        self.assertEqual(self.feed(42).returncode, 0)
        entry = json.loads((self.dir / "feed.json").read_text())
        self.assertEqual(entry["build"], 42)
        self.assertEqual(entry["sha256"], hashlib.sha256(b"zip").hexdigest())

    def test_the_feed_never_goes_back(self):
        current = self.dir / "current.json"
        current.write_text(json.dumps({"build": 43, "revision": "f" * 40}))
        result = self.feed(42, current)
        self.assertEqual(result.returncode, 3)
        self.assertFalse((self.dir / "feed.json").exists())
        current.write_text(json.dumps({"build": 41}))
        self.assertEqual(self.feed(42, current).returncode, 0)


if __name__ == "__main__":
    unittest.main()
