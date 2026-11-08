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

    def event(self, event):
        if event.get('type') == 'thread.started':
            identifier = event.get('thread_id')
            if (not isinstance(identifier, str) or not identifier or
                    (self.session and identifier != self.session)):
                raise ValueError('Codex did not confirm the requested session')
            self.session_seen = True

    def complete(self, stopped):
        if self.session and not self.session_seen and not stopped:
            raise ValueError('Codex resume ended without confirming its session')
