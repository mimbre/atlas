"""The atlas-runtime CLI built from this tree, once per test process, for its node commands."""
import atexit
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
_built = None


def executable():
    """Path of a fresh atlas-runtime built from tools/runtime; removed when the process exits."""
    global _built
    if _built is None:
        folder = Path(tempfile.mkdtemp(prefix='atlas-runtime-cli-'))
        atexit.register(shutil.rmtree, folder, True)
        binary = folder/'atlas-runtime'
        result = subprocess.run(['go', '-C', str(ROOT/'tools/runtime'), 'build', '-o', str(binary), '.'], text=True, capture_output=True)
        if result.returncode != 0:
            raise RuntimeError('Building the Runtime CLI failed:\n'+result.stdout+result.stderr)
        _built = binary
    return str(_built)
