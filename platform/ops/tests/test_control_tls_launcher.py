"""Real launcher in an inert checkout fixture; no Git, proxy, build or live service."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


class LauncherTest(unittest.TestCase):
    def run_launcher(self, endpoint, command):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as temporary:
            root = Path(temporary)
            for folder in ['bin/lib','platform/clients/agent','platform/clients/tui','products/software_factory/environments']:
                (root/folder).mkdir(parents=True)
            for name in ['bin/atlas','bin/lib/env.sh','bin/lib/update.sh']:
                (root/name).write_text((ROOT/name).read_text())
            (root/'bin/atlas').chmod(0o755)
            (root/'bin/lib/tunnel.sh').write_text('ensure_tunnel() { echo tunnel >>"$CAPTURE"; }\n')
            (root/'bin/clean-build').write_text('#!/bin/sh\nexit 0\n')
            (root/'bin/clean-build').chmod(0o755)
            mix = root/'bin/mix'
            mix.write_text('#!'+sys.executable+'\nimport os,json,sys\nwith open(os.environ["CAPTURE"],"a") as f: f.write(json.dumps({"args":sys.argv[1:],"endpoint":os.environ.get("ATLAS_CONTROL_ENDPOINT")})+"\\n")\n')
            mix.chmod(0o755)
            settings = {'env':'test','control':{'host':'127.0.0.1','port':7693},
                'fly':{'app':'private-fixture','rela_app':'private-rela','local':str(root/'data'),'control_port':7691}}
            (root/'products/software_factory/environments/test.json').write_text(json.dumps(settings))
            capture = root/'capture'
            env = dict(os.environ, PATH=str(root/'bin')+':'+os.environ['PATH'],
                CAPTURE=str(capture), ATLAS_NO_UPDATE='1')
            env.pop('ATLAS_CONTROL_ENDPOINT',None); env.pop('ATLAS_ENV_FILE',None)
            if endpoint is not None: env['ATLAS_CONTROL_ENDPOINT']=endpoint
            result = subprocess.run(['bash',str(root/'bin/atlas'),command,'--env','test'],
                env=env, capture_output=True, text=True, timeout=8)
            calls = capture.read_text().splitlines() if capture.exists() else []
            return result, calls

    def test_selected_endpoint_propagates_to_cli_steer_discovery_and_tui_without_tunnel(self):
        endpoint='tls://fixture.tail8263c4.ts.net:443'
        for command in ['get','steer','discover','tui']:
            with self.subTest(command=command):
                result,calls=self.run_launcher(endpoint,command)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertNotIn('tunnel',calls)
                self.assertTrue(calls)
                self.assertTrue(all(json.loads(c)['endpoint']==endpoint for c in calls))

    def test_invalid_and_empty_selection_fail_before_child_or_tunnel(self):
        for endpoint in ['', 'tls://short:443','tls://fixture.tail8263c4.ts.net:0',
                         'tls://fixture.tail8263c4.ts.net:65536','tcp://fixture.tail8263c4.ts.net:443']:
            result,calls=self.run_launcher(endpoint,'get')
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(calls,[])

    def test_absent_selection_preserves_default_fly_tunnel(self):
        result,calls=self.run_launcher(None,'get')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(calls[0],'tunnel')
        self.assertTrue(all(json.loads(c)['endpoint'] is None for c in calls[1:]))


if __name__ == '__main__': unittest.main()
