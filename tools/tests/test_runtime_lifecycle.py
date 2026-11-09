"""Lifecycle ownership regressions: all signal and process APIs mocked."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('runtime_lifecycle_subject', ROOT/'tools/runtime.py')
subject = importlib.util.module_from_spec(spec); spec.loader.exec_module(subject)


class LegacySignalRegression(unittest.TestCase):
    def test_legacy_stop_never_uses_pid_only_group_signalling(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary); (base/'runtime.pid').write_text('1234')
            client = base/'client.json'; client.write_text('{"env": "test"}')
            with patch.dict(os.environ, ATLAS_RUNTIME_HOME=str(base), ATLAS_ENV_FILE=str(client)), patch.object(sys, 'argv', ['runtime.py', 'runtime-stop', str(ROOT), 'test']), patch.object(subject.os, 'kill'), patch.object(subject.os, 'killpg') as groups, patch.object(subject.time, 'sleep'), patch.object(subject.subprocess, 'call', return_value=2):
                try: subject.main()
                except SystemExit: pass
                groups.assert_not_called()


class OwnershipLifecycleTest(unittest.TestCase):
    def fixture(self, directory):
        from types import SimpleNamespace
        module_spec = importlib.util.spec_from_file_location('owned_runtime_subject', ROOT/'tools/runtime_process.py')
        module = importlib.util.module_from_spec(module_spec); module_spec.loader.exec_module(module)
        directory = Path(directory).resolve()
        configuration = directory/'runtime.json'; client = directory/'client.json'
        configuration.write_text(json.dumps({'env':'test','runtime':{'machine':'fixture','agents':{'stub':{'port':'stub'}}},'bus_link':{'mode':'client','machine':'fixture','port':1234}}))
        client.write_text(json.dumps({'env':'test'}))
        snapshots = {}; live = {}; calls=[]
        def validate(pid):
            if type(pid) is not int or not 1 < pid < 2**31: raise ValueError('invalid PID')
            return pid
        def identity(pid):
            calls.append(pid)
            if not live[pid]: raise ProcessLookupError('gone')
            return dict(snapshots[pid])
        def state(pid):
            if not live[pid]: raise ProcessLookupError('gone')
            return dict(pid=pid,start=snapshots[pid]['start'],uid=os.getuid(),terminal=False)
        inspector=SimpleNamespace(validate_pid=validate,parse_pid=lambda s:validate(int(s)),process_identity=identity,process_state=state)
        controller=module.LocalRuntime(ROOT,'test','fixture',directory,configuration,client,inspector=inspector)
        record=dict(version='1',target=dict(environment='test',machine='fixture'),directory=str(directory),configuration=str(configuration),root=str(ROOT),client=str(client),instance='a'*32,phase='started',processes={})
        pid=111
        snapshots[pid]=dict(pid=pid,start=['birth',str(pid)],uid=os.getuid(),exe='/erlang/beam.smp',argv=['beam',*controller._boot_args(record['instance'])])
        live[pid]=True
        record['processes']['runtime']={key:snapshots[pid][key] for key in ('pid','uid','start')}
        (directory/'runtime.pid').write_text(str(pid))
        (directory/'runtime.processes.json').write_text(json.dumps(record))
        return module,controller,record,snapshots,live,calls

    def test_explicit_empty_agents_allows_connection_only_but_invalid_declarations_refuse(self):
        with tempfile.TemporaryDirectory() as temporary:
            module,c,record,snapshots,live,calls=self.fixture(temporary)
            c.file.unlink()
            (c.base/'runtime.pid').unlink()
            settings=json.loads(c.configuration.read_text())
            for agents in ({}, None, [], "", False):
                with self.subTest(agents=agents):
                    settings['runtime']['agents']=agents
                    c.configuration.write_text(json.dumps(settings))
                    if agents == {}:
                        self.assertEqual(c.configuration_data()['runtime']['agents'], {})
                    else:
                        with self.assertRaises(ValueError): c.configuration_data()
                    with patch.dict(os.environ, ATLAS_RUNTIME_HOME=str(c.base), ATLAS_RUNTIME_FILE=str(c.configuration)):
                        status=subject.observe_status(ROOT,'test',{'target':c.target},client_file=str(c.client_file))
                    self.assertEqual(status['state'],'absent')
                    self.assertEqual(status['capabilities']['local_start'], agents == {})
            del settings['runtime']['agents']
            c.configuration.write_text(json.dumps(settings))
            with self.assertRaises(ValueError): c.configuration_data()
            with patch.dict(os.environ, ATLAS_RUNTIME_HOME=str(c.base), ATLAS_RUNTIME_FILE=str(c.configuration)):
                status=subject.observe_status(ROOT,'test',{'target':c.target},client_file=str(c.client_file))
            self.assertFalse(status['capabilities']['local_start'])

    def test_corrupt_prefix_role_reuse_and_pid_records_refuse_all_signals(self):
        with tempfile.TemporaryDirectory() as temporary:
            module,c,record,snapshots,live,calls=self.fixture(temporary)
            import copy
            cases=[]
            bad=copy.deepcopy(record); bad['directory']+='-other'; cases.append((bad,None))
            bad=copy.deepcopy(record); bad['processes']['runtime']['start']=['reused']; cases.append((bad,None))
            bad=copy.deepcopy(record); bad['processes']['runtime']['pid']+=2**32; cases.append((bad,None))
            cases.append((record,'foreign-role'))
            bad=copy.deepcopy(record);bad['root']+='-prefix';cases.append((bad,None))
            bad=copy.deepcopy(record);bad['configuration']+='-prefix';cases.append((bad,None))
            bad=copy.deepcopy(record);bad['target']['environment']='prod';cases.append((bad,None))
            bad=copy.deepcopy(record);bad['target']['machine']='other';cases.append((bad,None))
            bad=copy.deepcopy(record);bad['instance']='b'*32;cases.append((bad,None))
            bad=copy.deepcopy(record);bad['processes']['runtime']['uid']=-1;cases.append((bad,None))
            # A second process role (the fly proxy before D-0089) is not this node's.
            bad=copy.deepcopy(record);bad['processes']['tunnel']=dict(bad['processes']['runtime']);cases.append((bad,None))
            for bad,alter in cases:
                with self.subTest(alter=alter), patch.object(module.os,'kill') as kill, patch.object(module.os,'killpg') as groups:
                    (c.file).write_text(json.dumps(bad))
                    original=snapshots[111]['argv']
                    if alter == 'foreign-role': snapshots[111]['argv']=['/unrelated/program']
                    try:
                        with self.assertRaises((ValueError,OSError)): c.stop()
                        kill.assert_not_called(); groups.assert_not_called()
                        self.assertTrue((c.base/'runtime.pid').exists())
                    finally:
                        snapshots[111]['argv']=original

    def test_proven_start_is_idempotent_and_stop_only_signals_proven_exact_pids(self):
        with tempfile.TemporaryDirectory() as temporary:
            module,c,record,snapshots,live,calls=self.fixture(temporary)
            with patch.object(module.subprocess,'Popen',side_effect=AssertionError('duplicate spawn')), patch.object(module.subprocess,'check_output',side_effect=AssertionError('credential lookup')):
                self.assertEqual(c.start()['instance'],record['instance'])
            sent=[]
            def terminate(pid,sig): sent.append((pid,sig)); live[pid]=False
            with patch.object(module.os,'kill',side_effect=terminate),patch.object(module.os,'killpg',side_effect=AssertionError('group signal forbidden')):
                stopped=c.stop(); self.assertEqual(stopped['phase'],'stopped')
                self.assertEqual([pid for pid,_ in sent],[111])
                self.assertEqual(set(stopped['completed_processes']),{'runtime'})
                self.assertFalse((c.base/'runtime.pid').exists())
                self.assertEqual(c.stop()['phase'],'stopped')
                self.assertEqual(len(sent),1)

    def test_busy_and_unconfirmed_exit_have_no_duplicate_or_escalation(self):
        with tempfile.TemporaryDirectory() as temporary:
            module,c,record,snapshots,live,calls=self.fixture(temporary)
            (c.base/'runtime.lock').touch()
            with patch.object(module.subprocess,'Popen') as spawn:
                with self.assertRaises(ValueError): c.start()
                spawn.assert_not_called()
            (c.base/'runtime.lock').unlink()
            with patch.object(c,'_wait_gone',return_value=False),patch.object(module.os,'kill') as kill:
                with self.assertRaises(ValueError): c.stop()
                self.assertEqual(kill.call_count,1)
                self.assertTrue((c.base/'runtime.pid').exists())

    def test_malformed_configuration_and_manifests_refuse_without_inspection(self):
        import copy
        with tempfile.TemporaryDirectory() as temporary:
            module,c,record,snapshots,live,calls=self.fixture(temporary)
            for data in [[], {"env":"test","runtime":[],"bus_link":[]}]:
                c.configuration.write_text(json.dumps(data))
                with self.subTest(configuration=data), patch.object(module.subprocess,'Popen') as spawn:
                    with self.assertRaises(ValueError): c.start()
                    spawn.assert_not_called()
            for data in [[], dict(record, instance=[]), dict(record, phase='unknown'), dict(record, processes=[]), dict(record, processes={'runtime':[]})]:
                calls.clear(); c.file.write_text(json.dumps(data))
                with self.subTest(manifest=data), patch.object(module.os,'kill') as kill:
                    with self.assertRaises(ValueError): c.stop()
                    kill.assert_not_called(); self.assertEqual(calls,[])



    def test_fresh_start_retains_birth_and_binds_receipt_before_success(self):
        from types import SimpleNamespace
        for receipt_kind in ('matching','foreign','exited'):
            with self.subTest(receipt=receipt_kind), tempfile.TemporaryDirectory() as temporary:
                module,c,record,snapshots,live,calls=self.fixture(temporary)
                c.file.unlink()
                (c.base/'runtime.pid').unlink()
                def spawn(command, **kwargs):
                    self.assertNotIn('ATLAS_RUNTIME_READ_TOKEN',kwargs['env'])
                    nonce=command[-1]
                    snapshots[111]['argv']=['beam',*c._boot_args(nonce)]
                    c._write(c.base/('runtime-ready-'+nonce+'.json'),json.dumps(dict(target=c.target,instance=nonce if receipt_kind=='matching' else 'foreign',pid=111)))
                    return SimpleNamespace(pid=111,poll=lambda: 1 if receipt_kind=='exited' else None)
                with patch.dict(os.environ,ATLAS_BUS_LINK_TOKEN='private-stub-token',ATLAS_RUNTIME_READ_TOKEN='private-read-only-secret'),patch.object(module.subprocess,'Popen',side_effect=spawn) as popen,patch.object(module.os,'kill') as kill:
                    if receipt_kind=='matching':
                        result=c.start(); self.assertEqual(result['phase'],'started'); self.assertEqual(result['processes']['runtime']['pid'],111)
                        self.assertEqual(c.start()['instance'],result['instance'])
                    else:
                        with self.assertRaises(ValueError): c.start()
                        retained=json.loads(c.file.read_text()); self.assertEqual(retained['phase'],'starting')
                        with self.assertRaises(ValueError): c.start()
                        self.assertTrue((c.base/'runtime.pid').exists())
                    self.assertEqual(popen.call_count,1);kill.assert_not_called()

    def test_missing_authority_and_legacy_pid_never_spawn_or_damage_records(self):
        with tempfile.TemporaryDirectory() as temporary:
            module,c,record,snapshots,live,calls=self.fixture(temporary)
            c.file.unlink()
            with patch.object(module.subprocess,'Popen') as spawn,patch.object(module.subprocess,'check_output') as credentials:
                with self.assertRaises(ValueError): c.start()
                credentials.assert_not_called();spawn.assert_not_called()
            (c.base/'runtime.pid').unlink()
            with patch.dict(os.environ,ATLAS_BUS_LINK_TOKEN=''),patch.object(module.subprocess,'check_output',return_value=b''),patch.object(module.subprocess,'Popen') as spawn:
                with self.assertRaises(ValueError): c.start()
                spawn.assert_not_called();self.assertFalse(c.file.exists())


    def test_keychain_and_runtime_children_exclude_read_grant_and_no_proxy_starts(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as temporary:
            module,c,record,snapshots,live,calls=self.fixture(temporary)
            c.file.unlink()
            (c.base/'runtime.pid').unlink()
            c.client_file.write_text(json.dumps({'env':'test','fly':{'in_use':True,'app':'private-app'}}))
            seen=[]
            def credential(command,**kwargs):
                seen.append(('keychain',dict(kwargs.get('env',os.environ))))
                return b'private-writer-synthetic'
            def spawn(command,**kwargs):
                role='runtime' if command[0]=='mix' else 'other:'+command[0]
                seen.append((role,dict(kwargs.get('env',os.environ))))
                nonce=command[-1];snapshots[111]['argv']=['beam',*c._boot_args(nonce)]
                c._write(c.base/('runtime-ready-'+nonce+'.json'),json.dumps(dict(target=c.target,instance=nonce,pid=111)))
                return SimpleNamespace(pid=111,poll=lambda:None)
            with patch.dict(os.environ,ATLAS_BUS_LINK_TOKEN='',ATLAS_RUNTIME_READ_TOKEN='private-read-synthetic'),patch.object(module.subprocess,'check_output',side_effect=credential),patch.object(module.subprocess,'Popen',side_effect=spawn),patch.object(module.os,'kill',side_effect=AssertionError('no real signals')):
                c.start()
            # The client file still says the environment runs on Fly: the node dials the Bus link itself.
            self.assertEqual([role for role,_ in seen],['keychain','runtime'])
            for role,env in seen:
                self.assertFalse('ATLAS_RUNTIME_READ_TOKEN' in env,role)

if __name__ == '__main__': unittest.main()
