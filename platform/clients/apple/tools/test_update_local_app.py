"""Isolated local update smoke; no real app, service, network, or Control."""
import contextlib
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import update_local_app as updater


class UpdateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="atlas-update-test-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.app = root / "Atlas Console.app"
        mac = self.app / "Contents/MacOS"
        resources = self.app / "Contents/Resources"
        mac.mkdir(parents=True)
        resources.mkdir()
        self.binary = root / "new-binary"
        shutil.copyfile("/usr/bin/false", self.binary)
        self.binary.chmod(0o755)
        old = mac / "AtlasMac"
        shutil.copyfile("/usr/bin/true", old)
        old.chmod(0o755)
        launcher = mac / "AtlasLauncher"
        launcher.write_text("#!/bin/sh\nexit 0\n")
        launcher.chmod(0o755)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "local.atlas.console", "CFBundleExecutable": "AtlasLauncher",
            "CFBundlePackageType": "APPL", "AtlasLocalDevelopment": True, "AtlasGitCommit": "a" * 40}))
        (resources / "SourceProvenance.txt").write_text("old")
        (resources / "LocalPackaging.json").write_text(json.dumps({
            "binary_sha256": updater.sha(old), "source_provenance_sha256": "old",
            "launcher_argv": ["--env", "prod", "--host", "private.host", "--port", "7593"]}))
        (resources / "user-file").write_text("preserve")
        subprocess.run(["codesign", "--force", "--sign", "-", str(self.app)], check=True)

    def invoke(self, *, is_running=False, tested=None, latest="b" * 40):
        real_run = updater.run
        def fake_run(*args, **kwargs):
            if args[0] == "codesign":
                return real_run(*args, **kwargs)
            return subprocess.CompletedProcess(args, 0)
        def fake_output(*args):
            if args[0] == "swift":
                return str(self.binary.parent)
            if args[1] == "ls-remote":
                return latest + "\trefs/heads/master"
            return "b" * 40
        # The fake build output still exercises the actual signing and atomic exchange.
        build_binary = self.binary.parent / "AtlasMac"
        build_binary.write_bytes(self.binary.read_bytes())
        build_binary.chmod(0o755)
        with patch.object(updater, "run", side_effect=fake_run), \
             patch.object(updater, "output", side_effect=fake_output), \
             patch.object(updater, "tested_revision", side_effect=tested), \
             patch.object(updater, "running", return_value=is_running), \
             contextlib.redirect_stdout(io.StringIO()):
            updater.update(self.app)

    def test_atomic_update_preserves_identity_endpoint_and_old_bundle(self):
        self.invoke()
        info, record = updater.metadata(self.app)
        self.assertEqual(info["AtlasGitCommit"], "b" * 40)
        self.assertEqual(info["CFBundleIdentifier"], "local.atlas.console")
        self.assertEqual(record["launcher_argv"][3], "private.host")
        self.assertEqual((self.app / "Contents/Resources/user-file").read_text(), "preserve")
        backups = list(self.app.parent.glob(".atlas-console-update-*/previous-bundle"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(updater.metadata(backups[0])[0]["AtlasGitCommit"], "a" * 40)
        subprocess.run(["codesign", "--verify", "--strict", str(self.app)], check=True)

    def test_running_and_unverified_leave_original_untouched(self):
        self.invoke(is_running=True)
        self.assertEqual(updater.metadata(self.app)[0]["AtlasGitCommit"], "a" * 40)
        with self.assertRaisesRegex(RuntimeError, "unverified"):
            self.invoke(tested=RuntimeError("unverified"))
        with self.assertRaisesRegex(RuntimeError, "master changed"):
            self.invoke(latest="c" * 40)
        self.assertEqual(updater.metadata(self.app)[0]["AtlasGitCommit"], "a" * 40)
        self.assertFalse(list(self.app.parent.glob(".atlas-console-update-*")))

    def test_release_gate_requires_exact_revision_and_success(self):
        rev = "b" * 40
        runs = {"workflow_runs": [{"head_sha": rev, "name": "CI", "status": "completed",
                                   "jobs_url": "https://example.invalid/jobs"}]}
        jobs = {"jobs": [{"name": "Deploy prod on Fly, and a smoke check", "conclusion": "success"}]}
        def response(data):
            return io.BytesIO(json.dumps(data).encode())
        with patch.object(updater.urllib.request, "urlopen",
                          side_effect=[response(runs), response(jobs)]):
            updater.tested_revision(rev)
        with patch.object(updater.urllib.request, "urlopen", return_value=response(runs)):
            with self.assertRaisesRegex(RuntimeError, "no completed CI"):
                updater.tested_revision("c" * 40)
        jobs["jobs"][0]["conclusion"] = "failure"
        with patch.object(updater.urllib.request, "urlopen",
                          side_effect=[response(runs), response(jobs)]):
            with self.assertRaisesRegex(RuntimeError, "no completed CI"):
                updater.tested_revision(rev)


if __name__ == "__main__":
    unittest.main()
