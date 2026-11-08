"""Owned-process and workspace regressions through the actual Go host and workspace commands."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parent))
from workspace_test_support import setup_workspace_cli
import workspace_test_support as workspace_client


def setUpModule():
    setup_workspace_cli()


def codex_host(native, workspace, folder, goal, sandbox, session, model='null'):
    """Native's argv for Codex, which runs in the Go host built by setup_workspace_cli."""
    return [os.environ['ATLAS_RUNTIME_EXECUTABLE'], 'native-host', str(native), str(workspace),
            str(folder), goal, sandbox, session, 'null', 'null', 'codex', model, 'null', 'false']


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
        # Claude without questions runs in the Go host built by setup_workspace_cli.
        return subprocess.Popen(
            [os.environ['ATLAS_RUNTIME_EXECUTABLE'], 'native-host', str(self.native), str(self.repo),
             str(self.root), 'fixture lifecycle only', '', '', json.dumps(scope), 'null', 'claude',
             'null', 'null', 'false'],
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


class NativeModelTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='runtime-model-')
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()

    def launch(self, model, session=''):
        native = self.root / 'native'
        native.write_text(
            f'#!{sys.executable}\n'
            'import json, sys\nfrom pathlib import Path\n'
            f'Path({str(self.root / "argv.json")!r}).write_text(json.dumps(sys.argv[1:]))\n'
            'print(\'{"type":"turn.completed"}\', flush=True)\n')
        native.chmod(0o700)
        process = subprocess.Popen(
            codex_host(native, self.root, self.root, '--prompt stays one argument', 'read-only', session, model),
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
                code, events, error = self.launch(json.dumps(model))
                self.assertEqual(code, 1)
                self.assertIn('Model must be', error)
                self.assertEqual(events, [])
                self.assertFalse((self.root / 'argv.json').exists())


@unittest.skipUnless(os.name == 'posix', 'Runner process groups require POSIX')
class CleanupTest(unittest.TestCase):
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
                codex_host(native, folder, folder, 'bounded session mismatch', 'read-only', 'expected-session'),
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

    def test_untrusted_repository_and_branch_inputs_are_rejected(self):
        for url, branch in (
                ('file:///tmp/repo', 'task/new'), ('https://example.com/test/repo', 'task/new'),
                ('https://github.com/test/../repo', 'task/new'),
                (self.url, 'develop'), (self.url, '../branch'), (self.url, '--force')):
            with self.subTest(url=url, branch=branch), self.assertRaises(ValueError):
                workspace_client.request('request', str(self.root / 'runtime'), url, branch)


if __name__ == '__main__':
    unittest.main()
