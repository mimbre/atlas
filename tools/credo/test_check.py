import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CHECK = Path(__file__).with_name("check.py")
CLEAN = 'defmodule Example do\n  @moduledoc "Example."\n\n  def value, do: :ok\nend\n'
BAD = CLEAN.replace(':ok', 'dbg(:ok)')


class CredoGateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        self.source = self.root / "platform" / "app" / "lib" / "example.ex"
        self.source.parent.mkdir(parents=True)
        self.source.write_text(CLEAN)
        self.git("add", ".")
        self.git("commit", "-qm", "baseline")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def gate(self, mode):
        return subprocess.run(["python3", str(CHECK), mode], cwd=self.root,
                              capture_output=True, text=True, env=os.environ.copy())

    def test_real_findings_use_index_not_worktree_and_keep_baseline(self):
        self.source.write_text(BAD)
        self.git("add", ".")
        self.source.write_text(CLEAN)
        result = self.gate("staged")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Credo.Check.Warning.Dbg", result.stdout)
        self.git("commit", "-qm", "existing finding")
        self.source.write_text(BAD.replace("Example.", "An example."))
        self.git("add", ".")
        result = self.gate("staged")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.gate("all")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Credo.Check.Warning.Dbg", result.stdout)

    def test_moved_finding_is_baselined_but_new_finding_is_reported(self):
        self.source.write_text(BAD)
        self.git("add", ".")
        self.git("commit", "-qm", "existing finding")
        moved = BAD.replace("  def value", "  # Context.\n  def value")
        self.source.write_text(moved)
        self.git("add", ".")
        result = self.gate("staged")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with_new = moved.replace("end\n", "\n  def other, do: dbg(:new)\nend\n")
        self.source.write_text(with_new)
        self.git("add", ".")
        result = self.gate("staged")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("Credo.Check.Warning.Dbg"), 1, result.stdout)
        self.source.write_text(moved.replace("dbg(:ok)", "dbg(:changed)"))
        self.git("add", ".")
        result = self.gate("staged")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Credo.Check.Warning.Dbg", result.stdout)

    def test_invalid_source_is_an_error(self):
        self.source.write_text("defmodule Broken do\n")
        self.git("add", ".")
        result = self.gate("staged")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_generated_and_untracked_sources_are_not_analyzed(self):
        generated = self.root / "platform" / "app" / "tmp" / "generated.ex"
        generated.parent.mkdir(parents=True)
        generated.write_text("not valid (\n")
        self.git("add", ".")
        self.source.with_name("untracked.ex").write_text("not valid (\n")
        result = self.gate("all")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1 tracked index files", result.stdout)


if __name__ == "__main__":
    unittest.main()
