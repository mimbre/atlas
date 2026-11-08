import json
import uuid

from runtime.protocol import emit
from runtime.providers.claude import assistant_model_matches


class QuestionProtocol:
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
                    not assistant_model_matches(self.model, message.get('model'))):
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
