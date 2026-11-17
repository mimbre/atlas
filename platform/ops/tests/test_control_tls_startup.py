"""Private local subprocess fixtures. Never run a real Tailscale binary or enroll a node."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]

# macOS protected system utilities cannot see the materialized-folder mapping.
# These local adapters perform the same filesystem operations through Python; they
# neither bypass the sandbox nor change TMPDIR, and are used only in this fixture.
FILESYSTEM = r'''
import os,sys,tempfile
from pathlib import Path
name=Path(sys.argv[0]).name; args=sys.argv[1:]
if name=='mkdir':
    for path in args[1:]: Path(path).mkdir(parents=True,exist_ok=True)
elif name=='chmod':
    for path in args[1:]: os.chmod(path,int(args[0],8))
elif name=='mktemp':
    template=Path(args[0]); fd,path=tempfile.mkstemp(prefix=template.name.split('XXXXXX')[0],dir=template.parent)
    os.close(fd); print(path)
elif name=='rm':
    for path in args[1:]: Path(path).unlink(missing_ok=True)
'''

FAKE = r'''
import json,os,sys,time,socket,signal,stat
from pathlib import Path
name=Path(sys.argv[0]).name; root=Path(os.environ['FIXTURE']); args=sys.argv[1:]
event={'name':name,'args':args,'pid':os.getpid(),'secret_in_env':'TS_AUTHKEY' in os.environ or 'control_ts_key' in os.environ}
if name=='tailscale' and 'up' in args and any(a.startswith('--auth-key=file:') for a in args):
    key=Path(next(a.split('file:',1)[1] for a in args if a.startswith('--auth-key=file:')))
    event.update(private=stat.S_IMODE(key.stat().st_mode)==0o600, key_ok=key.read_text()=='synthetic-only-key')
with (root/'events').open('a') as f: f.write(json.dumps(event)+'\n')
def socket_arg(): return Path(next(a.split('=',1)[1] for a in args if a.startswith('--socket=')))
if name=='tailscale':
    # Like the real CLI: every command talks to the owned daemon over --socket, so
    # nothing (least of all BackendState) is answered unless that daemon is serving.
    try: os.kill(int(socket_arg().read_text()),0)
    except (OSError,ValueError):
        print('failed to connect to local tailscaled',file=sys.stderr); sys.exit(1)
    if 'status' in args:
        print(json.dumps({'BackendState':(root/'state').read_text()})); sys.exit(0)
    if 'up' in args:
        if os.environ.get('FAIL_LOGIN'): sys.exit(8)
        (root/'state').write_text('Running'); sys.exit(0)
    if 'serve' in args and 'reset' not in args:
        if os.environ.get('FAIL_SERVE'): sys.exit(7)
    else: sys.exit(0)
if name=='apply-move.sh':
    if os.environ.get('END_HOLD'): Path(os.environ['ATLAS_HOLD_FILE']).unlink(missing_ok=True)
    sys.exit(0)
if name=='verify.py': sys.exit(0)
if name=='atlas':
    if os.environ.get('ATLAS_CONTROL_TAILSCALE','0')=='0': sys.exit(0)
    s=socket.socket(socket.AF_INET6); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    s.bind(('::',int(os.environ['CONTROL_PORT']))); s.listen()
if name=='tailscaled':
    if os.environ.get('FAIL_DAEMON'): sys.exit(9)
    socket_arg().write_text(str(os.getpid()))  # serving: the socket now answers
while True: time.sleep(.05)
'''


class StartupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        for folder in ['platform/ops', 'platform/atlas_facts/rela/scripts', 'release/bin', 'bin']:
            (self.base / folder).mkdir(parents=True, exist_ok=True)
        for name in ['core-run.sh', 'control-tailscale.sh']:
            (self.base/'platform/ops'/name).write_text((ROOT/'platform/ops'/name).read_text())
        for name in ['bin/tailscale', 'bin/tailscaled', 'release/bin/atlas',
                     'platform/ops/apply-move.sh', 'platform/atlas_facts/rela/scripts/verify.py']:
            path = self.base/name
            path.write_text('#!'+sys.executable+'\n'+FAKE)
            path.chmod(0o755)
        for name in ['mkdir','chmod','mktemp','rm']:
            path = self.base/'bin'/name
            path.write_text('#!'+sys.executable+'\n'+FILESYSTEM)
            path.chmod(0o755)
        import socket
        with socket.socket(socket.AF_INET6) as sock:
            sock.bind(('::1', 0)); self.port = sock.getsockname()[1]
        settings = self.base/'settings.json'
        settings.write_text(json.dumps({'env':'test','control':{'host':'::','port':self.port}}))
        (self.base/'state').write_text('Running')
        self.env = dict(os.environ, PATH=str(self.base/'bin')+':'+os.environ['PATH'],
            FIXTURE=str(self.base), ATLAS_APP_DIR=str(self.base), ATLAS_ENV='test',
            ATLAS_ENV_FILE=str(settings), CONTROL_PORT=str(self.port),
            ATLAS_CONTROL_TAILSCALE='1', TS_AUTHKEY='synthetic-only-key',
            ATLAS_HOLD_FILE=str(self.base/'hold'),
            ATLAS_CONTROL_TS_STATE_DIR=str(self.base/'node'),
            ATLAS_CONTROL_TS_SOCKET_DIR=str(self.base/'sock'))
        self.process = None

    def events(self):
        file = self.base/'events'
        return [json.loads(line) for line in file.read_text().splitlines()] if file.exists() else []

    def start(self):
        self.output = (self.base/'output').open('w+')
        self.addCleanup(self.output.close)
        self.process = subprocess.Popen(['bash', str(self.base/'platform/ops/core-run.sh')], env=self.env,
            stdout=self.output, stderr=subprocess.STDOUT, start_new_session=True)
        self.addCleanup(self.stop)
        return self.process

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try: self.process.wait(timeout=6)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL); self.process.wait()
        # Retain subprocess events and stderr even when a fixture assertion fails.
        evidence = os.environ.get('CONTROL_TEST_EVIDENCE')
        if evidence and (self.base/'output').exists():
            dest = Path(evidence)/(self.id().split('.')[-1]+'-'+self.base.name)
            dest.mkdir(exist_ok=True)
            for name in ['events','output']:
                if (self.base/name).exists(): (dest/name).write_text((self.base/name).read_text())

    def until(self, predicate):
        deadline = time.monotonic()+8
        while time.monotonic()<deadline:
            if predicate(): return
            time.sleep(.03)
        self.fail('private startup fixture timed out: '+(self.base/'output').read_text())

    def assert_clean(self):
        self.assertFalse(any(e['secret_in_env'] for e in self.events()))
        self.assertNotIn('synthetic-only-key', (self.base/'output').read_text())
        self.assertFalse(list((self.base/'sock').glob('authkey.*')))
        for event in self.events():
            if event['name'] in ['tailscaled','atlas'] or 'serve' in event['args']:
                with self.assertRaises(ProcessLookupError, msg=str(event)): os.kill(event['pid'], 0)

    def test_disabled_and_hold_never_start_sidecar_and_strip_secret(self):
        self.env['ATLAS_CONTROL_TAILSCALE']='0'
        self.start().wait(timeout=5)
        self.assertEqual([e['name'] for e in self.events()], ['apply-move.sh','verify.py','atlas'])
        self.assert_clean()

    def test_held_does_not_verify_or_enroll_even_when_enabled(self):
        (self.base/'hold').touch()
        self.start()
        self.until(lambda: 'held:' in (self.base/'output').read_text())
        self.assertEqual([e['name'] for e in self.events()], ['apply-move.sh'])
        self.stop(); self.assert_clean()

    def test_apply_move_ends_hold_before_sidecar_and_state_reuse_needs_no_key(self):
        (self.base/'hold').touch(); self.env['END_HOLD']='1'
        self.env.pop('TS_AUTHKEY')
        self.start()
        self.until(lambda: any('serve' in e['args'] for e in self.events()))
        self.assertEqual([e['name'] for e in self.events()][:2], ['apply-move.sh','verify.py'])
        self.assertFalse(any('up' in e['args'] for e in self.events()))
        daemon = next(e for e in self.events() if e['name']=='tailscaled')
        self.assertIn('--tun=userspace-networking', daemon['args'])
        self.assertIn('--statedir='+str(self.base/'node'), daemon['args'])
        serve = next(e for e in self.events() if 'serve' in e['args'])
        self.assertEqual(serve['args'][1:], ['serve','--tls-terminated-tcp=443',f'tcp://localhost:{self.port}'])
        self.assertNotIn('--bg', serve['args'])
        self.stop(); self.assert_clean()

    def test_first_login_uses_private_file_and_no_secret_in_any_child(self):
        (self.base/'state').write_text('NeedsLogin')
        self.start()
        self.until(lambda: any('serve' in e['args'] for e in self.events()))
        login = next(e for e in self.events() if 'up' in e['args'])
        self.assertTrue(login['private']); self.assertTrue(login['key_ok'])
        self.assertNotIn('synthetic-only-key', json.dumps(self.events()))
        self.stop(); self.assert_clean()

    def test_serve_failure_stops_owned_core_and_daemon(self):
        self.env['FAIL_SERVE']='1'
        self.assertNotEqual(self.start().wait(timeout=8), 0)
        self.assertIn('Serve exited', (self.base/'output').read_text())
        self.assert_clean()

    def test_daemon_failure_never_starts_core(self):
        self.env['FAIL_DAEMON']='1'
        self.assertNotEqual(self.start().wait(timeout=8), 0)
        # Awaited signals: core-run has exited (wait above) and the gate reported, via
        # kill -0, that the owned daemon had exited. The fake daemon logs its event before it
        # exits and every gate probe runs in the foreground, so the event log is now complete.
        self.assertIn('owned tailscaled exited', (self.base/'output').read_text())
        events = self.events()
        # apply-move and verify run sequentially in the foreground, so their order is fixed.
        self.assertEqual([e['name'] for e in events][:2], ['apply-move.sh','verify.py'])
        # The backgrounded daemon and the gate's concurrent `status` probes may log in any
        # order: assert membership, not position.
        daemons = [e for e in events[2:] if e['name']=='tailscaled']
        self.assertEqual(len(daemons), 1, events)
        sock = self.base/'sock'/'tailscaled.sock'
        self.assertIn('--socket='+str(sock), daemons[0]['args'])
        self.assertFalse(sock.exists())  # a daemon that never came up never published its socket
        # The readiness gate itself must hold: past verify, only the daemon and the gate's
        # status probes ever ran; never set, up, the core or serve.
        for event in events[2:]:
            if event is not daemons[0]:
                self.assertEqual((event['name'], event['args'][1:2]), ('tailscale', ['status']), event)
        self.assertFalse(any(e['name']=='atlas' or 'set' in e['args'] or 'serve' in e['args']
                             for e in events))
        self.assert_clean()

    def test_missing_key_for_unauthorized_state_fails_closed(self):
        (self.base/'state').write_text('NeedsLogin'); self.env.pop('TS_AUTHKEY')
        self.assertNotEqual(self.start().wait(timeout=8), 0)
        self.assertFalse(any(e['name']=='atlas' for e in self.events()))
        self.assert_clean()

    def test_login_failure_removes_key_file_and_starts_no_core(self):
        (self.base/'state').write_text('NeedsLogin'); self.env['FAIL_LOGIN']='1'
        self.assertNotEqual(self.start().wait(timeout=8), 0)
        self.assertFalse(any(e['name']=='atlas' for e in self.events()))
        self.assert_clean()

    def test_stopped_persisted_node_resumes_without_key(self):
        (self.base/'state').write_text('Stopped'); self.env.pop('TS_AUTHKEY')
        self.start()
        self.until(lambda: any('serve' in e['args'] for e in self.events()))
        resume = next(e for e in self.events() if 'up' in e['args'])
        self.assertFalse(any(a.startswith('--auth-key') for a in resume['args']))
        restrict = next(e for e in self.events() if 'set' in e['args'])
        for flag in ['--advertise-routes=','--advertise-tags=','--advertise-exit-node=false','--ssh=false']:
            self.assertIn(flag, restrict['args'])
        self.stop(); self.assert_clean()

    def test_absent_opt_in_starts_only_default_core(self):
        self.env.pop('ATLAS_CONTROL_TAILSCALE')
        self.assertEqual(self.start().wait(timeout=5),0)
        self.assertEqual([e['name'] for e in self.events()], ['apply-move.sh','verify.py','atlas'])
        self.assert_clean()


if __name__ == '__main__': unittest.main()
