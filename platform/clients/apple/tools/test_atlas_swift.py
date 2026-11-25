"""Tests of tools/atlas_swift.py against a local bare repository: python3 -B tools/test_atlas_swift.py"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).with_name("atlas_swift.py")


class AtlasSwiftTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.contract = self.dir / "contract.ex"
        self.set_version("0.24.0")
        self.remote = self.dir / "remote.git"
        subprocess.run(["git", "init", "--quiet", "--bare", "--initial-branch=main", str(self.remote)], check=True)
        self.package = self.dir / "swift"
        self.write("Package.swift", "// package\n")
        self.write("Sources/Kit/Contract.swift", 'static let version = "0.24.0"\n')
        self.write(".build/debug/junk", "not part of it\n")

    def tearDown(self):
        self.tmp.cleanup()

    def set_version(self, version):
        self.contract.write_text(f'defmodule C do\n  # 0.1.0: first\n  version "{version}"\nend\n')

    def write(self, path, text):
        (self.package / path).parent.mkdir(parents=True, exist_ok=True)
        (self.package / path).write_text(text)

    def run_tool(self, *args):
        return subprocess.run([sys.executable, "-B", str(TOOL), "--contract", str(self.contract), *args],
                              capture_output=True, text=True)

    def tagged(self, tag):
        listing = subprocess.run(["git", "--git-dir", str(self.remote), "ls-tree", "-r", "--name-only", tag],
                                 capture_output=True, text=True, check=True)
        return listing.stdout.split()

    def test_the_contract_version(self):
        self.assertEqual(self.run_tool("version").stdout.strip(), "0.24.0")

    def test_publishes_a_version_whose_tag_is_missing(self):
        result = self.run_tool("publish", str(self.package), str(self.remote), "--source", "abc")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("published 0.24.0", result.stdout)
        self.assertEqual(self.tagged("0.24.0"), ["Package.swift", "Sources/Kit/Contract.swift"])

    def test_a_version_with_a_tag_is_left_as_it_is(self):
        self.run_tool("publish", str(self.package), str(self.remote))
        self.write("Sources/Kit/Blocks.swift", "// new\n")
        again = self.run_tool("publish", str(self.package), str(self.remote))
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("0.24.0 is published already; nothing to publish", again.stdout)
        self.assertNotIn("Sources/Kit/Blocks.swift", self.tagged("0.24.0"))

    def test_a_new_version_replaces_the_package_on_main(self):
        self.run_tool("publish", str(self.package), str(self.remote))
        self.set_version("0.25.0")
        (self.package / "Sources/Kit/Contract.swift").unlink()
        self.write("Sources/Kit/Blocks.swift", "// new\n")
        self.assertEqual(self.run_tool("publish", str(self.package), str(self.remote)).returncode, 0)
        self.assertEqual(self.tagged("0.25.0"), ["Package.swift", "Sources/Kit/Blocks.swift"])
        self.assertEqual(self.tagged("main"), self.tagged("0.25.0"))

    def test_a_package_that_was_not_generated(self):
        result = self.run_tool("publish", str(self.dir / "missing"), str(self.remote))
        self.assertEqual(result.returncode, 1)
        self.assertIn("bin/generate atlas", result.stderr)


if __name__ == "__main__":
    unittest.main()
