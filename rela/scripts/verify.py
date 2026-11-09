#!/usr/bin/env python3
"""Check packaged description provenance without PyYAML, Elixir or a running service."""
import hashlib
import json
from pathlib import Path
import sys


def verify(root):
    root = Path(root).resolve()
    provenance = json.loads((root / 'atlas.manifest.json').read_text())
    for name, expected in provenance['inputs'].items():
        path = root / name
        if not path.resolve().is_relative_to(root):
            raise ValueError(f'unsafe provenance path: {name}')
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f'stale description input: {name}; run mix model.gen in model/contract')
    # atlas.json is a proof of the model's additions, read by no component: not checked.
    return provenance


if __name__ == '__main__':
    try:
        verify(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent)
    except (OSError, ValueError, KeyError, TypeError) as e:
        sys.exit(f'description: {e}')
