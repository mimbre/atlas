#!/usr/bin/env python3
"""Own a native CLI process group; parent EOF/stop interrupts it before this helper exits."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import select
import selectors
import signal
import shutil
import subprocess
import sys
import time
import tempfile
import uuid

import workspace_client


def emit(event):
    print(json.dumps(event), flush=True)


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


def permission_arguments(scope):
    root = Path(scope['root'])
    filesystem = {str(root): 'write', str(root / '.git'): 'write'}
    filesystem.update({str(root / name): 'read' for name in ('.agents', '.codex', '.aws')})
    paths = ','.join(f'{json.dumps(path)}={json.dumps(access)}' for path, access in filesystem.items())
    # One TOML table preserves quoted path keys; dotted CLI override keys do not.
    profile = ('permissions={atlas_repository={extends=":read-only",filesystem={' + paths +
               '},network={enabled=true,domains={"github.com"="allow","api.github.com"="allow"}}}}')
    return ['-c', 'default_permissions="atlas_repository"', '-c', profile,
            '-c', 'features.network_proxy=true']


def claude_repository_settings(scope, native_temporary):
    root = Path(scope['root'])
    temporary_roots = {Path(path).resolve() for path in
                       ('/tmp', '/var/tmp', tempfile.gettempdir())}
    if any(root == path or root.is_relative_to(path) for path in temporary_roots):
        raise ValueError('Claude dedicated repositories must be outside system temporary directories')
    # Claude 2.1.280 redirects longer child-temp paths to shared /tmp/claude-<uid>.
    if len(os.fsencode(Path(native_temporary) / f'claude-{os.getuid()}')) > 44:
        raise ValueError('Claude private native temp path exceeds the 44-byte child-temp limit')
    protected = [root / name for name in ('.agents', '.codex', '.aws', '.claude')]
    protected += [root / '.git/config', root / '.git/hooks']
    settings = {'sandbox': {
        'enabled': True, 'failIfUnavailable': True, 'allowUnsandboxedCommands': False,
        'excludedCommands': [],
        'filesystem': {'allowWrite': [str(root), str(native_temporary)],
                       'denyWrite': sorted(str(path) for path in temporary_roots) +
                                    [str(path) for path in protected]},
        'network': {'allowedDomains': scope['network_hosts'],
                    'allowAllUnixSockets': False, 'allowLocalBinding': False}}}
    if sys.platform == 'darwin':
        settings['sandbox']['network']['allowMachLookup'] = ['com.apple.trustd.agent']
    return settings


def claude_context(workspace, scope):
    root = Path(workspace).resolve()
    def git(*args):
        return subprocess.run(['git', '-C', str(root), *args],
                              capture_output=True, text=True)
    top = git('rev-parse', '--show-toplevel')
    identity = None
    if top.returncode == 0:
        branch = git('symbolic-ref', '--quiet', 'HEAD')
        if branch.returncode not in (0, 1):
            raise ValueError('Cannot inspect Claude repository branch')
        head = branch.stdout.strip() if branch.returncode == 0 else git('rev-parse', 'HEAD').stdout.strip()
        origin = git('config', '--get-all', 'remote.origin.url')
        if not head or origin.returncode not in (0, 1):
            raise ValueError('Cannot inspect Claude repository identity')
        identity = {'root': top.stdout.strip(), 'branch': head, 'origin': origin.stdout.splitlines()}
    elif top.returncode != 128 or any(os.path.lexists(path / '.git') for path in (root, *root.parents)):
        raise ValueError('Cannot inspect Claude working directory')
    return {'cwd': str(root), 'permissions': scope, 'git': identity}


def execute_assignment(workspace, scope, repository, created, backend, folder, expected_context, command):
    if repository is not None:
        executable = shutil.which('codex') if backend == 'claude' else command[0]
        if executable is None:
            raise ValueError('Managed repository preparation requires the installed Codex sandbox')
        command_prefix = [executable, 'sandbox', '-P', 'atlas_repository', '-C', workspace,
                          *permission_arguments(scope), '--']
        prepared = workspace_client.request('prepare', payload={
            'scope': scope, 'repository': repository, 'created': created,
            'command_prefix': command_prefix})
        emit({'type': 'runtime.repository_prepared', 'repository': prepared})
    if scope is not None and scope != workspace_client.request('scope', workspace):
        raise ValueError('Dedicated repository permission scope changed')
    if backend == 'claude':
        context = claude_context(workspace, scope)
        if expected_context is not None and context != expected_context:
            raise ValueError('Saved Claude working directory, repository identity or permission scope changed')
        (Path(folder) / 'claude-context.json').write_text(json.dumps(context))
    os.execv(command[0], command)


def codex_model(session, workspace, started_at):
    # Exec JSON omits model identity; only this invocation's native turn context is evidence.
    if not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', session):
        return None
    home = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex'))
    model = None
    try:
        for path in (home / 'sessions').glob(f'*/*/*/rollout-*-{session}.jsonl'):
            with path.open() as records:
                metadata = json.loads(next(records))
                if (metadata.get('type') != 'session_meta' or
                        metadata.get('payload', {}).get('id') != session):
                    continue
                for line in records:
                    record = json.loads(line)
                    if record.get('type') != 'turn_context':
                        continue
                    context = record.get('payload', {})
                    timestamp = datetime.fromisoformat(record.get('timestamp', '').replace('Z', '+00:00'))
                    if (timestamp.tzinfo is not None and timestamp >= started_at and
                            context.get('cwd') == workspace and
                            isinstance(context.get('model'), str) and context['model'] and
                            context['model'] != '<synthetic>'):
                        model = context['model']
    except (OSError, ValueError, TypeError, AttributeError, StopIteration):
        return None
    return model


def json_record(line, limit):
    if len(line) > limit:
        raise ValueError('Native protocol record exceeds its size limit')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate JSON key')
            result[key] = value
        return result
    value = json.loads(line, object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise ValueError('Native protocol record must be an object')
    return value


def write_native(stream, event):
    data = (json.dumps(event) + '\n').encode()
    if len(data) > 1048576:
        raise ValueError('Native input exceeds 1 MiB')
    remaining = memoryview(data)
    deadline = time.monotonic() + 3
    while remaining:
        timeout = deadline - time.monotonic()
        if timeout <= 0 or not select.select([], [stream], [], timeout)[1]:
            raise ValueError('Native input transport stalled')
        try:
            written = os.write(stream.fileno(), remaining)
        except BlockingIOError:
            continue
        except OSError as error:
            raise ValueError('Native input transport closed') from error
        if not written:
            raise ValueError('Native input transport closed')
        remaining = remaining[written:]
    stream.flush()


def claude_assistant_model_matches(configured, actual):
    # Native init retains the context-window option; assistant records use the base model ID.
    return isinstance(actual, str) and bool(actual) and (
        actual == configured or configured == actual + '[1m]')


class QuestionHost:
    """One owned native query; fixture tests do not establish provider behavior."""

    def __init__(self, session, goal, send, close, tools, native_pid, resume_model=None):
        self.session, self.goal = session, goal
        self.send, self.close, self.tools = send, close, set(tools)
        self.resume_model = resume_model
        self.native_pid = native_pid
        self.model = None
        self.initialize_id = 'initialize-' + uuid.uuid4().hex
        self.initialized = False
        self.candidate = self.pending = self.inflight = None
        self.last_tool = None
        self.finished = False

    def start(self):
        self.send({'type': 'control_request', 'request_id': self.initialize_id,
                   'request': {'subtype': 'initialize'}})

    @staticmethod
    def question_input(value):
        if (not isinstance(value, dict) or set(value) != {'questions'} or
                len(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()) > 32768):
            raise ValueError('Invalid native question input')
        questions = value['questions']
        if not isinstance(questions, list) or not 1 <= len(questions) <= 4:
            raise ValueError('Invalid native question count')
        seen = set()
        for question in questions:
            if (not isinstance(question, dict) or
                    set(question) != {'question', 'header', 'options', 'multiSelect'}):
                raise ValueError('Invalid native question fields')
            text = question['question']
            if (not isinstance(text, str) or not text.strip() or len(text.encode()) > 4096 or text in seen or
                    not isinstance(question['header'], str) or
                    not isinstance(question['multiSelect'], bool)):
                raise ValueError('Invalid native question')
            seen.add(text)
            options = question['options']
            if not isinstance(options, list) or not 2 <= len(options) <= 4:
                raise ValueError('Invalid native question options')
            for option in options:
                if (not isinstance(option, dict) or set(option) != {'label', 'description'} or
                        any(not isinstance(option[key], str) for key in option) or
                        not option['label'].strip()):
                    raise ValueError('Invalid native question option')
        return questions

    def reject_request(self, event, message, deny=False):
        identifier = event.get('request_id')
        if isinstance(identifier, str) and identifier and len(identifier) <= 256:
            response = {'subtype': 'success' if deny else 'error', 'request_id': identifier}
            if deny:
                response['response'] = {'behavior': 'deny', 'message': message}
            else:
                response['error'] = message
            self.send({'type': 'control_response', 'response': response})

    def event(self, event):
        kind = event.get('type')
        if self.finished:
            raise ValueError('Native event after terminal result')
        if 'session_id' in event and event['session_id'] != self.session:
            raise ValueError('Native question session changed')
        if event.get('parent_tool_use_id') is not None:
            raise ValueError('Subagent question transport is not supported')
        if kind == 'control_response':
            response = event.get('response')
            if (self.initialized or not isinstance(response, dict) or
                    response.get('request_id') != self.initialize_id or
                    response.get('subtype') != 'success' or
                    not isinstance(response.get('response'), dict) or
                    response['response'].get('current_permission_mode', 'default') not in ('default', 'manual')):
                raise ValueError('Unexpected native initialization response')
            self.initialized = True
            self.send({'type': 'user', 'session_id': self.session, 'parent_tool_use_id': None,
                       'message': {'role': 'user', 'content': self.goal}})
            return
        if kind == 'system' and event.get('subtype') == 'init':
            actual = event.get('model')
            tools = event.get('tools')
            if (not self.initialized or event.get('session_id') != self.session or
                    not isinstance(actual, str) or not actual or actual == '<synthetic>' or
                    (self.resume_model is not None and actual != self.resume_model) or
                    (self.model is not None and actual != self.model) or
                    event.get('permissionMode', 'default') not in ('default', 'manual') or
                    not isinstance(tools, list) or any(not isinstance(tool, str) for tool in tools) or
                    set(tools) != self.tools):
                raise ValueError('Native question initialization identity changed')
            self.model = actual
        elif kind == 'assistant':
            message = event.get('message')
            if (self.model is None or event.get('session_id') != self.session or
                    not isinstance(message, dict) or
                    not claude_assistant_model_matches(self.model, message.get('model'))):
                raise ValueError('Native question assistant identity changed')
            content = message.get('content')
            if not isinstance(content, list):
                raise ValueError('Invalid native assistant content')
            for block in content:
                if not isinstance(block, dict):
                    raise ValueError('Invalid native assistant block')
                if block.get('type') == 'tool_use' and block.get('name') == 'AskUserQuestion':
                    tool = block.get('id')
                    if (self.candidate or self.pending or self.inflight or
                            not isinstance(tool, str) or not tool or len(tool) > 256 or
                            tool == self.last_tool or
                            block.get('caller', {'type': 'direct'}) != {'type': 'direct'}):
                        raise ValueError('Ambiguous native question tool use')
                    self.question_input(block.get('input'))
                    self.candidate = {'tool': tool, 'input': block['input']}
        elif kind == 'control_request':
            request = event.get('request')
            if not isinstance(request, dict) or request.get('subtype') != 'can_use_tool':
                self.reject_request(event, 'Runtime does not permit native control changes')
                raise ValueError('Unsupported native control request')
            identifier = event.get('request_id')
            if (not isinstance(identifier, str) or not identifier or len(identifier) > 256 or
                    not isinstance(request.get('tool_name'), str) or not request['tool_name'] or
                    not isinstance(request.get('tool_use_id'), str) or not request['tool_use_id'] or
                    not isinstance(request.get('input'), dict)):
                self.reject_request(event, 'Runtime refused a malformed native request', deny=True)
                raise ValueError('Malformed native permission request')
            if request.get('tool_name') != 'AskUserQuestion':
                self.reject_request(event, 'Runtime does not approve non-question tools', deny=True)
                return
            try:
                if (set(request) - {'subtype', 'tool_name', 'display_name', 'input',
                                    'tool_use_id', 'requires_user_interaction'} or
                        request.get('requires_user_interaction') is not True or
                        self.model is None or self.pending or self.inflight or not self.candidate or
                        request.get('tool_use_id') != self.candidate['tool'] or
                        request.get('input') != self.candidate['input']):
                    raise ValueError('Uncorrelated native question request')
                questions = self.question_input(request.get('input'))
            except ValueError:
                self.reject_request(event, 'Runtime refused an invalid native question', deny=True)
                raise
            self.pending = {**self.candidate, 'request': identifier,
                            'id': 'question-' + uuid.uuid4().hex}
            self.candidate = None
            emit({'type': 'runtime.question',
                  'question': {'id': self.pending['id'], 'questions': questions,
                               'correlation': {'session_id': self.session, 'model': self.model,
                                               'tool_use_id': self.pending['tool'],
                                               'request_id': self.pending['request'],
                                               'native_pid': self.native_pid}}})
        elif kind == 'user':
            message = event.get('message')
            if not isinstance(message, dict) or not isinstance(message.get('content'), list):
                raise ValueError('Invalid native tool result')
            for block in message['content']:
                if not isinstance(block, dict):
                    raise ValueError('Invalid native tool result block')
                if (block.get('type') == 'tool_result' and self.inflight and
                        block.get('tool_use_id') == self.inflight['tool']):
                    if (event.get('session_id') != self.session or
                            block.get('is_error', False) is not False):
                        raise ValueError('Native question processing failed')
                    emit({'type': 'runtime.answer_processed', 'question_id': self.inflight['id']})
                    self.last_tool = self.inflight['tool']
                    self.inflight = None
        elif kind == 'control_cancel_request':
            raise ValueError('Native cancelled its pending control request')
        elif kind == 'result':
            self.close()
            self.finished = True
            if (self.model is None or event.get('session_id') != self.session or
                    self.candidate or self.pending or self.inflight):
                raise ValueError('Native result ended without processing its question')
        elif isinstance(kind, str) and kind.startswith('control_'):
            raise ValueError('Unsupported native control message')

    def answer(self, command):
        identifier, answers = command.get('question_id'), command.get('answers')
        if (set(command) != {'command', 'question_id', 'answers'} or
                command.get('command') != 'answer' or not isinstance(identifier, str) or
                not identifier or len(identifier) > 256):
            raise ValueError('Malformed Runtime answer command')
        if (self.finished or not self.pending or identifier != self.pending['id'] or
                not isinstance(answers, dict) or
                set(answers) != {q['question'] for q in self.pending['input']['questions']} or
                any(not isinstance(value, str) or not value.strip() or len(value.encode()) > 4096
                    for value in answers.values()) or
                len(json.dumps(answers, ensure_ascii=False, separators=(',', ':')).encode()) > 16384):
            emit({'type': 'runtime.answer_rejected', 'question_id': identifier,
                  'error': 'Answer does not match the pending native question'})
            return
        pending = self.pending
        self.send({'type': 'control_response', 'response': {
            'subtype': 'success', 'request_id': pending['request'],
            'response': {'behavior': 'allow', 'updatedInput': {
                **pending['input'], 'answers': answers}}}})
        self.inflight, self.pending = pending, None
        emit({'type': 'runtime.answer_delivered', 'question_id': identifier})

    def cancel(self):
        self.candidate = self.pending = self.inflight = None
        self.finished = True
        self.close()


def main():
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
    if backend == 'claude' and scope is None and sandbox != 'read-only':
        raise ValueError('Claude requires read-only or dedicated-repository execution')
    if backend == 'claude' and session:
        if str(uuid.UUID(session)) != session or model is None or not isinstance(expected_context, dict):
            raise ValueError('Claude resume requires a confirmed UUID, model and saved execution context')
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
    model_arguments = ['--model', model] if model is not None else []
    question_session = session or str(uuid.uuid4()) if questions_enabled else None
    if backend == 'claude':
        tools = 'Bash,Read,Glob,Grep' if scope is not None else 'Read,Glob,Grep'
        command = [executable, '--print', '--output-format', 'stream-json', '--verbose',
                   '--restricted', '--safe-mode', '--strict-mcp-config', '--no-chrome',
                   '--tools', tools + (',AskUserQuestion' if questions_enabled else ''),
                   '--allowedTools', tools]
        if questions_enabled:
            command += ['--input-format', 'stream-json', '--permission-mode', 'manual',
                        '--permission-prompts', 'host', '--permission-prompt-tool', 'stdio',
                        *(['--resume', session] if session else ['--session-id', question_session]),
                        *model_arguments]
        else:
            command += ['--permission-mode', 'dontAsk', '--permission-prompts', 'none',
                        *(['--resume', session] if session else []), *model_arguments, '--', goal]
    else:
        command = [executable, 'exec', *permissions, '--disable', 'hooks',
                   '-c', 'forced_login_method="chatgpt"', '-c', 'approval_policy="never"',
                   '--color', 'never', '--cd', workspace]
        if session:
            command.append('resume')
        command += [*model_arguments, '--json', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check',
                    '--output-last-message', str(folder / 'answer.txt'), '--']
        command += [session, goal] if session else [goal]
    session_seen = False
    native_session = None

    def forward(event):
        nonlocal session_seen, native_session
        nonlocal deadline
        if stopped:
            return
        if host is not None and event.get('type') != 'runtime.repository_prepared':
            host.event(event)
            if host.finished:
                deadline = time.monotonic() + 3
            if event.get('type') == 'control_response':
                return
        if backend == 'claude' and session:
            if event.get('type') == 'system' and event.get('subtype') == 'init':
                if event.get('session_id') != session or event.get('model') != model:
                    raise ValueError('Claude did not confirm the requested session and model')
                session_seen = True
            if event.get('type') == 'assistant':
                actual = event.get('message', {}).get('model')
                if actual and actual != '<synthetic>' and not claude_assistant_model_matches(model, actual):
                    raise ValueError('Claude resumed with a different model')
        if backend == 'claude' and event.get('type') == 'result' and isinstance(event.get('result'), str):
            (folder / 'answer.txt').write_text(event['result'])
        if event.get('type') == 'runtime.repository_prepared':
            emit(event)
            return
        if event.get('type') == 'thread.started':
            identifier = event.get('thread_id')
            if not isinstance(identifier, str) or not identifier or (session and identifier != session):
                raise ValueError('Codex did not confirm the requested session')
            session_seen = True
            if backend == 'codex':
                native_session = identifier
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
                command = [sys.executable, str(Path(__file__).resolve()), '--execute-assignment',
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
                host = QuestionHost(question_session, goal,
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
                    if session and not session_seen and not stopped:
                        raise ValueError(f'{backend.capitalize()} resume ended without confirming its session')
                    if backend == 'codex' and native_session and not stopped:
                        actual_model = codex_model(native_session, workspace, started_at)
                        if actual_model:
                            emit({'type': 'runtime.identity', 'backend': 'codex', 'model': actual_model})
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


if __name__ == '__main__':
    try:
        main()
    except BrokenPipeError:
        pass  # Parent disappeared; main's finally has already reaped the process.
    except Exception as error:
        print(f'Native runner: {error}', file=sys.stderr)
        sys.exit(1)
