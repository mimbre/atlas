import json
from pathlib import Path
import uuid

from runtime.workspaces import client as workspace_client


def assistant_model_matches(configured, actual):
    # Native init retains the context-window option; assistant records use the base model ID.
    return isinstance(actual, str) and bool(actual) and (
        actual == configured or configured == actual + '[1m]')


def validate(scope, sandbox, session, model, expected_context):
    if scope is None and sandbox != 'read-only':
        raise ValueError('Claude requires read-only or dedicated-repository execution')
    if session:
        if str(uuid.UUID(session)) != session or model is None or not isinstance(expected_context, dict):
            raise ValueError('Claude resume requires a confirmed UUID, model and saved execution context')


def save_context(workspace, scope, folder, expected_context):
    actual = workspace_client.request('context', workspace)
    actual['permissions'] = scope
    if expected_context is not None and actual != expected_context:
        raise ValueError('Saved Claude working directory, repository identity or permission scope changed')
    (Path(folder) / 'claude-context.json').write_text(json.dumps(actual))


def build_command(executable, goal, scope, session, model, questions_enabled, question_session):
    model_arguments = ['--model', model] if model is not None else []
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
    return command, tools


class Protocol:
    def __init__(self, session, model, folder):
        self.session, self.model, self.folder = session, model, folder
        self.session_seen = False

    def event(self, event):
        if self.session:
            if event.get('type') == 'system' and event.get('subtype') == 'init':
                if event.get('session_id') != self.session or event.get('model') != self.model:
                    raise ValueError('Claude did not confirm the requested session and model')
                self.session_seen = True
            if event.get('type') == 'assistant':
                actual = event.get('message', {}).get('model')
                if actual and actual != '<synthetic>' and not assistant_model_matches(self.model, actual):
                    raise ValueError('Claude resumed with a different model')
        if event.get('type') == 'result' and isinstance(event.get('result'), str):
            (self.folder / 'answer.txt').write_text(event['result'])

    def complete(self, workspace, started_at, stopped):
        if self.session and not self.session_seen and not stopped:
            raise ValueError('Claude resume ended without confirming its session')
