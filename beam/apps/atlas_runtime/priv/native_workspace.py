"""Validate, own and prepare workspaces; the caller supplies the sandboxed Git command prefix."""
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess


def dedicated_scope(root):
    return {'profile': 'dedicated-repository', 'version': 1, 'root': str(root),
            'git_dir': str(root / '.git'), 'network_hosts': ['github.com', 'api.github.com']}


def repository_request(home, url, branch):
    match = re.fullmatch(r'https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9_.-]+)', url)
    if not match:
        raise ValueError('Repository must be an HTTPS github.com owner/repository URL')
    owner, name = (part.lower() for part in match.groups())
    name = name.removesuffix('.git')
    if name in ('', '.', '..'):
        raise ValueError('Invalid repository name')
    checked = subprocess.run(['git', 'check-ref-format', '--branch', branch],
                             capture_output=True, text=True)
    if checked.returncode or checked.stdout.strip() != branch or branch == 'develop':
        raise ValueError('Task branch must be a new explicit Git branch other than develop')
    root = Path(home).absolute() / 'repositories' / owner / name
    if root != root.resolve():
        raise ValueError('Managed repository path must not contain symlinks')
    return {'permissions': dedicated_scope(root),
            'repository': {'url': f'https://github.com/{owner}/{name}.git', 'branch': branch}}


def permission_scope(workspace):
    root = Path(workspace).absolute()
    if root != root.resolve() or not (root / '.git').is_dir() or (root / '.git').is_symlink():
        raise ValueError('Dedicated repository requires a canonical root with its own .git directory')
    git_dir = root / '.git'
    env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
    result = subprocess.run(
        ['git', '-C', str(root), 'rev-parse', '--path-format=absolute',
         '--show-toplevel', '--git-dir', '--git-common-dir'],
        env=env, capture_output=True, text=True, check=True)
    if result.stdout.splitlines() != [str(root), str(git_dir), str(git_dir)]:
        raise ValueError('Dedicated repository cannot use worktree or external Git metadata')
    if any((git_dir / path).exists() for path in
           ('commondir', 'objects/info/alternates', 'objects/info/http-alternates', 'worktrees')):
        raise ValueError('Dedicated repository cannot share Git metadata or object stores')
    for directory, dirs, files in os.walk(git_dir):
        for name in dirs + files:
            path = Path(directory) / name
            if path.is_symlink() or (path.is_file() and path.stat().st_nlink > 1):
                raise ValueError('Dedicated Git metadata cannot contain symlinks or shared hardlinks')
    # Project config can select legacy sandbox settings instead of the explicit profile.
    ignored_config = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex')).resolve() / 'config.toml'
    configs = [directory / '.codex/config.toml' for directory in (root, *root.parents)]
    configs.append(Path('/etc/codex/config.toml'))
    if any(path != ignored_config and path.exists() for path in configs):
        raise ValueError('Dedicated repository cannot load project or system Codex config')
    return dedicated_scope(root)


def lock_repository(workspace, create):
    root = Path(workspace)
    if root != root.resolve():
        raise ValueError('Repository path changed to a symlink')
    created = False
    if create:
        root.parent.mkdir(parents=True, exist_ok=True)
        try:
            root.mkdir()
            created = True
        except FileExistsError:
            pass
    if root != root.resolve():
        raise ValueError('Repository path changed to a symlink')
    lock = os.open(root, os.O_RDONLY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(lock)
        raise ValueError('Repository already has an active Runtime owner')
    return lock, created


def prepare_repository(scope, repository, created, command_prefix):
    root = Path(scope['root'])
    url, branch = repository['url'], repository['branch']
    expected = repository_request(root.parents[2], url, branch)
    if expected != {'permissions': scope, 'repository': {'url': url, 'branch': branch}}:
        raise ValueError('Managed repository request changed')
    marker = root / '.git/atlas-runtime-repository.json'
    identity = {'version': 1, 'url': url}

    def git(*args, check=True):
        result = subprocess.run(
            [*command_prefix, 'git', '-c', 'core.hooksPath=/dev/null',
             '-c', 'core.fsmonitor=false', '-c', 'maintenance.auto=false', '-c', 'gc.auto=0',
             '-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential', *args],
            capture_output=True, text=True, env=dict(os.environ, GIT_TERMINAL_PROMPT='0'))
        if check and result.returncode:
            raise ValueError(f'Git preparation failed: {result.stderr.strip()}')
        return result

    if created:
        git('clone', '--origin', 'origin', '--branch', 'develop', url, '.')
        permission_scope(str(root))
        marker.write_text(json.dumps(identity) + '\n')
    else:
        if not marker.is_file() or json.loads(marker.read_text()) != identity:
            raise ValueError('Refusing an unmanaged or mismatched repository')
        permission_scope(str(root))
        if git('remote', 'get-url', 'origin').stdout.strip() != url:
            raise ValueError('Managed repository origin does not match the request')
    if 'base_sha' in repository:
        if git('branch', '--show-current').stdout.strip() != branch:
            raise ValueError('Saved repository branch changed; continuation will not switch it')
        return repository
    if git('status', '--porcelain', '--untracked-files=all').stdout:
        raise ValueError('Managed repository has uncommitted work; nothing was reset or stashed')
    local = git('show-ref', '--verify', '--quiet', f'refs/heads/{branch}', check=False)
    if local.returncode != 1:
        raise ValueError('Task branch already exists or cannot be checked')
    git('fetch', '--no-tags', 'origin', '+refs/heads/*:refs/remotes/origin/*')
    remote = git('show-ref', '--verify', '--quiet', f'refs/remotes/origin/{branch}', check=False)
    if remote.returncode != 1:
        raise ValueError('Task branch already exists remotely or cannot be checked')
    base = git('rev-parse', '--verify', 'refs/remotes/origin/develop^{commit}').stdout.strip()
    git('checkout', '--no-overwrite-ignore', '--no-track', '-b', branch, base)
    return {**repository, 'base_sha': base}
