from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import selectors
import signal
import shutil
import subprocess
import sys
import time
import tempfile
import uuid

from runtime.host.assignment import execute_assignment
from runtime.protocol import emit, json_record, write_native
from runtime.host.sandbox import claude_repository_settings, permission_arguments
from runtime.providers import claude, codex
from runtime.providers.claude_questions import QuestionProtocol
from runtime.workspaces import client as workspace_client


def signal_group(process, sig):
    try:
        try:
            os.killpg(process.pid, sig)
        except PermissionError as error:
            # macOS can deny a group signal while its last member is exiting,
            # even before poll() can reap it. Bound the wait for our own leader,
            # then still signal any surviving descendants in the same group.
            # A live leader or a second denial remains a real permission error.
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                raise error
            os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass


def main(entrypoint):
    if len(sys.argv) > 9 and sys.argv[1] == '--execute-assignment':
        execute_assignment(sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4]),
                           json.loads(sys.argv[5]), sys.argv[6], sys.argv[7],
                           json.loads(sys.argv[8]), sys.argv[9:])
        return
    executable, workspace, folder, goal, sandbox, session, *extra = sys.argv[1:]
    scope = json.loads(extra[0]) if extra else None
    repository = json.loads(extra[1]) if len(extra) >= 2 else None
    backend = extra[2] if len(extra) >= 3 else 'codex'
    model = json.loads(extra[3]) if len(extra) >= 4 else None
    expected_context = json.loads(extra[4]) if len(extra) >= 5 else None
    questions_enabled = json.loads(extra[5]) if len(extra) >= 6 else False
    if type(questions_enabled) is not bool or (questions_enabled and backend != 'claude'):
        raise ValueError('Questions require a boolean opt-in and the Claude backend')
    if model is not None and (not isinstance(model, str) or
                              not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:/\[\]-]{0,199}', model)):
        raise ValueError('Model must be a nonempty identifier of at most 200 characters')
    if backend not in ('codex', 'claude'):
        raise ValueError('Backend must be codex or claude')
    if backend == 'claude':
        claude.validate(scope, sandbox, session, model, expected_context)
    if len(extra) > 6 or (scope is None and sandbox not in ('read-only', 'workspace-write')):
        raise ValueError('Sandbox must be read-only or workspace-write')
    if repository is not None and (scope != workspace_client.request('dedicated-scope', workspace) or
                                   bool(session) != ('base_sha' in repository)):
        raise ValueError('Managed repository context does not match this start or continuation')
    if scope is not None:
        if sandbox:
            raise ValueError('Dedicated repository permissions conflict with sandbox')
        permissions = permission_arguments(scope)
    else:
        permissions = ['--sandbox', sandbox]
    folder = Path(folder)
    question_session = session or str(uuid.uuid4()) if questions_enabled else None
    if backend == 'claude':
        command, tools = claude.build_command(
            executable, goal, scope, session, model, questions_enabled, question_session)
        protocol = claude.Protocol(session, model, folder)
    else:
        command = codex.build_command(executable, workspace, folder, goal, permissions, session, model)
        protocol = codex.Protocol(session)

    def forward(event):
        nonlocal deadline
        if stopped:
            return
        if host is not None and event.get('type') != 'runtime.repository_prepared':
            host.event(event)
            if host.finished:
                deadline = time.monotonic() + 3
            if event.get('type') == 'control_response':
                return
        protocol.event(event)
        if event.get('type') == 'runtime.repository_prepared':
            emit(event)
            return
        emit({'type': 'runtime.event', 'event': event})

    process = None
    group_killed = False
    host = None
    lock = None
    created = False
    native_temporary = None
    environment = None
    selector = selectors.DefaultSelector()
    stopped = False
    deadline = None
    partial = b''
    control_partial = b''
    stdout_open = True
    try:
        with (folder / 'stderr.log').open('wb') as errors, (folder / 'stream.jsonl').open('wb') as output:
            if scope is not None or (Path(workspace) / '.git/atlas-runtime-repository.json').exists():
                try:
                    lock, created = workspace_client.acquire(workspace, repository is not None and not session)
                except Exception as error:
                    errors.write(str(error).encode())
                    raise
                if backend == 'claude' and scope is not None:
                    if repository is None and scope != workspace_client.request('scope', workspace):
                        raise ValueError('Dedicated repository permission scope changed')
                    native_temporary = tempfile.mkdtemp(prefix='.ac-', dir=Path.home().resolve())
                    command[1:1] = ['--settings', json.dumps(
                        claude_repository_settings(scope, native_temporary))]
                    environment = dict(os.environ, CLAUDE_CODE_TMPDIR=native_temporary)
            if scope is not None or backend == 'claude':
                command = [sys.executable, str(entrypoint), '--execute-assignment',
                           workspace, json.dumps(scope), json.dumps(repository), json.dumps(created),
                           backend, str(folder), json.dumps(expected_context), *command]
            started_at = datetime.now(timezone.utc)
            process = subprocess.Popen(command, stdin=subprocess.PIPE if questions_enabled else subprocess.DEVNULL,
                                       stdout=subprocess.PIPE,
                                       stderr=errors, start_new_session=True,
                                       cwd=workspace if backend == 'claude' else None, env=environment)
            (folder / 'process.json').write_text(json.dumps({
                'pid': process.pid, 'command': command, 'native_temporary': native_temporary}))
            emit({'type': 'runtime.process_started', 'pid': process.pid})
            selector.register(sys.stdin, selectors.EVENT_READ, 'control')
            selector.register(process.stdout, selectors.EVENT_READ, 'output')
            if questions_enabled:
                os.set_blocking(process.stdin.fileno(), False)
                host = QuestionProtocol(question_session, goal,
                                    lambda event: write_native(process.stdin, event),
                                    process.stdin.close, tools.split(',') + ['AskUserQuestion'],
                                    process.pid, model if session else None)
                host.start()
            while True:
                for key, _ in selector.select(.1):
                    if key.data == 'control':
                        data = os.read(sys.stdin.fileno(), 4096)
                        should_stop = not questions_enabled or not data
                        if not should_stop:
                            control_partial += data
                            while b'\n' in control_partial:
                                line, control_partial = control_partial.split(b'\n', 1)
                                if line == b'stop':
                                    should_stop = True
                                    break
                                command = json_record(line, 32768)
                                host.answer(command)
                            if len(control_partial) > 32768:
                                raise ValueError('Runtime control record exceeds 32 KiB')
                        if should_stop:
                            selector.unregister(sys.stdin)
                            stopped = True
                            if host is not None:
                                host.cancel()
                            deadline = time.monotonic() + 3
                            signal_group(process, signal.SIGINT)
                    else:
                        data = os.read(process.stdout.fileno(), 65536)
                        if not data:
                            selector.unregister(process.stdout)
                            stdout_open = False
                        else:
                            output.write(data)
                            output.flush()
                            partial += data
                            while b'\n' in partial:
                                line, partial = partial.split(b'\n', 1)
                                # Keep protocol records separate from helper diagnostics.
                                event = json_record(line, 1048576)
                                forward(event)
                            if len(partial) > 1048576:
                                raise ValueError('Native event exceeds 1 MiB')
                if deadline is not None and time.monotonic() >= deadline:
                    signal_group(process, signal.SIGKILL)
                    group_killed = True
                    deadline = None
                if not stdout_open:
                    if partial.strip():
                        forward(json_record(partial, 1048576))
                        partial = b''
                    if host is not None and not host.finished and not stopped:
                        raise ValueError('Native question transport ended before its result')
                    # EOF can precede the leader's exit; do not turn a clean exit into SIGKILL.
                    try:
                        code = process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        if not group_killed:
                            signal_group(process, signal.SIGKILL)
                            group_killed = True
                        code = process.wait()
                    protocol.complete(workspace, started_at, stopped)
                    emit({'type': 'runtime.process_ended', 'exit_code': code, 'stopped': stopped})
                    return
    finally:
        selector.close()
        if host is not None:
            host.cancel()
        if process is not None:
            # Signal every descendant once; a second kill can hit orphan zombies on macOS.
            if not group_killed:
                signal_group(process, signal.SIGKILL)
            process.wait()
        if native_temporary is not None:
            try:
                shutil.rmtree(native_temporary)
            except FileNotFoundError:
                pass
        # Keep ownership until the complete process group has been reaped, including on stop.
        if lock is not None:
            os.close(lock)
