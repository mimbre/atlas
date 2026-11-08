"""Build the actual workspace command for isolated Python integration tests."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


def setup_workspace_cli():
    folder = tempfile.TemporaryDirectory(prefix='atlas-workspace-test-')
    unittest.addModuleCleanup(folder.cleanup)
    root = Path(__file__).resolve().parents[4]
    executable = str(Path(folder.name) / 'atlas-runtime')
    subprocess.run(['go', '-C', 'tools/runtime', 'build', '-o', executable, '.'],
                   cwd=root, check=True)
    environment = patch.dict(os.environ, {'ATLAS_RUNTIME_EXECUTABLE': executable})
    environment.start()
    unittest.addModuleCleanup(environment.stop)
