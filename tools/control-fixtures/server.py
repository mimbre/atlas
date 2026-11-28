#!/usr/bin/env python3
"""Launch the shared, read-only Control fixture endpoint."""
import argparse
import os
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scenario', required=True, choices=['decision', 'scene', 'todo', 'lists', 'empty'])
parser.add_argument('--port', type=int, default=4747)
parser.add_argument('--artifact', type=Path)
args = parser.parse_args()
if not 1 <= args.port <= 65535:
    parser.error('--port must be between 1 and 65535')
root = Path(__file__).resolve().parents[2]
artifact = args.artifact or root / 'tools/control-fixtures/.generated/product.json'
if not artifact.is_file():
    parser.error(f'no product fixture artifact at {artifact}; run product_generate.exs first')
artifact = artifact.resolve()
os.environ['MIX_ENV'] = 'test'
os.chdir(root / 'products' / 'software_factory')
os.execvp('mix', ['mix', 'run', '--no-start', str(root / 'tools/control-fixtures/server.exs'), args.scenario, str(args.port), str(artifact)])
