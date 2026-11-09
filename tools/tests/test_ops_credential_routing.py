"""atlas-ops never hands the Runtime read credential to a child; inert stubs, no services."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class OpsCredentialRoutingTest(unittest.TestCase):
    def test_no_operating_child_receives_the_read_credential(self):
        with tempfile.TemporaryDirectory() as temporary:
            private = Path(temporary)
            binary = private / 'bin'
            binary.mkdir()
            local = private / 'on-fly'
            settings = private / 'test.json'
            settings.write_text(json.dumps({
                'env': 'test',
                'control': {'host': '127.0.0.1', 'port': 1},
                'fly': {'app': 'private-core', 'rela_app': 'private-rela', 'local': str(local),
                        'control_port': 2, 'move_from': str(private / 'nothing')},
            }))
            capture = private / 'calls.jsonl'
            stub = '''#!/usr/bin/env python3
import os,sys,json
with open(os.environ['PRIVATE_ENV_CAPTURE'],'a') as f:
 f.write(json.dumps({'program':os.path.basename(sys.argv[0]),'command':sys.argv[1:],'read_present':'ATLAS_RUNTIME_READ_TOKEN' in os.environ,'value_present':any('private-read-synthetic' in v for v in os.environ.values())})+'\\n')
'''
            for command in ['fly', 'flyctl', 'mix']:
                file = binary / command
                file.write_text(stub)
                file.chmod(0o755)
            env = dict(os.environ, PATH=str(binary) + ':' + os.environ.get('PATH', '/usr/bin:/bin'),
                       ATLAS_ENV_FILE=str(settings), ATLAS_NO_UPDATE='1',
                       ATLAS_RUNTIME_READ_TOKEN='private-read-synthetic',
                       PRIVATE_ENV_CAPTURE=str(capture))
            for words in [['status'], ['logs'], ['tunnel', 'status'], ['tunnel', 'close'], ['env']]:
                result = subprocess.run([str(ROOT / 'bin/atlas-ops'), *words, '--env', 'test'],
                                        env=env, text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, (words, result.stdout, result.stderr))
                self.assertNotIn('private-read-synthetic', result.stdout + result.stderr)
            calls = [json.loads(line) for line in capture.read_text().splitlines()]
            # status asks Fly about both apps; logs follows the core's.
            self.assertEqual([c['command'][:3] for c in calls],
                             [['status', '-a', 'private-core'], ['status', '-a', 'private-rela'],
                              ['logs', '-a', 'private-core']])
            for call in calls:
                self.assertFalse(call['read_present'], call['command'])
                self.assertFalse(call['value_present'], call['command'])


if __name__ == '__main__':
    unittest.main()
