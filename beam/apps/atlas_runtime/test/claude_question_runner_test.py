"""Deterministic host/owned-process fixtures, not live-provider or model-consumption proof."""
import copy
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest


HELPER = Path(__file__).resolve().parents[1] / 'priv' / 'native_runner.py'
sys.path.insert(0, str(HELPER.parent))
import workspace_client
sys.path.insert(0, str(Path(__file__).resolve().parent))
from workspace_test_support import setup_workspace_cli
spec = importlib.util.spec_from_file_location('question_native_runner', HELPER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
SESSION = '15113671-40b9-4677-8b2b-c6c1180db993'
MODEL = 'fixture-model'
TOOLS = ['Read', 'Glob', 'Grep', 'AskUserQuestion']
QUESTION = {'question': 'Which value?', 'header': 'Value', 'multiSelect': False,
            'options': [{'label': '11', 'description': 'First'},
                        {'label': '23', 'description': 'Second'}]}


def setUpModule():
    setup_workspace_cli()


def assistant(session=SESSION, tool='tool-1'):
    return {'type': 'assistant', 'session_id': session, 'parent_tool_use_id': None,
            'message': {'model': MODEL, 'content': [
                {'type': 'tool_use', 'id': tool, 'name': 'AskUserQuestion',
                 'caller': {'type': 'direct'}, 'input': {'questions': [copy.deepcopy(QUESTION)]}}]}}


def request(tool='tool-1', identifier='request-1'):
    return {'type': 'control_request', 'request_id': identifier,
            'request': {'subtype': 'can_use_tool', 'tool_name': 'AskUserQuestion',
                        'tool_use_id': tool, 'requires_user_interaction': True,
                        'input': {'questions': [copy.deepcopy(QUESTION)]}}}


def processed(session=SESSION, tool='tool-1'):
    return {'type': 'user', 'session_id': session, 'parent_tool_use_id': None,
            'message': {'role': 'user', 'content': [
                {'type': 'tool_result', 'tool_use_id': tool, 'content': 'fixture processed'}]}}


class QuestionHostTest(unittest.TestCase):
    def setUp(self):
        self.sent = []
        self.closed = False
        self.output = io.StringIO()
        self.redirect = redirect_stdout(self.output)
        self.redirect.__enter__()
        self.addCleanup(self.redirect.__exit__, None, None, None)
        self.host = runner.QuestionHost(SESSION, 'one assignment', self.sent.append,
                                        self.close, TOOLS, native_pid=7319)
        self.host.start()
        self.host.event({'type': 'control_response', 'response': {
            'subtype': 'success', 'request_id': self.host.initialize_id, 'response': {}}})
        self.host.event({'type': 'system', 'subtype': 'init', 'session_id': SESSION,
                         'model': MODEL, 'tools': TOOLS})

    def close(self):
        self.closed = True

    def pending(self):
        self.host.event(assistant())
        self.host.event(request())
        return self.host.pending['id']

    def answer(self, identifier, answers=None):
        self.host.answer({'command': 'answer', 'question_id': identifier,
                          'answers': {'Which value?': '436849'} if answers is None else answers})

    def events(self):
        return [json.loads(line) for line in self.output.getvalue().splitlines()]

    def test_delivery_is_not_processing_and_duplicate_never_resends(self):
        identifier = self.pending()
        self.answer(identifier)
        response = self.sent[-1]['response']
        self.assertEqual(response, {'subtype': 'success', 'request_id': 'request-1',
                                    'response': {'behavior': 'allow', 'updatedInput': {
                                        'questions': [QUESTION], 'answers': {'Which value?': '436849'}}}})
        self.assertIsNone(self.host.pending)
        self.assertEqual(self.events()[-1]['type'], 'runtime.answer_delivered')
        count = len(self.sent)
        self.answer(identifier)
        self.assertEqual(len(self.sent), count)
        self.assertEqual(self.events()[-1]['type'], 'runtime.answer_rejected')
        self.host.event(processed())
        self.assertEqual(self.events()[-1]['type'], 'runtime.answer_processed')
        self.host.event({'type': 'result', 'session_id': SESSION, 'result': 'fixture done'})
        self.assertTrue(self.closed)
        self.answer(identifier)
        self.assertEqual(self.events()[-1]['type'], 'runtime.answer_rejected')
        self.assertEqual(sum(event['type'] == 'user' for event in self.sent), 1)

    def test_sequential_questions_keep_exact_source_correlation(self):
        previous = None
        for index in (1, 2):
            tool, identifier = f'tool-{index}', f'request-{index}'
            source = assistant(tool=tool)
            control = request(tool, identifier)
            self.host.event(source)
            self.host.event(control)
            question = self.events()[-1]['question']
            self.assertEqual(question['questions'], control['request']['input']['questions'])
            self.assertEqual(question['correlation'], {
                'session_id': source['session_id'], 'model': source['message']['model'],
                'tool_use_id': source['message']['content'][0]['id'],
                'request_id': control['request_id'], 'native_pid': 7319})
            self.assertEqual(question['correlation']['tool_use_id'], control['request']['tool_use_id'])
            if previous is not None:
                self.assertNotEqual(question['id'], previous['id'])
                count = len(self.sent)
                self.answer(previous['id'])
                self.assertEqual(len(self.sent), count)
                self.assertEqual(self.host.pending['id'], question['id'])
            self.answer(question['id'])
            self.assertEqual(self.sent[-1]['response']['request_id'], identifier)
            self.host.event(processed(tool=tool))
            previous = question

    def test_wrong_answers_leave_exact_pending_question(self):
        identifier = self.pending()
        invalid = [{}, {'other': 'yes'}, {'Which value?': None}, {'Which value?': 1},
                   {'Which value?': ''}, {'Which value?': ' \t'}, {'Which value?': 'é' * 2049},
                   {'Which value?': 'yes', 'updatedPermissions': []}]
        for answers in invalid:
            with self.subTest(answers=repr(answers)[:100]):
                count = len(self.sent)
                self.answer(identifier, answers)
                self.assertEqual(len(self.sent), count)
                self.assertEqual(self.host.pending['id'], identifier)
                self.assertEqual(self.events()[-1]['type'], 'runtime.answer_rejected')
        self.answer('question-wrong')
        self.assertEqual(self.host.pending['id'], identifier)
        self.answer(identifier, {'Which value?': 'é' * 2048})
        self.assertIsNone(self.host.pending)

    def test_answer_object_size_limit_includes_question_keys(self):
        questions = [dict(QUESTION, question=str(index) + 'q' * 4095) for index in range(4)]
        message = assistant()
        message['message']['content'][0]['input']['questions'] = questions
        control = request()
        control['request']['input']['questions'] = questions
        self.host.event(message)
        self.host.event(control)
        self.answer(self.host.pending['id'], {q['question']: 'answer' for q in questions})
        self.assertEqual(self.events()[-1]['type'], 'runtime.answer_rejected')

    def test_wrong_native_identity_and_permission_suggestions_fail_closed(self):
        self.host.event(assistant())
        variants = []
        wrong_tool = request('wrong-tool')
        variants.append(wrong_tool)
        wrong_input = request()
        wrong_input['request']['input']['questions'][0]['question'] = 'Changed?'
        variants.append(wrong_input)
        suggestions = request()
        suggestions['request']['permission_suggestions'] = [{'type': 'setMode', 'mode': 'bypassPermissions'}]
        variants.append(suggestions)
        wrong_session = request()
        wrong_session['session_id'] = 'foreign'
        variants.append(wrong_session)
        subagent = request()
        subagent['parent_tool_use_id'] = 'subagent'
        variants.append(subagent)
        for event in variants:
            with self.subTest(event=event), self.assertRaises(ValueError):
                self.host.event(event)
        self.assertIsNone(self.host.pending)
        drift = assistant()
        drift['message']['model'] = 'different-model'
        with self.assertRaisesRegex(ValueError, 'identity'):
            self.host.event(drift)

    def test_initialization_is_correlated_and_single_assignment(self):
        for response in ({'subtype': 'success', 'request_id': 'foreign'},
                         {'subtype': 'error', 'request_id': self.host.initialize_id}):
            with self.assertRaises(ValueError):
                self.host.event({'type': 'control_response', 'response': response})
        self.assertEqual(sum(event['type'] == 'user' for event in self.sent), 1)
        with self.assertRaises(ValueError):
            self.host.event({'type': 'system', 'subtype': 'init', 'session_id': SESSION,
                             'model': MODEL, 'tools': TOOLS + ['Write']})
        with self.assertRaises(ValueError):
            self.host.event({'type': 'system', 'subtype': 'init', 'session_id': SESSION,
                             'model': MODEL, 'tools': TOOLS, 'permissionMode': 'bypassPermissions'})

    def test_resume_model_must_match_native_init(self):
        host = runner.QuestionHost(SESSION, 'assignment', self.sent.append, self.close,
                                   TOOLS, native_pid=7319, resume_model='saved-model')
        host.event({'type': 'control_response', 'response': {
            'subtype': 'success', 'request_id': host.initialize_id, 'response': {}}})
        with self.assertRaisesRegex(ValueError, 'identity'):
            host.event({'type': 'system', 'subtype': 'init', 'session_id': SESSION,
                        'model': MODEL, 'tools': TOOLS})

    def test_context_modifier_keeps_exact_init_and_accepts_only_same_assistant_model(self):
        configured = 'claude-opus-5-5[1m]'
        for resume_model in (None, configured):
            host = runner.QuestionHost(SESSION, 'assignment', self.sent.append, self.close,
                                       TOOLS, native_pid=7319, resume_model=resume_model)
            host.event({'type': 'control_response', 'response': {
                'subtype': 'success', 'request_id': host.initialize_id, 'response': {}}})
            host.event({'type': 'system', 'subtype': 'init', 'session_id': SESSION,
                        'model': configured, 'tools': TOOLS})
            with self.assertRaisesRegex(ValueError, 'identity'):
                host.event({'type': 'system', 'subtype': 'init', 'session_id': SESSION,
                            'model': 'claude-opus-5-5', 'tools': TOOLS})
            for changed in ('claude-opus-5', 'claude-sonnet-5-5', 'claude-opus-5-5[2m]'):
                event = assistant()
                event['message']['model'] = changed
                with self.assertRaisesRegex(ValueError, 'identity'):
                    host.event(event)
            event = assistant()
            event['message']['model'] = 'claude-opus-5-5'
            host.event(event)
            host.event(request())
            identifier = host.pending['id']
            host.answer({'command': 'answer', 'question_id': identifier,
                         'answers': {'Which value?': '436849'}})
            host.event(processed())
            self.assertEqual(host.model, configured)
            self.assertEqual(self.events()[-1],
                             {'type': 'runtime.answer_processed', 'question_id': identifier})

    def test_non_question_denied_and_mode_updates_refused(self):
        for tool in ('Bash', 'Read', 'Write', 'Edit'):
            event = request()
            event['request']['tool_name'] = tool
            self.host.event(event)
            self.assertEqual(self.sent[-1]['response']['response']['behavior'], 'deny')
        for subtype in ('set_permission_mode', 'mcp_set_servers', 'unknown'):
            with self.subTest(subtype=subtype), self.assertRaises(ValueError):
                self.host.event({'type': 'control_request', 'request_id': 'mode',
                                 'request': {'subtype': subtype, 'mode': 'bypassPermissions'}})
            self.assertEqual(self.sent[-1]['response']['subtype'], 'error')

    def test_bounded_native_questions_reject_duplicates_and_invalid_options(self):
        variants = [{'questions': []}, {'questions': [QUESTION] * 5},
                    {'questions': [QUESTION, QUESTION]},
                    {'questions': [dict(QUESTION, question='é' * 2049)]},
                    {'questions': [dict(QUESTION, options=QUESTION['options'][:1])]},
                    {'questions': [dict(QUESTION, header='x' * 32768)]},
                    {'questions': [QUESTION], 'answers': {}},
                    {'questions': [dict(QUESTION, multiSelect=1)]}]
        for value in variants:
            with self.subTest(value=repr(value)[:100]), self.assertRaises(ValueError):
                runner.QuestionHost.question_input(value)

    def test_cancel_clears_state_and_rejects_late_answer(self):
        identifier = self.pending()
        self.host.cancel()
        self.answer(identifier)
        self.assertTrue(self.closed)
        self.assertIsNone(self.host.pending)
        self.assertIsNone(self.host.inflight)
        self.assertEqual(self.events()[-1]['type'], 'runtime.answer_rejected')

    def test_result_without_processing_and_wrong_session_do_not_claim_processed(self):
        identifier = self.pending()
        self.answer(identifier)
        with self.assertRaises(ValueError):
            self.host.event(processed(session='foreign'))
        error = processed()
        error['message']['content'][0]['is_error'] = True
        with self.assertRaises(ValueError):
            self.host.event(error)
        with self.assertRaises(ValueError):
            self.host.event({'type': 'result', 'session_id': SESSION, 'result': 'too early'})
        self.assertTrue(self.closed)
        self.assertNotIn('runtime.answer_processed', [event['type'] for event in self.events()])

    def test_unrelated_parallel_result_preserves_inflight_question(self):
        identifier = self.pending()
        self.answer(identifier)
        inflight = self.host.inflight
        unrelated = processed(tool='parallel-read')
        unrelated['message']['content'][0]['is_error'] = True
        self.host.event(unrelated)
        self.assertIs(self.host.inflight, inflight)
        self.assertNotIn('runtime.answer_processed', [event['type'] for event in self.events()])
        with self.assertRaisesRegex(ValueError, 'session changed'):
            self.host.event(processed(session='foreign', tool='parallel-read'))
        self.host.event(processed())
        self.assertIsNone(self.host.inflight)
        self.assertEqual(self.events()[-1],
                         {'type': 'runtime.answer_processed', 'question_id': identifier})

    def test_complete_oversized_records_and_duplicate_keys_are_rejected(self):
        for record in (b'{"x":"' + b'a' * 32768 + b'"}\n',
                       b'{"command":"answer","command":"stop"}', b'[]'):
            with self.assertRaises(ValueError):
                runner.json_record(record, 32768)


def fixture_native():
    """Actual subprocess protocol peer; assertions describe fixtures, never provider proof."""
    mode = os.environ['ATLAS_QUESTION_FIXTURE']
    args = sys.argv
    assert args[args.index('--permission-mode') + 1] == 'manual'
    assert args[args.index('--permission-prompts') + 1] == 'host'
    assert args[args.index('--permission-prompt-tool') + 1] == 'stdio'
    assert args[args.index('--input-format') + 1] == 'stream-json'
    assert all(flag in args for flag in ('--restricted', '--safe-mode', '--strict-mcp-config'))
    tools = args[args.index('--tools') + 1].split(',')
    assert 'AskUserQuestion' in tools
    assert 'AskUserQuestion' not in args[args.index('--allowedTools') + 1].split(',')
    session = args[args.index('--session-id') + 1]
    initial = json.loads(sys.stdin.readline())
    assert initial['request'] == {'subtype': 'initialize'}
    runner.emit({'type': 'control_response', 'response': {
        'subtype': 'success', 'request_id': initial['request_id'], 'response': {}}})
    assignment = json.loads(sys.stdin.readline())
    assert assignment == {'type': 'user', 'session_id': session, 'parent_tool_use_id': None,
                          'message': {'role': 'user', 'content': 'fixture assignment'}}
    runner.emit({'type': 'system', 'subtype': 'init', 'session_id': session,
                 'model': MODEL, 'tools': tools})
    # Descendant ignores SIGINT; runner must reap the complete owned process group.
    descendant = subprocess.Popen([sys.executable, '-c',
                                   'import signal,time;signal.signal(signal.SIGINT,signal.SIG_IGN);time.sleep(30)'],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
    Path(os.environ['ATLAS_QUESTION_CHILD']).write_text(str(descendant.pid))
    source, control = assistant(session), request()
    Path(os.environ['ATLAS_QUESTION_SOURCE']).write_text(json.dumps({
        'assistant': source, 'control_request': control, 'native_pid': os.getpid()}))
    runner.emit(source)
    runner.emit(control)
    if mode == 'output-loss':
        os.close(sys.stdout.fileno())
        time.sleep(30)
        return
    if mode == 'malformed-output':
        print('{broken', flush=True)
        time.sleep(30)
        return
    if mode == 'oversized-output':
        print(json.dumps({'payload': 'x' * 1048576}), flush=True)
        time.sleep(30)
        return
    if mode == 'native-cancel':
        runner.emit({'type': 'control_cancel_request', 'request_id': 'request-1'})
        time.sleep(30)
        return
    if mode == 'input-loss':
        os.close(sys.stdin.fileno())
        runner.emit({'type': 'fixture.input_closed'})
        time.sleep(30)
        return
    response = sys.stdin.readline()
    if not response or mode == 'pending':
        return
    response = json.loads(response)
    assert response == {'type': 'control_response', 'response': {
        'subtype': 'success', 'request_id': 'request-1', 'response': {
            'behavior': 'allow', 'updatedInput': {'questions': [QUESTION],
                                                'answers': {'Which value?': '436849'}}}}}
    if mode != 'early-result':
        runner.emit(processed(session))
    runner.emit({'type': 'result', 'session_id': session, 'result': 'fixture completed'})
    assert sys.stdin.read() == ''  # No successor assignment after this query's terminal result.
    if mode == 'result-hang':
        time.sleep(30)


class QuestionProcessTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='.question-fixture-', dir=Path.home())
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()
        self.workspace = self.root / 'workspace'
        self.workspace.mkdir()
        self.native = self.root / 'fixture-native'
        self.native.write_text(f'#!{sys.executable}\nimport runpy\n'
                               f'runpy.run_path({str(Path(__file__).resolve())!r}, run_name="question_fixture")\n')
        self.native.chmod(0o700)
        self.buffer = b''
        self.events = []
        self.process = None
        self.addCleanup(self.cleanup_process)

    def cleanup_process(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.stdin.close()
                self.process.wait(timeout=8)
            for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                stream.close()

    def launch(self, mode='success', scoped=False, enabled='true', backend='claude'):
        self.cleanup_process()
        self.buffer = b''
        self.events = []
        scope = None
        if scoped:
            subprocess.run(['git', 'init', '-q', str(self.workspace)], check=True)
            scope = workspace_client.request('scope', str(self.workspace))
        self.process = subprocess.Popen(
            [sys.executable, str(HELPER), str(self.native), str(self.workspace), str(self.root),
             'fixture assignment', '' if scoped else 'read-only', '', json.dumps(scope),
             'null', backend, 'null', 'null', enabled], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=dict(os.environ, ATLAS_QUESTION_FIXTURE=mode,
                     ATLAS_QUESTION_CHILD=str(self.root / 'child.pid'),
                     ATLAS_QUESTION_SOURCE=str(self.root / 'question-source.json')))

    def next_event(self, wanted):
        deadline = time.monotonic() + 8
        while True:
            if b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                event = json.loads(line)
                self.events.append(event)
                if event['type'] == wanted or (event['type'] == 'runtime.event' and
                                               event['event']['type'] == wanted):
                    return event
                continue
            timeout = deadline - time.monotonic()
            self.assertGreater(timeout, 0, f'Timed out awaiting {wanted}: {self.events}')
            self.assertTrue(select.select([self.process.stdout], [], [], timeout)[0])
            data = os.read(self.process.stdout.fileno(), 65536)
            self.assertTrue(data, f'EOF awaiting {wanted}: {self.events}')
            self.buffer += data

    def send(self, identifier):
        self.process.stdin.write((json.dumps({'command': 'answer', 'question_id': identifier,
                                             'answers': {'Which value?': '436849'}}) + '\n').encode())
        self.process.stdin.flush()

    def ended(self, success):
        self.process.wait(timeout=8)
        remaining = self.buffer + self.process.stdout.read()
        self.events.extend(json.loads(line) for line in remaining.splitlines())
        self.buffer = b''
        error = self.process.stderr.read().decode()
        self.assertEqual(self.process.returncode == 0, success, error)
        evidence = json.loads((self.root / 'process.json').read_text())
        deadline = time.monotonic() + 3
        while True:
            try:
                os.killpg(evidence['pid'], 0)
            except ProcessLookupError:
                break
            self.assertLess(time.monotonic(), deadline, 'Owned native process group survived')
            time.sleep(.02)
        if evidence['native_temporary']:
            self.assertFalse(Path(evidence['native_temporary']).exists())
        return error

    def test_read_only_and_write_scoped_query_delivery_processing_and_cleanup(self):
        previous = None
        for scoped in (False, True):
            with self.subTest(scoped=scoped):
                self.launch(scoped=scoped)
                event = self.next_event('runtime.question')
                self.assertEqual(event['question']['questions'], [QUESTION])
                identifier = event['question']['id']
                self.assertRegex(identifier, '^question-[0-9a-f]{32}$')
                source = json.loads((self.root / 'question-source.json').read_text())
                message, control = source['assistant'], source['control_request']
                correlation = event['question']['correlation']
                self.assertEqual(correlation, {
                    'session_id': message['session_id'], 'model': message['message']['model'],
                    'tool_use_id': message['message']['content'][0]['id'],
                    'request_id': control['request_id'], 'native_pid': source['native_pid']})
                self.assertEqual(correlation['tool_use_id'], control['request']['tool_use_id'])
                self.assertEqual(event['question']['questions'], control['request']['input']['questions'])
                self.assertNotEqual(correlation['native_pid'], self.process.pid)
                if previous is not None:
                    self.assertNotEqual(identifier, previous['id'])
                    self.assertNotEqual(correlation['session_id'], previous['correlation']['session_id'])
                    self.assertNotEqual(correlation['native_pid'], previous['correlation']['native_pid'])
                previous = event['question']
                self.send(identifier)
                delivered = self.next_event('runtime.answer_delivered')
                self.assertEqual(delivered['question_id'], identifier)
                processed_event = self.next_event('runtime.answer_processed')
                self.assertEqual(processed_event['question_id'], identifier)
                self.ended(True)
                self.assertEqual((self.root / 'answer.txt').read_text(), 'fixture completed')
                self.cleanup_process()
                self.process = None
                self.events = []

    def test_terminal_input_eof_deadline_kills_group_once(self):
        self.launch('result-hang')
        identifier = self.next_event('runtime.question')['question']['id']
        self.send(identifier)
        self.next_event('runtime.answer_processed')
        self.ended(True)
        self.assertEqual(self.events[-1]['type'], 'runtime.process_ended')
        self.assertEqual(self.events[-1]['exit_code'], -signal.SIGKILL)

    def test_stop_and_parent_eof_cancel_pending_owned_group(self):
        for control in (b'stop\n', None):
            with self.subTest(control=control):
                self.launch('pending')
                self.next_event('runtime.question')
                if control is None:
                    self.process.stdin.close()
                else:
                    self.process.stdin.write(control)
                    self.process.stdin.flush()
                self.ended(True)
                self.assertTrue(self.events[-1]['stopped'])
                self.assertNotIn('runtime.answer_delivered', [event['type'] for event in self.events])
                self.cleanup_process()
                self.process = None
                self.events = []

    def test_malformed_unknown_and_duplicate_key_control_cancel_group(self):
        for control in (b'{broken\n', b'{"command":"set_permission_mode"}\n',
                        b'{"command":"answer","command":"stop"}\n',
                        b'{"command":"answer","question_id":"id","answers":{},"updatedPermissions":[]}\n'):
            with self.subTest(control=control):
                self.launch('pending')
                self.next_event('runtime.question')
                self.process.stdin.write(control)
                self.process.stdin.flush()
                self.ended(False)
                self.cleanup_process()
                self.process = None
                self.events = []

    def test_transport_loss_cancel_and_early_result_never_claim_processing(self):
        for mode in ('output-loss', 'input-loss', 'malformed-output', 'oversized-output',
                     'native-cancel', 'early-result'):
            with self.subTest(mode=mode):
                self.launch(mode)
                identifier = self.next_event('runtime.question')['question']['id']
                if mode == 'input-loss':
                    self.next_event('fixture.input_closed')
                if mode in ('input-loss', 'early-result'):
                    self.send(identifier)
                self.ended(False)
                self.assertNotIn('runtime.answer_processed', [event['type'] for event in self.events])
                if mode == 'input-loss':
                    self.assertNotIn('runtime.answer_delivered', [event['type'] for event in self.events])
                self.cleanup_process()
                self.process = None
                self.events = []

    def test_opt_in_must_be_boolean_and_claude_only(self):
        for enabled, backend in (('1', 'claude'), ('"true"', 'claude'), ('true', 'codex')):
            with self.subTest(enabled=enabled, backend=backend):
                self.launch(enabled=enabled, backend=backend)
                self.process.wait(timeout=5)
                self.assertNotEqual(self.process.returncode, 0)
                self.assertFalse((self.root / 'process.json').exists())
                self.cleanup_process()
                self.process = None


if __name__ == 'question_fixture':
    fixture_native()
elif __name__ == '__main__':
    unittest.main()
