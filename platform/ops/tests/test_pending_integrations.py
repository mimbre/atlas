"""pending-integrations.sh lists unfinished integrate requests of one repository in Code's
journal and changes nothing; on Fly through one read-only `fly ssh console` command."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / 'platform/ops/pending-integrations.sh'
PROD = json.loads((ROOT / 'products/software_factory/environments/prod.json').read_text())


def record(n, repository, **extra):
    request = {'version': 1, 'id': f'{n:064x}', 'run': f'run-{n}', 'subject': f'PR-{n}',
               'operation': 'integrate',
               'target': f'https://github.com/{repository}/pull/{n}',
               'payload': {'revision': f'{n:040x}'}}
    return {'request': request, 'digest': 'd' * 64, **extra}


def journal(folder):
    effects = folder / 'effects'
    effects.mkdir(parents=True)
    records = [
        record(1, 'eyra/atlas', phase='accepted', line=['a' * 40]),
        record(2, 'eyra/atlas', phase='merging', merging='b' * 40, merge_attempted=True,
               line=['c' * 40, 'b' * 40]),
        record(3, 'eyra/atlas', phase='checking', line=['d' * 40],
               outcome={'status': 'done', 'reference': 'e' * 40, 'outputs': {}}),
        record(4, 'mimbre/atlas', outcome={'status': 'refused', 'reason': 'repository_not_allowed',
                                            'details': {}}),
        record(5, 'mimbre/atlas', phase='updating', line=['f' * 40]),
    ]
    for r in records:
        (effects / (r['request']['id'] + '.json')).write_text(json.dumps(r))
    return effects


def digest(folder):
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(folder.iterdir())}


def ids(out):
    return re.findall(r'\bid=([0-9a-f]{64})\b', out)


class PendingIntegrationsTest(unittest.TestCase):
    def run_script(self, *args, env=None):
        return subprocess.run(['bash', str(SCRIPT), *args], text=True, capture_output=True,
                              timeout=30, env=env or os.environ)

    def test_lists_only_unfinished_requests_of_the_repository_and_changes_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            effects = journal(Path(temporary) / 'code')
            before = digest(effects)
            result = self.run_script('--journal', str(effects))
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(sorted(ids(result.stdout)), [f'{1:064x}', f'{2:064x}'])
            self.assertEqual(digest(effects), before)

            other = self.run_script('--journal', str(effects), '--repository', 'mimbre/atlas')
            self.assertEqual(other.returncode, 1, other.stderr)
            self.assertEqual(ids(other.stdout), [f'{5:064x}'])

            none = self.run_script('--journal', str(effects), '--repository', 'someone/else')
            self.assertEqual(none.returncode, 0, none.stderr)
            self.assertEqual(ids(none.stdout), [])

    def test_an_unreadable_record_is_never_taken_for_finished(self):
        with tempfile.TemporaryDirectory() as temporary:
            effects = Path(temporary) / 'effects'
            effects.mkdir()
            (effects / ('9' * 64 + '.json')).write_text('{not json')
            result = self.run_script('--journal', str(effects))
            self.assertEqual(result.returncode, 2)

    def test_on_fly_it_runs_one_read_only_ssh_console_command_on_the_prod_core(self):
        with tempfile.TemporaryDirectory() as temporary:
            private = Path(temporary)
            data = private / 'data/code'
            effects = journal(data)
            before = digest(effects)
            binary = private / 'bin'
            binary.mkdir()
            calls = private / 'calls.jsonl'
            # The stand-in splits -C as Fly does and runs it here, so the quoting is tested too.
            stub = binary / 'fly'
            stub.write_text(f'''#!/usr/bin/env python3
import json, shlex, subprocess, sys
with open({str(calls)!r}, 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
words = shlex.split(sys.argv[sys.argv.index('-C') + 1])
sys.exit(subprocess.run(words).returncode)
''')
            stub.chmod(0o755)
            env = dict(os.environ, PATH=f'{binary}:/usr/bin:/bin')
            result = self.run_script('--data', str(data), env=env)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(sorted(ids(result.stdout)), [f'{1:064x}', f'{2:064x}'])
            self.assertEqual(digest(effects), before)

            [call] = [json.loads(line) for line in calls.read_text().splitlines()]
            self.assertEqual(call[:4], ['ssh', 'console', '-q', '-a'])
            self.assertEqual(call[4], PROD['fly']['app'])
            self.assertEqual(call[5], '-C')
            words = shlex.split(call[6])
            self.assertEqual(words[:2], ['sh', '-c'])
            # Nothing that writes, moves, holds or restarts; only the stderr of cd is dropped.
            command = words[2].replace('2>/dev/null', '')
            self.assertNotIn('>', command)
            for word in ['rm', 'mv', 'cp', 'mkdir', 'touch', 'tee', 'kill', 'restart', 'hold']:
                self.assertIsNone(re.search(rf'\b{word}\b', command), word)

    def test_a_cut_off_answer_is_an_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'bin'
            binary.mkdir()
            stub = binary / 'fly'
            stub.write_text('#!/bin/sh\necho missing\n')
            stub.chmod(0o755)
            env = dict(os.environ, PATH=f'{binary}:/usr/bin:/bin')
            self.assertEqual(self.run_script(env=env).returncode, 2)


if __name__ == '__main__':
    unittest.main()
