import os
import shutil

from runtime.protocol import emit
from runtime.host.sandbox import permission_arguments
from runtime.providers import claude
from runtime.workspaces import client as workspace_client


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
        claude.save_context(workspace, scope, folder, expected_context)
    os.execv(command[0], command)
