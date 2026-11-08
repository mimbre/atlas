from datetime import datetime
import json
import os
from pathlib import Path
import re

from runtime.protocol import emit


def model(session, workspace, started_at):
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


def build_command(executable, workspace, folder, goal, permissions, session, configured_model):
    model_arguments = ['--model', configured_model] if configured_model is not None else []
    command = [executable, 'exec', *permissions, '--disable', 'hooks',
               '-c', 'forced_login_method="chatgpt"', '-c', 'approval_policy="never"',
               '--color', 'never', '--cd', workspace]
    if session:
        command.append('resume')
    command += [*model_arguments, '--json', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check',
                '--output-last-message', str(folder / 'answer.txt'), '--']
    command += [session, goal] if session else [goal]
    return command


class Protocol:
    def __init__(self, session):
        self.session = session
        self.session_seen = False
        self.native_session = None

    def event(self, event):
        if event.get('type') == 'thread.started':
            identifier = event.get('thread_id')
            if (not isinstance(identifier, str) or not identifier or
                    (self.session and identifier != self.session)):
                raise ValueError('Codex did not confirm the requested session')
            self.session_seen = True
            self.native_session = identifier

    def complete(self, workspace, started_at, stopped):
        if self.session and not self.session_seen and not stopped:
            raise ValueError('Codex resume ended without confirming its session')
        if self.native_session and not stopped:
            actual_model = model(self.native_session, workspace, started_at)
            if actual_model:
                emit({'type': 'runtime.identity', 'backend': 'codex', 'model': actual_model})
