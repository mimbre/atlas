"""Private shell routing with inert child interpreters; no services/proxies/models."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runtime_cli

ROOT = Path(__file__).resolve().parents[2]

class CredentialRoutingTest(unittest.TestCase):
    def test_only_discovery_transport_receives_the_read_credential(self):
        with tempfile.TemporaryDirectory() as temporary:
            private=Path(temporary); binary=private/'bin';binary.mkdir()
            settings=private/'client.json';settings.write_text(json.dumps({'env':'test','control':{'host':'127.0.0.1','port':1}}))
            capture=private/'calls.jsonl'
            stub='''#!/usr/bin/python3
import os,sys,json
with open(os.environ['PRIVATE_ENV_CAPTURE'],'a') as f:
 f.write(json.dumps({'program':os.path.basename(sys.argv[0]),'command':sys.argv[1:],'read_present':'ATLAS_RUNTIME_READ_TOKEN' in os.environ,'private_var_present':'atlas_discovery_read_grant' in os.environ})+'\\n')
'''
            for command in ['mix','python3']:
                file=binary/command;file.write_text(stub);file.chmod(0o755)
            env=dict(os.environ,PATH=str(binary)+':/usr/bin:/bin',ATLAS_ENV_FILE=str(settings),ATLAS_NO_UPDATE='1',ATLAS_RUNTIME_READ_TOKEN='private-read-synthetic',PRIVATE_ENV_CAPTURE=str(capture))
            # Build before PATH holds only the stubs.
            cli=runtime_cli.executable()
            commands=[[str(ROOT/'bin/atlas'),'discover','--machine','fixture']]+[[cli,'node',op,'--checkout',str(ROOT)] for op in ['status','start','stop']]
            for command in commands:
                result=subprocess.run([*command,'--env','test'],env=env,text=True,capture_output=True)
                self.assertEqual(result.returncode,0,result.stderr)
            calls=[json.loads(line) for line in capture.read_text().splitlines()]
            self.assertEqual(sum(call['read_present'] for call in calls),1)
            # Each node operation reached the checkout's lifecycle, as atlas-runtime node launches it.
            self.assertEqual([call['command'][:4] for call in calls if call['program']=='python3'],[[str(ROOT/'tools/runtime.py'),'runtime-'+op,str(ROOT),'test'] for op in ['status','start','stop']])
            for call in calls:
                expected=call['program']=='mix' and call['command'][:2]==['atlas.agent','runtime-discover']
                self.assertEqual(call['read_present'],expected,call['command'])
                self.assertFalse(call['private_var_present'],call['command'])


    def test_python_wrapper_launcher_also_removes_read_credential(self):
        import importlib.util
        from unittest.mock import patch
        spec=importlib.util.spec_from_file_location('private_runtime_helper',ROOT/'tools/runtime.py')
        helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
        with patch.dict(os.environ,ATLAS_RUNTIME_READ_TOKEN='private-read-synthetic'),patch.object(helper.shutil,'which',return_value='/private/elixir'),patch.object(helper.subprocess,'call',return_value=0) as child:
            self.assertEqual(helper.status_cli(ROOT,'test',[],operation='start'),0)
            self.assertFalse('ATLAS_RUNTIME_READ_TOKEN' in child.call_args.kwargs['env'])


    def test_direct_elixir_status_start_stop_and_legacy_child_environments(self):
        build=next((ROOT/'bff/contract/_build'/mode/'lib' for mode in ('dev','test') if (ROOT/'bff/contract/_build'/mode/'lib/atlas_bff_contract/ebin/Elixir.AtlasBFFContract.Wire.Runtime.MachineProtocol.beam').is_file()),None)
        self.assertIsNotNone(build,'Explicit fixture setup must build the shared contract')
        paths=[arg for p in sorted(build.glob('*/ebin')) for arg in ('-pa',str(p))]
        with tempfile.TemporaryDirectory() as temporary:
            private=Path(temporary);(private/'tools').mkdir();capture=private/'capture.json'
            diagnostic=dict(target=dict(environment='test',machine='fixture'),state='unsupported',basis='private_inert',message='private inert helper',capabilities=dict(local_status=True,local_start=False,local_stop=False,remote_status=False))
            stub='import os,json\nfrom pathlib import Path\nPath('+repr(str(capture))+').write_text(json.dumps({"read_present":"ATLAS_RUNTIME_READ_TOKEN" in os.environ}))\nprint('+repr(json.dumps(diagnostic))+')\n'
            (private/'tools/runtime.py').write_text(stub)
            env={key:value for key,value in os.environ.items() if not key.startswith('ATLAS_')}
            env.update(ATLAS_RUNTIME_READ_TOKEN='private-read-synthetic',ELIXIR_ERL_OPTIONS='+S 1:1')
            for action in ['status','start','stop','legacy']:
                with self.subTest(action=action):
                    operation=[] if action=='legacy' else ['--operation',action,'unused']
                    result=subprocess.run(['elixir',*paths,str(ROOT/'tools/runtime_status.exs'),str(private),'test',str(private/'missing.json'),*operation,'--machine','fixture','--json'],env=env,text=True,capture_output=True,timeout=5)
                    self.assertEqual(result.returncode,0 if action in ['status','legacy'] else 2,result.stderr)
                    frame=json.loads(result.stdout)
                    self.assertEqual(frame['op'],'machine_status_result' if action in ['status','legacy'] else 'machine_'+action+'_error')
                    self.assertFalse(json.loads(capture.read_text())['read_present'],action)
                    self.assertNotIn('private-read-synthetic',result.stdout+result.stderr)

if __name__=='__main__':unittest.main()
