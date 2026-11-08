#!/usr/bin/env python3
"""Own a native CLI process group; parent EOF/stop interrupts it before this helper exits."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from runtime.host.process import main


if __name__ == '__main__':
    try:
        main(Path(__file__).resolve())
    except BrokenPipeError:
        pass  # Parent disappeared; main's finally has already reaped the process.
    except Exception as error:
        print(f'Native runner: {error}', file=sys.stderr)
        sys.exit(1)
