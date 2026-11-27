"""Isolated local update smoke; no real app, service, network, or Control."""
import contextlib
import io
import json
import os
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

    def test_release_gate_checks_failures_and_tested_tree(self):
        rev, tree = "b" * 40, "c" * 40
        run = {"id": 1, "head_sha": rev, "name": "CI", "status": "completed",
               "path": ".github/workflows/ci.yml", "conclusion": "failure",
               "repository": {"id": 10}, "jobs_url": "https://example.invalid/jobs"}
        jobs = [{"name": "Deploy prod on Fly, and a smoke check", "conclusion": "success", "status": "completed"},
                {"name": "Publish the Mac app of this release", "conclusion": "failure", "status": "completed"},
                {"name": "Apple clients", "conclusion": "skipped", "status": "completed"}]
        artifact = {"name": "tested-tree-" + tree, "expired": False,
                    "workflow_run": {"id": 2, "repository_id": 10, "head_repository_id": 10}}
        prior = {"id": 2, "path": run["path"], "repository": {"id": 10}, "head_repository": {"id": 10},
                 "status": "completed", "conclusion": "success"}
        def request(req, timeout):
            url = req.full_url
            if url == updater.API:
                data = {"workflow_runs": [run]}
            elif url.startswith("https://example.invalid/jobs"):
                data = {"jobs": jobs, "total_count": len(jobs)}
            elif "/artifacts?" in url:
                data = {"artifacts": [artifact]}
            else:
                data = prior
            return io.BytesIO(json.dumps(data).encode())
        with patch.object(updater.urllib.request, "urlopen", side_effect=request):
            updater.tested_revision(rev, tree)
            for changed, value in ((jobs[2], "failure"), (jobs[2], "cancelled"), (jobs[0], "failure")):
                original = changed["conclusion"]
                changed["conclusion"] = value
                with self.assertRaisesRegex(RuntimeError, "no qualifying CI"):
                    updater.tested_revision(rev, tree)
                changed["conclusion"] = original
            artifact["expired"] = True
            with self.assertRaisesRegex(RuntimeError, "no qualifying CI"):
                updater.tested_revision(rev, tree)
            artifact["expired"] = False
            prior["conclusion"] = "failure"
            with self.assertRaisesRegex(RuntimeError, "no qualifying CI"):
                updater.tested_revision(rev, tree)
            with self.assertRaisesRegex(RuntimeError, "no qualifying CI"):
                updater.tested_revision("d" * 40, tree)

    def test_interruption_after_exchange_retains_original(self):
        exchange = updater.swap
        def interrupted(app, candidate):
            exchange(app, candidate)
            raise KeyboardInterrupt()
        with patch.object(updater, "swap", side_effect=interrupted):
            with self.assertRaises(KeyboardInterrupt):
                self.invoke()
        backups = list(self.app.parent.glob(".atlas-console-update-*/uninstalled-or-previous-bundle"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(updater.metadata(backups[0])[0]["AtlasGitCommit"], "a" * 40)
        self.assertEqual((backups[0] / "Contents/Resources/user-file").read_text(), "preserve")

    def test_launch_environment_retains_asdf_and_existing_path(self):
        with patch.dict(os.environ, {"PATH": "/custom/bin"}, clear=True), \
             patch.object(Path, "home", return_value=self.app.parent), \
             patch.object(updater, "update") as update:
            self.assertEqual(updater.main(), 0)
            self.assertEqual(os.environ["PATH"].split(os.pathsep)[0],
                             str(self.app.parent / ".asdf/shims"))
            self.assertIn("/custom/bin", os.environ["PATH"].split(os.pathsep))
            update.assert_called_once()


if __name__ == "__main__":
    unittest.main()
