import json
import os
from pathlib import Path
import sys
import tempfile


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
