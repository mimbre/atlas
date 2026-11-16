"""Exercise private fixture lifecycles with and without an explicit TMPDIR."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import test_control_tls_launcher as launcher_fixture
import test_control_tls_startup as startup_fixture


class TempPortabilityTest(unittest.TestCase):
    def exercise(self, explicit):
        # Both the platform default and explicit directory stay in owned scratch.
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as owned:
            fallback = Path(owned) / 'default'
            selected = Path(owned) / 'explicit'
            fallback.mkdir()
            selected.mkdir()
            created = []
            temporary_directory = tempfile.TemporaryDirectory

            def track(*args, **kwargs):
                directory = temporary_directory(*args, **kwargs)
                created.append(Path(directory.name))
                return directory

            with patch.dict(os.environ), patch.object(tempfile, 'tempdir', str(fallback)), \
                    patch.object(tempfile, 'TemporaryDirectory', track):
                if explicit:
                    os.environ['TMPDIR'] = str(selected)
                else:
                    os.environ.pop('TMPDIR', None)
                startup = startup_fixture.StartupTest('test_first_login_uses_private_file_and_no_secret_in_any_child')
                result = unittest.TestResult()
                startup.run(result)
                self.assertTrue(result.wasSuccessful(), result.errors + result.failures)
                launcher = launcher_fixture.LauncherTest()
                process, calls = launcher.run_launcher('tls://fixture.tail8263c4.ts.net:443', 'get')
                self.assertEqual(process.returncode, 0, process.stderr)
                self.assertTrue(calls)
                self.assertEqual(os.environ.get('TMPDIR'), str(selected) if explicit else None)
            self.assertEqual(len(created), 2)
            self.assertTrue(all(path.parent == (selected if explicit else fallback) for path in created))
            self.assertTrue(all(not path.exists() for path in created))
            self.assertEqual(list(fallback.iterdir()), [])
            self.assertEqual(list(selected.iterdir()), [])

    def test_absent_tmpdir_uses_runtime_default_and_cleans_up(self):
        self.exercise(False)

    def test_explicit_tmpdir_takes_precedence_and_cleans_up(self):
        self.exercise(True)
