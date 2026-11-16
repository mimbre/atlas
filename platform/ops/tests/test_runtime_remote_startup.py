"""ATLAS_RUNTIME_REMOTE in core startup, with fake binaries only. Never runs a real Tailscale.

Every fake child (tailscaled, tailscale, apply-move.sh, verify.py, python3, the release and the
hold path's sleep) records its argv and which env names carry the synthetic token."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
TOKEN = 'synthetic-runtime-token-not-a-secret'

# Same local filesystem adapters as test_control_tls_startup.py (macOS protected utilities
# cannot see the materialized-folder mapping); used only in this fixture.
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

# The token value is read from the fixture folder, never from the env, so the probe itself
# cannot put it into a child's env.
RECORD = r'''
import json,os,sys
from pathlib import Path
def record(name):
    root=Path(os.environ['FIXTURE']); token=(root/'token').read_text(); args=sys.argv[1:]
    event={'name':name,'args':args,'pid':os.getpid(),
           'token_env':sorted(k for k,v in os.environ.items() if token in v or k.lower() in
                              ('atlas_runtime_backend_token','runtime_backend_token')),
           'token_value':os.environ.get('ATLAS_RUNTIME_BACKEND_TOKEN'),
           'token_argv':any(token in a for a in sys.argv)}
    with (root/'events').open('a') as f: f.write(json.dumps(event)+'\n')
'''

FAKE = RECORD + r'''
import socket,time
name=Path(sys.argv[0]).name; root=Path(os.environ['FIXTURE']); args=sys.argv[1:]
record(name)
if name=='tailscale':
    if 'status' in args:
        print(json.dumps({'BackendState':'Running'})); sys.exit(0)
    if 'serve' not in args: sys.exit(0)
if name in ('apply-move.sh','verify.py'): sys.exit(0)
if name=='atlas':
    if os.environ.get('ATLAS_CONTROL_TAILSCALE','0')=='0': sys.exit(0)
    s=socket.socket(socket.AF_INET6); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    s.bind(('::',int(os.environ['CONTROL_PORT']))); s.listen()
if name=='sleep' and args!=['infinity']:
    time.sleep(float(args[0])); sys.exit(0)
while True: time.sleep(.05)
'''

# python3 is recorded, then the real interpreter runs the same arguments (stdin is kept).
PYTHON = RECORD + r'''
record('python3')
os.execv(sys.executable,[sys.executable]+sys.argv[1:])
'''


class RuntimeRemoteStartupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        for folder in ['platform/ops', 'platform/atlas_facts/rela/scripts', 'release/bin', 'bin']:
            (self.base/folder).mkdir(parents=True, exist_ok=True)
        for name in ['core-run.sh', 'control-tailscale.sh']:
            (self.base/'platform/ops'/name).write_text((ROOT/'platform/ops'/name).read_text())
        for name in ['bin/tailscale', 'bin/tailscaled', 'release/bin/atlas',
                     'platform/ops/apply-move.sh', 'platform/atlas_facts/rela/scripts/verify.py']:
            self.script(name, FAKE)
        self.script('bin/python3', PYTHON)
        for name in ['mkdir', 'chmod', 'mktemp', 'rm']:
            self.script('bin/'+name, FILESYSTEM)
        (self.base/'token').write_text(TOKEN)
        with socket.socket(socket.AF_INET6) as sock:
            sock.bind(('::1', 0)); self.port = sock.getsockname()[1]
        settings = self.base/'settings.json'
        settings.write_text(json.dumps({'env': 'test', 'control': {'host': '::', 'port': self.port}}))
        self.env = dict(os.environ, PATH=str(self.base/'bin')+':'+os.environ['PATH'],
            FIXTURE=str(self.base), ATLAS_APP_DIR=str(self.base), ATLAS_ENV='test',
            ATLAS_ENV_FILE=str(settings), CONTROL_PORT=str(self.port),
            ATLAS_CONTROL_TAILSCALE='1', ATLAS_RUNTIME_REMOTE='1',
            ATLAS_RUNTIME_BACKEND_TOKEN=TOKEN,
            ATLAS_HOLD_FILE=str(self.base/'hold'),
            ATLAS_CONTROL_TS_STATE_DIR=str(self.base/'node'),
            ATLAS_CONTROL_TS_SOCKET_DIR=str(self.base/'sock'))
        self.env.pop('TS_AUTHKEY', None)
        self.process = None

    def script(self, name, body):
        path = self.base/name
        path.write_text('#!'+sys.executable+'\n'+body)
        path.chmod(0o755)

    def events(self):
        file = self.base/'events'
        return [json.loads(line) for line in file.read_text().splitlines()] if file.exists() else []

    def output(self):
        return (self.base/'output').read_text()

    def start(self):
        self.stop()  # a failed subTest must not leave its core holding the Control port
        (self.base/'events').unlink(missing_ok=True)
        out = (self.base/'output').open('w')
        self.addCleanup(out.close)
        self.process = subprocess.Popen(['bash', str(self.base/'platform/ops/core-run.sh')], env=self.env,
            stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
        self.addCleanup(self.stop)
        return self.process

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try: self.process.wait(timeout=6)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL); self.process.wait()

    def until(self, predicate):
        deadline = time.monotonic()+10
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.03)
        self.fail('startup fixture timed out: '+self.output())

    def serving(self):
        self.until(lambda: any('serve' in e['args'] for e in self.events()))

    def daemon(self):
        return next(e for e in self.events() if e['name'] == 'tailscaled')

    def today(self):
        # tailscaled argv before S3 (control-tailscale.sh), byte for byte.
        return ['--tun=userspace-networking', '--statedir='+str(self.base/'node'),
                '--socket='+str(self.base/'sock'/'tailscaled.sock')]

    def assert_token_only_for_release(self, release_gets_it):
        events = self.events()
        self.assertTrue(events)
        self.assertFalse([e for e in events if e['token_argv']], 'token on argv')
        for event in events:
            if event['name'] == 'atlas' and release_gets_it:
                self.assertEqual(event['token_env'], ['ATLAS_RUNTIME_BACKEND_TOKEN'])
                self.assertEqual(event['token_value'], TOKEN)
            else:
                self.assertEqual(event['token_env'], [], event['name'])
        self.assertNotIn(TOKEN, self.output())

    def test_remote_off_keeps_tailscaled_argv_and_gives_token_to_no_child(self):
        for value in [None, '0']:
            with self.subTest(ATLAS_RUNTIME_REMOTE=value):
                if value is None: self.env.pop('ATLAS_RUNTIME_REMOTE')
                else: self.env['ATLAS_RUNTIME_REMOTE'] = value
                self.start(); self.serving()
                self.assertEqual(self.daemon()['args'], self.today())
                self.assertTrue(any(e['name'] == 'atlas' for e in self.events()))
                self.stop(); self.assert_token_only_for_release(False)

    def test_remote_on_adds_only_a_localhost_http_proxy_and_token_reaches_only_the_release(self):
        self.start(); self.serving()
        args = self.daemon()['args']
        self.assertEqual(args, self.today()+['--outbound-http-proxy-listen=localhost:1055'])
        proxy = [a for a in args if 'proxy' in a or 'socks' in a]
        self.assertEqual(proxy, ['--outbound-http-proxy-listen=localhost:1055'])
        restrict = next(e for e in self.events() if e['name'] == 'tailscale' and 'set' in e['args'])
        self.assertEqual(restrict['args'][1:], ['set', '--accept-dns=false', '--accept-routes=false',
            '--ssh=false', '--advertise-routes=', '--advertise-tags=', '--advertise-exit-node=false'])
        names = {e['name'] for e in self.events()}
        self.assertTrue({'apply-move.sh', 'verify.py', 'python3', 'tailscaled', 'tailscale', 'atlas'} <= names)
        self.assertEqual(len([e for e in self.events() if e['name'] == 'atlas']), 1)
        self.stop(); self.assert_token_only_for_release(True)

    def test_remote_without_control_tailscale_fails_before_any_child(self):
        for value in [None, '0', '2']:
            with self.subTest(ATLAS_CONTROL_TAILSCALE=value):
                if value is None: self.env.pop('ATLAS_CONTROL_TAILSCALE', None)
                else: self.env['ATLAS_CONTROL_TAILSCALE'] = value
                self.assertNotEqual(self.start().wait(timeout=5), 0)
                self.assertEqual(self.events(), [])
                self.assertIn('ATLAS_RUNTIME_REMOTE=1 requires ATLAS_CONTROL_TAILSCALE=1', self.output())
                self.assertNotIn(TOKEN, self.output())

    def test_remote_without_backend_token_fails_before_any_child(self):
        for value in [None, '']:
            with self.subTest(ATLAS_RUNTIME_BACKEND_TOKEN=value):
                if value is None: self.env.pop('ATLAS_RUNTIME_BACKEND_TOKEN', None)
                else: self.env['ATLAS_RUNTIME_BACKEND_TOKEN'] = value
                try: rc = self.start().wait(timeout=5)
                except subprocess.TimeoutExpired: rc = None
                self.assertEqual([e['name'] for e in self.events()], [], 'children started')
                self.assertNotIn(rc, (None, 0))
                self.assertIn('ATLAS_RUNTIME_REMOTE=1 requires a non-empty ATLAS_RUNTIME_BACKEND_TOKEN',
                              self.output())

    def test_remote_off_needs_no_backend_token(self):
        self.env.pop('ATLAS_RUNTIME_BACKEND_TOKEN')
        self.env.update(ATLAS_CONTROL_TAILSCALE='0', ATLAS_RUNTIME_REMOTE='0')
        self.assertEqual(self.start().wait(timeout=5), 0)
        self.assertEqual([e['name'] for e in self.events()], ['apply-move.sh', 'python3', 'verify.py', 'atlas'])

    def test_remote_values_other_than_0_or_1_fail_before_any_child(self):
        for value in ['2', 'true', 'yes', '01', ' 1', '1 ', 'on']:
            with self.subTest(ATLAS_RUNTIME_REMOTE=value):
                self.env['ATLAS_RUNTIME_REMOTE'] = value
                self.assertNotEqual(self.start().wait(timeout=5), 0)
                self.assertEqual(self.events(), [])
                self.assertIn('ATLAS_RUNTIME_REMOTE must be 0 or 1', self.output())

    def test_hold_path_clears_the_token(self):
        (self.base/'hold').touch()
        self.script('bin/sleep', FAKE)
        self.start()
        self.until(lambda: any(e['name'] == 'sleep' for e in self.events()))
        self.assertEqual([e['name'] for e in self.events()], ['apply-move.sh', 'sleep'])
        self.assertEqual(self.events()[-1]['args'], ['infinity'])
        self.stop(); self.assert_token_only_for_release(False)

    def test_default_core_branch_clears_the_token(self):
        self.env.update(ATLAS_CONTROL_TAILSCALE='0', ATLAS_RUNTIME_REMOTE='0')
        self.assertEqual(self.start().wait(timeout=5), 0)
        self.assertEqual([e['name'] for e in self.events()], ['apply-move.sh', 'python3', 'verify.py', 'atlas'])
        self.assert_token_only_for_release(False)


if __name__ == '__main__': unittest.main()
