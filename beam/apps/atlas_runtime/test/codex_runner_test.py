"""Owned-process cleanup regressions; injected permission errors are labelled."""
import errno
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


HELPER = Path(__file__).resolve().parents[1] / 'priv' / 'runtime' / 'entrypoint.py'
sys.path.insert(0, str(HELPER.parent.parent))
from runtime.host import assignment, process as process_host, sandbox
from runtime.providers import claude, codex
from runtime.workspaces import client as workspace_client
sys.path.insert(0, str(Path(__file__).resolve().parent))
from workspace_test_support import setup_workspace_cli


def setUpModule():
    setup_workspace_cli()


class ClaudeRepositoryLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='.runtime-claude-scope-', dir=Path.home())
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        self.scope = workspace_client.request('scope', str(self.repo))
        self.capture = self.root / 'owned-temp.txt'
        self.native = self.root / 'fixture-native'

    def launch(self, scope, hang=False, fail=False, home=None):
        self.native.write_text(
            f'#!{sys.executable}\n'
            'import json, os, sys, time\nfrom pathlib import Path\n'
            'temporary = Path(os.environ["CLAUDE_CODE_TMPDIR"])\n'
            f'Path({str(self.capture)!r}).write_text(json.dumps({{"path": str(temporary), '
            '"mode": temporary.stat().st_mode & 0o777, '
            '"settings": json.loads(sys.argv[sys.argv.index("--settings") + 1])}))\n'
            'print(\'{"type":"fixture.ready"}\', flush=True)\n' +
            ('time.sleep(30)\n' if hang else '') +
            ('sys.exit(7)\n' if fail else ''))
        self.native.chmod(0o700)
        return subprocess.Popen(
            [sys.executable, str(HELPER), str(self.native), str(self.repo), str(self.root),
             'fixture lifecycle only', '', '', json.dumps(scope), 'null', 'claude'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=dict(os.environ, HOME=str(home),
                     CODEX_HOME=os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
            if home is not None else None)

    def test_owned_private_temp_is_removed_after_completion_failure_and_stop(self):
        for stop, fail in ((False, False), (False, True), (True, False)):
            with self.subTest(stop=stop, fail=fail):
                process = self.launch(self.scope, hang=stop, fail=fail)
                try:
                    self.assertEqual(json.loads(process.stdout.readline())['type'], 'runtime.process_started')
                    self.assertEqual(json.loads(process.stdout.readline())['event']['type'], 'fixture.ready')
                    captured = json.loads(self.capture.read_text())
                    temporary = Path(captured['path'])
                    self.assertEqual(temporary.parent, Path.home().resolve())
                    self.assertEqual(captured['mode'], 0o700)
                    filesystem = captured['settings']['sandbox']['filesystem']
                    self.assertEqual(filesystem['allowWrite'], [str(self.repo), str(temporary)])
                    self.assertIn(str(Path('/tmp').resolve()), filesystem['denyWrite'])
                    self.assertIn(str(self.repo / '.git/config'), filesystem['denyWrite'])
                    evidence = json.loads((self.root / 'process.json').read_text())
                    self.assertEqual(evidence['native_temporary'], str(temporary))
                    if stop:
                        with self.assertRaisesRegex(ValueError, 'active Runtime owner'):
                            workspace_client.acquire(str(self.repo), False)
                        process.stdin.write('stop\n')
                        process.stdin.flush()
                    process.wait(timeout=5)
                    _, error = process.communicate()
                    self.assertEqual(process.returncode, 0, error)
                    self.assertFalse(temporary.exists())
                    released, _ = workspace_client.acquire(str(self.repo), False)
                    os.close(released)
                    subprocess.run(['git', '-C', str(self.repo), 'rev-parse', '--git-dir'],
                                   check=True, capture_output=True)
                finally:
                    if process.poll() is None:
                        process.stdin.close()
                        process.wait(timeout=5)
                    for stream in (process.stdin, process.stdout, process.stderr):
                        stream.close()

    def test_changed_scope_never_executes_native_cli(self):
        process = self.launch({**self.scope, 'network_hosts': ['example.com']})
        try:
            process.wait(timeout=5)
            _, error = process.communicate()
            self.assertNotEqual(process.returncode, 0)
            self.assertIn('permission scope changed', error)
            self.assertFalse(self.capture.exists())
        finally:
            if process.poll() is None:
                process.stdin.close()
                process.wait(timeout=5)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()

    def test_system_temp_repository_cannot_bypass_native_temp_denial(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'outside system temporary directories'):
                sandbox.claude_repository_settings(
                    workspace_client.request('dedicated-scope', Path(directory).resolve()), '/private-owned')

    def test_native_temp_byte_limit_fails_closed_before_fallback(self):
        suffix = len(os.fsencode(f'/claude-{os.getuid()}'))
        for extra in (0, 1):
            temporary = '/' + 'x' * (44 - suffix - 1 + extra)
            if extra:
                with self.assertRaisesRegex(ValueError, '44-byte'):
                    sandbox.claude_repository_settings(self.scope, temporary)
            else:
                sandbox.claude_repository_settings(self.scope, temporary)
        with self.assertRaisesRegex(ValueError, '44-byte'):
            sandbox.claude_repository_settings(self.scope, '/' + 'é' * 22)

    def test_trust_service_access_is_macos_only_and_exact(self):
        for platform in ('darwin', 'linux'):
            with self.subTest(platform=platform), patch.object(sandbox.sys, 'platform', platform):
                settings = sandbox.claude_repository_settings(self.scope, '/private-owned')
                network = settings['sandbox']['network']
                if platform == 'darwin':
                    self.assertEqual(network['allowMachLookup'], ['com.apple.trustd.agent'])
                else:
                    self.assertNotIn('allowMachLookup', network)

    def test_long_home_refuses_native_and_removes_created_temp(self):
        process = self.launch(self.scope, home=self.root)
        try:
            _, error = process.communicate(timeout=5)
            self.assertNotEqual(process.returncode, 0)
            self.assertIn('44-byte', error)
            self.assertFalse(self.capture.exists())
            self.assertEqual(list(self.root.glob('.ac-*')), [])
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_saved_claude_context_preserves_work_but_refuses_git_identity_drift(self):
        saved = claude.context(str(self.repo), self.scope)
        (self.repo / 'unfinished.txt').write_text('keep this work\n')
        self.assertEqual(claude.context(str(self.repo), self.scope), saved)
        for args in (
                ['symbolic-ref', 'HEAD', 'refs/heads/other'],
                ['remote', 'add', 'origin', 'https://github.com/other/repo.git']):
            subprocess.run(['git', '-C', str(self.repo), *args], check=True)
            with self.assertRaisesRegex(ValueError, 'repository identity'):
                assignment.execute_assignment(
                    str(self.repo), self.scope, None, False, 'claude',
                    str(self.root), saved, ['/must-not-execute'])
            subprocess.run(['git', '-C', str(self.repo), 'symbolic-ref', 'HEAD',
                            saved['git']['branch']], check=True)
        self.assertEqual((self.repo / 'unfinished.txt').read_text(), 'keep this work\n')

    def test_unreadable_git_identity_is_not_treated_as_a_non_repository(self):
        (self.repo / '.git/config').write_text('invalid git configuration\n')
        with self.assertRaisesRegex(ValueError, 'Cannot inspect Claude working directory'):
            claude.context(str(self.repo), None)


class NativeModelTest(unittest.TestCase):
    session = '01a1b578-c3b5-7972-9664-1d250bf64cdf'

    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='runtime-model-')
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()
        self.home = self.root / 'codex'
        self.artifact = (self.home / 'sessions/2026/11/07' /
                         f'rollout-2026-11-07T11-05-53-{self.session}.jsonl')
        self.artifact.parent.mkdir(parents=True)
        self.started = datetime(2026, 11, 7, 10, 5, 54, tzinfo=timezone.utc)
        self.environment = patch.dict(os.environ, CODEX_HOME=str(self.home))
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def records(self, *contexts, session=None):
        records = [{'type': 'session_meta', 'payload': {'id': session or self.session}}]
        records.extend({'type': 'turn_context', 'timestamp': timestamp,
                        'payload': {'cwd': cwd, 'model': model}}
                       for timestamp, cwd, model in contexts)
        self.artifact.write_text(''.join(json.dumps(record) + '\n' for record in records))

    def model(self):
        return codex.model(self.session, str(self.root), self.started)

    def test_native_turn_context_not_requested_model_confirms_identity(self):
        # Shape and model from native Codex 0.166.0 rollout, with fixture-only cwd.
        self.records(('2026-11-07T10:05:55.213Z', str(self.root), 'gpt-6.1-sol'))
        self.assertEqual(self.model(), 'gpt-6.1-sol')

    def test_resume_ignores_previous_turn_and_other_workspaces(self):
        self.records(
            ('2026-11-07T10:05:53.848Z', str(self.root), 'old-model'),
            ('2026-11-07T10:05:55.213Z', '/other', 'foreign-model'))
        self.assertIsNone(self.model())
        self.records(
            ('2026-11-07T10:05:53.848Z', str(self.root), 'old-model'),
            ('2026-11-07T10:05:55.213Z', str(self.root), 'native-current'))
        self.assertEqual(self.model(), 'native-current')

    def test_missing_unconfirmed_and_malformed_artifacts_leave_identity_unknown(self):
        self.assertIsNone(self.model())
        self.records(('2026-11-07T10:05:55.213Z', str(self.root), 'model'),
                     session='different-session')
        self.assertIsNone(self.model())
        for timestamp, model in [('bad-date', 'model'), ('2026-11-07T10:05:55', 'model'),
                                 ('2026-11-07T10:05:55Z', None),
                                 ('2026-11-07T10:05:55Z', '<synthetic>')]:
            self.records((timestamp, str(self.root), model))
            self.assertIsNone(self.model())
        self.artifact.write_text('{truncated')
        self.assertIsNone(self.model())
        self.assertIsNone(codex.model('../../*', str(self.root), self.started))

    def launch(self, extra, session='', artifact=False):
        native = self.root / 'native'
        native.write_text(
            f'#!{sys.executable}\n'
            'import json, sys\nfrom pathlib import Path\n'
            'from datetime import datetime, timezone\n'
            f'Path({str(self.root / "argv.json")!r}).write_text(json.dumps(sys.argv[1:]))\n' +
            (f'with Path({str(self.artifact)!r}).open("a") as output:\n'
             '    output.write(json.dumps({"type": "turn_context", '
             '"timestamp": datetime.now(timezone.utc).isoformat(), '
             f'"payload": {{"cwd": {str(self.root)!r}, "model": "native-confirmed"}}}}) + "\\n")\n'
             if artifact else '') +
            f'print(json.dumps({{"type": "thread.started", "thread_id": {self.session!r}}}), flush=True)\n'
            'print(\'{"type":"turn.completed"}\', flush=True)\n')
        native.chmod(0o700)
        process = subprocess.Popen(
            [sys.executable, str(HELPER), str(native), str(self.root), str(self.root),
             '--prompt stays one argument', 'read-only', session, *extra],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            process.wait(timeout=5)  # Keep control stdin open; EOF would cancel the turn.
            output, error = process.communicate()
            return process.returncode, [json.loads(line) for line in output.splitlines()], error
        finally:
            if process.poll() is None:
                process.stdin.close()
                process.wait(timeout=5)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()

    def test_invalid_models_never_launch_native_process(self):
        for model in ('', '--dangerously-skip-permissions', 'opus --tools Bash', 'opus\nx',
                      'opus;touch /tmp/injected', 'x' * 201, 1, ['opus']):
            with self.subTest(model=model):
                code, events, error = self.launch(['null', 'null', 'codex', json.dumps(model)])
                self.assertEqual(code, 1)
                self.assertIn('Model must be', error)
                self.assertEqual(events, [])
                self.assertFalse((self.root / 'argv.json').exists())

    def test_current_native_artifact_emits_identity_before_process_end_on_resume(self):
        self.records(('2026-11-07T10:05:53.848Z', str(self.root), 'stale-model'))
        code, events, error = self.launch(
            ['null', 'null', 'codex', '"requested-model"'], self.session, artifact=True)
        self.assertEqual(code, 0, error)
        self.assertEqual(events[-2],
                         {'type': 'runtime.identity', 'backend': 'codex', 'model': 'native-confirmed'})
        self.assertEqual(events[-1]['type'], 'runtime.process_ended')


@unittest.skipUnless(os.name == 'posix', 'Runner process groups require POSIX')
class CleanupTest(unittest.TestCase):
    def wait_zombie(self, pid):
        # Do not poll/wait the Popen here: the regression requires an unreaped leader.
        for _ in range(200):
            state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='],
                                   capture_output=True, text=True, check=False).stdout.strip()
            if state.startswith('Z'):
                return
            time.sleep(.01)
        self.fail(f'Owned leader {pid} did not become a zombie')

    def assert_dead(self, pid):
        for _ in range(200):
            state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='],
                                   capture_output=True, text=True, check=False).stdout.strip()
            if not state or state.startswith('Z'):
                return
            time.sleep(.01)
        self.fail(f'Owned descendant {pid} is still running')

    def test_signalling_unreaped_exited_leader_does_not_mask_failure(self):
        process = subprocess.Popen(['/bin/sh', '-c', 'exit 0'], start_new_session=True)
        try:
            self.wait_zombie(process.pid)
            process_host.signal_group(process, signal.SIGKILL)
            self.assertEqual(process.wait(timeout=5), 0)
            self.assert_dead(process.pid)
        finally:
            process.wait(timeout=5)

    def test_exited_leader_does_not_exempt_live_descendants_from_cleanup(self):
        process = subprocess.Popen(
            ['/bin/sh', '-c', 'sleep 60 </dev/null >/dev/null 2>&1 & echo $!'],
            stdout=subprocess.PIPE, text=True, start_new_session=True)
        try:
            child = int(process.stdout.readline())
            self.wait_zombie(process.pid)
            process_host.signal_group(process, signal.SIGKILL)
            self.assertEqual(process.wait(timeout=5), 0)
            self.assert_dead(child)
        finally:
            # Reap the leader before final cleanup so a failing regression cannot
            # itself leave an unreaped child or a sleeping owned descendant.
            process.wait(timeout=5)
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.stdout.close()

    def test_denied_signal_to_live_leader_fails_within_bound(self):
        # The child outlives the cleanup bound but self-expires if waiting regresses.
        # Never try to cause a real EPERM by signalling a foreign process.
        process = subprocess.Popen(['/bin/sleep', '10'], start_new_session=True)
        try:
            started = time.monotonic()
            with patch.object(process_host.os, 'killpg',
                              side_effect=PermissionError(errno.EPERM, 'injected denial')):
                with self.assertRaises(PermissionError):
                    process_host.signal_group(process, signal.SIGKILL)
            self.assertLess(time.monotonic() - started, 6)
            self.assertIsNone(process.poll(), 'Permission failure must not claim the leader exited')
        finally:
            process.kill()
            process.wait(timeout=5)

    def test_persistent_denial_after_reaping_is_not_cleanup_success(self):
        process = subprocess.Popen(['/bin/sh', '-c', 'exit 0'], start_new_session=True)
        try:
            self.wait_zombie(process.pid)
            # Keep denying even after wait() reaps the owned leader. ESRCH is
            # harmless, but this second EPERM must remain a visible failure.
            with patch.object(process_host.os, 'killpg',
                              side_effect=PermissionError(errno.EPERM, 'injected denial')):
                with self.assertRaises(PermissionError):
                    process_host.signal_group(process, signal.SIGKILL)
            self.assertEqual(process.returncode, 0, 'Owned leader must still be reaped')
            self.assert_dead(process.pid)
        finally:
            process.wait(timeout=5)

    def test_runner_reports_original_native_session_failure(self):
        with tempfile.TemporaryDirectory(prefix='runtime-cleanup-') as folder:
            root = Path(folder)
            native = root / 'native'
            native.write_text(
                '#!/bin/sh\n'
                'printf \'%s\\n\' \'{"type":"thread.started","thread_id":"wrong-session"}\'\n'
                'printf \'%s\\n\' \'{"type":"turn.completed"}\'\n')
            native.chmod(0o700)
            process = subprocess.Popen(
                [sys.executable, str(HELPER), str(native), folder, folder,
                 'bounded session mismatch', 'read-only', 'expected-session'],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True)
            try:
                # Keep control stdin open until failure; communicate() first would
                # request cancellation and test a different lifecycle transition.
                process.wait(timeout=5)
                output, error = process.communicate()
                self.assertEqual(process.returncode, 1)
                self.assertIn('Codex did not confirm the requested session', error)
                self.assertNotIn('Operation not permitted', error)
                self.assertNotIn('runtime.process_ended', output)
            finally:
                if process.poll() is None:
                    process.stdin.close()
                    process.wait(timeout=5)
                for stream in (process.stdin, process.stdout, process.stderr):
                    stream.close()


class DedicatedRepositoryTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='runtime-repository-')
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()
        self.repo = self.root / 'repo'
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), '-c', 'user.name=Test',
                        '-c', 'user.email=test@example.invalid', 'commit',
                        '--allow-empty', '-qm', 'initial'], check=True)

    def test_only_independent_canonical_repository_root_is_accepted(self):
        scope = workspace_client.request('scope', str(self.repo))
        self.assertEqual(scope['root'], str(self.repo))
        self.assertEqual(scope['git_dir'], str(self.repo / '.git'))
        alias = self.root / 'alias'
        alias.symlink_to(self.repo, target_is_directory=True)
        child = self.repo / 'child'
        child.mkdir()
        worktree = self.root / 'worktree'
        subprocess.run(['git', '-C', str(self.repo), 'worktree', 'add', '-q',
                        '-b', 'other', str(worktree)], check=True)
        for path in (alias, child, worktree, self.repo):
            with self.subTest(path=path), self.assertRaises(ValueError):
                workspace_client.request('scope', str(path))

    def test_external_and_shared_metadata_are_rejected(self):
        metadata = self.repo / '.git'
        alternate = metadata / 'objects/info/alternates'
        alternate.write_text(str(self.root / 'objects') + '\n')
        with self.assertRaises(ValueError):
            workspace_client.request('scope', str(self.repo))
        alternate.unlink()
        linked = metadata / 'linked'
        linked.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            workspace_client.request('scope', str(self.repo))
        linked.unlink()
        os.link(metadata / 'HEAD', self.root / 'shared-head')
        with self.assertRaises(ValueError):
            workspace_client.request('scope', str(self.repo))

    def test_project_config_cannot_override_permission_profile(self):
        for directory in (self.repo, self.root):
            config = directory / '.codex'
            config.mkdir()
            (config / 'config.toml').write_text('sandbox_mode = "read-only"\n')
            with self.assertRaises(ValueError):
                workspace_client.request('scope', str(self.repo))
            (config / 'config.toml').unlink()
            config.rmdir()


class ProvisioningTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='runtime-provision-')
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()
        self.source = self.root / 'source'
        self.url = 'https://github.com/test/fixture.git'
        self.git(self.root, 'init', '-q', '-b', 'develop', str(self.source))
        (self.source / 'state.txt').write_text('base\n')
        self.git(self.source, 'add', 'state.txt')
        self.git(self.source, 'commit', '-qm', 'base')
        # Local Git transport bridge: real clone/fetch/checkout, not native sandbox proof.
        self.bridge = self.root / 'local-git'
        self.bridge.write_text(
            f'#!{sys.executable}\nimport os, sys\n'
            "args = sys.argv[sys.argv.index('--') + 1:]\n"
            "os.chdir(sys.argv[sys.argv.index('-C') + 1])\n"
            "if 'clone' in args or 'fetch' in args:\n"
            f"    args[1:1] = ['-c', 'url.{self.source.as_uri()}.insteadOf={self.url}']\n"
            "os.execvp(args[0], args)\n")
        self.bridge.chmod(0o700)
        self.request = workspace_client.request('request', str(self.root / 'runtime'), self.url, 'task/first')
        self.repo = Path(self.request['permissions']['root'])
        self.repo.mkdir(parents=True)
        self.command_prefix = [str(self.bridge), '-C', str(self.repo), '--']
        workspace_client.request('prepare', payload={
            'scope': self.request['permissions'], 'repository': self.request['repository'],
            'created': True, 'command_prefix': self.command_prefix})

    def git(self, cwd, *args):
        return subprocess.check_output(
            ['git', '-C', str(cwd), '-c', 'user.name=Test',
             '-c', 'user.email=test@example.invalid', *args], text=True).strip()

    def prepare(self, branch):
        request = workspace_client.request('request', str(self.root / 'runtime'), self.url, branch)
        return workspace_client.request('prepare', payload={
            'scope': request['permissions'], 'repository': request['repository'],
            'created': False, 'command_prefix': self.command_prefix})

    def test_reuse_uses_fresh_develop_and_preserves_prior_task_commit(self):
        self.git(self.repo, 'commit', '--allow-empty', '-qm', 'task change')
        previous = self.git(self.repo, 'rev-parse', 'HEAD')
        self.git(self.source, 'commit', '--allow-empty', '-qm', 'new develop')
        latest = self.git(self.source, 'rev-parse', 'HEAD')
        prepared = self.prepare('task/second')
        self.assertEqual(prepared['base_sha'], latest)
        self.assertEqual(self.git(self.repo, 'rev-parse', 'HEAD'), latest)
        self.assertEqual(self.git(self.repo, 'branch', '--show-current'), 'task/second')
        self.assertEqual(self.git(self.repo, 'rev-parse', 'task/first'), previous)

    def test_continuation_preserves_work_and_refuses_branch_drift(self):
        head = self.git(self.repo, 'rev-parse', 'HEAD')
        saved = {**self.request['repository'], 'base_sha': head}
        (self.repo / 'unfinished.txt').write_text('keep working\n')
        self.git(self.source, 'commit', '--allow-empty', '-qm', 'new remote base')
        workspace_client.request('prepare', payload={
            'scope': self.request['permissions'], 'repository': saved,
            'created': False, 'command_prefix': self.command_prefix})
        self.assertEqual(self.git(self.repo, 'rev-parse', 'HEAD'), head)
        self.git(self.repo, 'checkout', '-qb', 'different-task')
        with self.assertRaises(ValueError):
            workspace_client.request('prepare', payload={
                'scope': self.request['permissions'], 'repository': saved,
                'created': False, 'command_prefix': self.command_prefix})
        self.assertEqual(self.git(self.repo, 'branch', '--show-current'), 'different-task')
        self.assertEqual((self.repo / 'unfinished.txt').read_text(), 'keep working\n')

    def test_dirty_and_existing_branches_are_preserved(self):
        head = self.git(self.repo, 'rev-parse', 'HEAD')
        for name in ('state.txt', 'untracked.txt'):
            path = self.repo / name
            original = path.read_bytes() if path.exists() else None
            path.write_text('keep my work\n')
            with self.assertRaises(ValueError):
                self.prepare('task/second')
            self.assertEqual(path.read_text(), 'keep my work\n')
            self.assertEqual(self.git(self.repo, 'rev-parse', 'HEAD'), head)
            if original is None:
                path.unlink()
            else:
                path.write_bytes(original)
        with self.assertRaises(ValueError):
            self.prepare('task/first')
        self.git(self.source, 'branch', 'task/remote')
        with self.assertRaises(ValueError):
            self.prepare('task/remote')
        self.assertEqual(self.git(self.repo, 'branch', '--show-current'), 'task/first')
        self.assertEqual(self.git(self.repo, 'rev-parse', 'HEAD'), head)

    def test_mismatched_and_unmanaged_paths_are_preserved(self):
        self.git(self.repo, 'remote', 'set-url', 'origin', 'https://github.com/other/repo.git')
        with self.assertRaises(ValueError):
            self.prepare('task/second')
        self.assertEqual(self.git(self.repo, 'remote', 'get-url', 'origin'),
                         'https://github.com/other/repo.git')
        marker = self.repo / '.git/atlas-runtime-repository.json'
        marker.unlink()
        with self.assertRaises(ValueError):
            self.prepare('task/second')
        self.assertEqual((self.repo / 'state.txt').read_text(), 'base\n')

    def test_active_owner_blocks_reacquisition_until_release(self):
        lock = os.open(self.repo, os.O_RDONLY)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(ValueError):
                workspace_client.acquire(str(self.repo), False)
        finally:
            os.close(lock)
        acquired, created = workspace_client.acquire(str(self.repo), False)
        try:
            self.assertFalse(created)
            with self.assertRaisesRegex(ValueError, 'active Runtime owner'):
                workspace_client.acquire(str(self.repo), False)
        finally:
            os.close(acquired)
        released, created = workspace_client.acquire(str(self.repo), False)
        os.close(released)

    def test_claude_provisioning_without_codex_sandbox_preserves_repository(self):
        head = self.git(self.repo, 'rev-parse', 'HEAD')
        with patch.object(assignment.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(ValueError, 'installed Codex sandbox'):
                assignment.execute_assignment(
                    str(self.repo), self.request['permissions'], self.request['repository'],
                    False, 'claude', str(self.root), None, ['/missing-claude'])
        self.assertEqual(self.git(self.repo, 'rev-parse', 'HEAD'), head)
        self.assertEqual(self.git(self.repo, 'branch', '--show-current'), 'task/first')

    def test_untrusted_repository_and_branch_inputs_are_rejected(self):
        for url, branch in (
                ('file:///tmp/repo', 'task/new'), ('https://example.com/test/repo', 'task/new'),
                ('https://github.com/test/../repo', 'task/new'),
                (self.url, 'develop'), (self.url, '../branch'), (self.url, '--force')):
            with self.subTest(url=url, branch=branch), self.assertRaises(ValueError):
                workspace_client.request('request', str(self.root / 'runtime'), url, branch)


if __name__ == '__main__':
    unittest.main()
