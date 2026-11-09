#!/usr/bin/env python3
"""Reviewed, one-off CI route around the existing quiescent Fly backup helper.
Plaintext remains private to the runner and existing Fly volumes; only proof.json
is suitable for an Actions artifact. This is release recovery, not offsite DR.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
ECC = 'ecc28f387a3f528e6c225e4c6fdc0b09a60d5d3f'
MASTER = 'dcf7785513e0776a30987a3cba7a3801d0a15da5'
RELEASE_REF = 'refs/heads/release/ecc28f3-20261106'
APPS = {'eyra-atlas': 'beam', 'eyra-atlas-rela': 'rela'}
# Authenticated successful master CI41913896681/job126879062084.
IMAGES = {'eyra-atlas': 'sha256:9ef23e5766009be43bc98982165b51d2a6efca711055063d2cd7cde2fc254661',
          'eyra-atlas-rela': 'sha256:13e51c2c08dc43396ead0a3e342d3398910a5f9340850b4cdaeafca5f95a38b8'}
TOKENS = {'beam': 'ATLAS_FLY_TOKEN_CORE', 'rela': 'ATLAS_FLY_TOKEN_RELA'}


class Refused(Exception):
    pass


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def invoke(args, env=None, label='command'):
    result = subprocess.run(args, env=env, capture_output=True)
    if result.returncode:
        # Never print captured server/CLI output, config, records or credentials.
        raise Refused(f'{label} failed (exit {result.returncode})')
    return result.stdout.decode()


def raw_fly(args):
    allowed = args[:1] == ['status'] or args[:2] in [['machine', 'restart'], ['ssh', 'console']] or args[:3] in [['ssh', 'sftp', 'get'], ['ssh', 'sftp', 'put']]
    if not allowed:
        raise Refused('unsupported Fly operation; no deploy/resource/secret changes')
    try:
        positions = [n for n, value in enumerate(args) if value == '-a']
        if len(positions) != 1:
            raise Refused('ambiguous Fly app')
        app = args[positions[0] + 1]
        name = APPS[app]
        token = os.environ[TOKENS[name]]
        binary = os.environ['ATLAS_BACKUP_FLY']
        if not token or not os.path.isabs(binary):
            raise Refused('missing existing scoped credential/CLI')
    except (IndexError, KeyError):
        raise Refused('unknown app or unavailable existing credential') from None
    env = dict(os.environ, FLY_API_TOKEN=token)
    return invoke([binary, *args], env, label='Fly ' + ' '.join(args))


# This journal is private to the serialized CI job and its helper subprocesses.
# It records intent BEFORE a remote mutation; the remote owner marker resolves
# interrupted acquisition/removal without inferring ownership from hold existence.
CONTEXT = None


def context_path():
    value = os.environ.get('ATLAS_BACKUP_CONTEXT')
    return Path(value) if value else CONTEXT


def save_context(path, value):
    temporary = path.with_suffix('.next')
    write_json(temporary, value)
    temporary.replace(path)


def bound_remote(app, machine, command):
    return raw_fly(['ssh', 'console', '-q', '-a', app, '--machine', machine,
                    '-C', command]).replace('\r', '')


def pending_absent(pair=None):
    for app, name in APPS.items():
        command = f'test ! -e /data/incoming/{name}.tar.gz'
        if pair:
            bound_remote(app, pair[app]['machine'], command)
        else:
            remote(app, command)


def fence(context):
    # Recheck the entire pair at each I/O barrier, including exceptional release.
    # SSH/SFTP below also target the recorded ID, never Fly's dynamic selection.
    for app, expected in context['pair'].items():
        machines = json.loads(raw_fly(['status', '-a', app, '--json'])).get('Machines', [])
        if len(machines) != 1 or machines[0]['id'] != expected['machine'] or machines[0]['image_ref'] != expected['image']:
            raise Refused('recorded production pair changed; mutation refused')
    pending_absent(context['pair'])


def owner_command(context, app, action, command=''):
    # Executed on the exact recorded machine. Pending apply input and owner proof
    # are checked again beside the mutation. Never remove a pending move archive.
    payload = {'operation': context['operation'], 'name': APPS[app],
               'action': action, 'command': command, 'phase': context['phases'][app]}
    code = """import json,sys,subprocess
from pathlib import Path
p=json.loads(sys.argv[1]); hold=Path('/data/hold'); owner=Path('/data/atlas-backup-'+p['operation']+'.owner')
assert not Path('/data/incoming/'+p['name']+'.tar.gz').exists(), 'pending apply input'
if p['action']=='acquire':
 assert not hold.exists() and not owner.exists(), 'foreign hold or owner'
 with owner.open('x') as f: f.write(p['operation'])
 with hold.open('x') as f: f.write(p['operation'])
else:
 assert owner.read_text()==p['operation'], 'owner mismatch'
 if hold.exists(): assert hold.read_text()==p['operation'], 'foreign hold'
 if p['action'] not in ['release']:
  if p['phase']=='acquired': assert hold.exists(), 'owned hold disappeared'
  if p['phase'] in ['releasing','released']: assert not hold.exists(), 'hold reappeared'
 if p['action']=='release': hold.unlink(missing_ok=True)
 elif p['action']=='run': subprocess.run(p['command'],shell=True,check=True)
"""
    return 'python3 -c ' + shlex.quote(code) + ' ' + shlex.quote(json.dumps(payload))


def fly(args):
    path = context_path()
    if not path or args[:1] == ['status']:
        return raw_fly(args)
    context = json.loads(path.read_text())
    fence(context)
    app = args[args.index('-a') + 1]
    phase = context['phases'][app]
    machine = context['pair'][app]['machine']
    if args[:2] == ['machine', 'restart']:
        if args[2] != machine or phase not in ['acquired', 'releasing']:
            raise Refused('restart lacks exact recorded ownership')
        bound_remote(app, machine, owner_command(context, app, 'check'))
        answer = raw_fly(args)
        if phase == 'releasing':
            context['phases'][app] = 'released'
            save_context(path, context)
        return answer
    if args[:2] == ['ssh', 'console']:
        command = args[args.index('-C') + 1]
        if command == 'touch /data/hold':
            if phase != 'initial': raise Refused('unexpected hold acquisition')
            context['phases'][app] = 'acquiring'
            save_context(path, context)
            answer = bound_remote(app, machine, owner_command(context, app, 'acquire'))
            context['phases'][app] = 'acquired'
            save_context(path, context)
            return answer
        if command == 'rm -f /data/hold':
            if phase not in ['acquiring', 'acquired', 'releasing']:
                raise Refused('release lacks recorded ownership')
            context['phases'][app] = 'releasing'
            save_context(path, context)
            return bound_remote(app, machine, owner_command(context, app, 'release'))
        # Before acquisition read-only helper probes are allowed, never mutations.
        if phase == 'initial':
            if not command.startswith('test '): raise Refused('unowned helper operation')
            return bound_remote(app, machine, command)
        return bound_remote(app, machine, owner_command(context, app, 'run', command))
    if args[:2] == ['ssh', 'sftp']:
        if phase not in ['acquired', 'released']:
            raise Refused('transfer lacks recorded ownership')
        bound_remote(app, machine, owner_command(context, app, 'check'))
        return raw_fly([*args, '--machine', machine])
    raise Refused('unsupported bound operation')


def remote(app, command):
    return fly(['ssh', 'console', '-q', '-a', app, '-C', command]).replace('\r', '')


def holds_absent():
    for app in APPS:
        remote(app, 'test ! -e /data/hold')


def held():
    for app in APPS:
        remote(app, 'test -e /data/hold')


def status(app):
    data = json.loads(fly(['status', '-a', app, '--json']))
    machines = data.get('Machines', [])
    if len(machines) != 1:
        raise Refused('expected exactly one existing machine per app')
    machine = machines[0]
    if machine['state'] != 'started' or not machine.get('checks') or any(
            c.get('status') != 'passing' for c in machine['checks']):
        raise Refused('production machine is not healthy')
    image = machine['image_ref']
    if image.get('tag') != 'master-' + MASTER or image.get('digest') != IMAGES[app]:
        raise Refused('unexpected production image; do not guess a recovery binding')
    return {'machine': machine['id'], 'image': image}


def manifest(folder):
    rows = []
    for path in sorted(folder.rglob('*'), key=lambda p: str(p.relative_to(folder))):
        if path.is_symlink():
            raise Refused('symlink requires a separately reviewed backup policy')
        if path.is_file():
            rel = './' + path.relative_to(folder).as_posix()
            if '\n' in rel or '\r' in rel:
                raise Refused('noncanonical filename')
            rows.append(digest(path) + '  ' + rel + '\n')
    if not rows:
        raise Refused('empty store')
    return ''.join(rows)


def transport(args):
    """Token routing plus held archive/manifest proof for the unchanged helper."""
    if not context_path() or not context_path().is_file():
        raise Refused('helper transport requires the recorded operation journal')
    output = Path(os.environ['ATLAS_BACKUP_OUTPUT'])
    if args[:3] == ['ssh', 'sftp', 'get']:
        if len(args) != 7 or args[3] != '-a' or args[4] not in APPS:
            raise Refused('unexpected backup transfer')
        app, archive, local = args[4:]
        name = APPS[app]
        if archive != f'/tmp/{name}.tar.gz':
            raise Refused('unexpected archive path')
        held()
        before = remote(app, f'/app/fly/manifest.sh /data/{name}')
        counts = remote(app, '/app/fly/counts.sh /data/rela') if name == 'rela' else ''
        wire = remote(app, f'sha256sum /tmp/{name}.tar.gz').split()
        if len(wire) != 2 or not re.fullmatch('[0-9a-f]{64}', wire[0]):
            raise Refused('missing remote archive digest')
        answer = fly(args)
        if digest(local) != wire[0]:
            raise Refused('archive bytes differ after transport')
        after = remote(app, f'/app/fly/manifest.sh /data/{name}')
        held()
        if before != after:
            raise Refused('store changed inside the held boundary')
        private = output / 'private'
        shutil.copyfile(local, private / f'{name}.tar.gz')
        (private / f'{name}.remote.sha256').write_text(before)
        (private / f'{name}.counts').write_text(counts)
        write_json(private / f'{name}.wire.json', {'archive_sha256': wire[0], 'held_both': True,
                                                   'captured_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())})
        return answer
    return fly(args)


def release_owned(pair):
    """Only used after preflight established both holds absent and backup began.
    Exact existing pair/slot is held by this job. Mirror supported helper's order.
    Failure is reported rather than claiming services resumed.
    """
    path = context_path()
    if not path:
        raise Refused('release lacks operation journal')
    context = json.loads(path.read_text())
    if context['pair'] != pair: raise Refused('release pair mismatch')
    for app in ['eyra-atlas-rela', 'eyra-atlas']:
        context = json.loads(path.read_text())
        if context['phases'][app] in ['initial', 'released']:
            continue
        remote(app, 'rm -f /data/hold')
        fly(['machine', 'restart', pair[app]['machine'], '-a', app, '--skip-health-checks'])
        for _ in range(60):
            try:
                status(app)
                break
            except Refused:
                time.sleep(2)
        else:
            raise Refused('service release could not be verified')
    holds_absent()


def admission():
    sha = invoke(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).strip()
    if not re.fullmatch('[0-9a-f]{40}', sha) or os.environ.get('GITHUB_REF_NAME') != 'atlas-prod-backup-' + sha:
        raise Refused('explicit reviewed full-SHA tag required')
    if os.environ.get('GITHUB_REPOSITORY') != 'eyra/atlas' or os.environ.get('GITHUB_EVENT_NAME') != 'push':
        raise Refused('only the authorized repository tag route is admitted')
    refs = invoke(['git', '-C', str(ROOT), 'ls-remote', '--exit-code', 'origin',
                   'refs/heads/master', RELEASE_REF]).splitlines()
    found = {row.split()[1]: row.split()[0] for row in refs if len(row.split()) == 2}
    if found != {'refs/heads/master': MASTER, RELEASE_REF: ECC}:
        raise Refused('release source advanced; re-review backup binding')
    return sha


def preflight():
    pending_absent()
    holds_absent()
    pair = {app: status(app) for app in APPS}
    core = json.loads(remote('eyra-atlas', 'cat /app/fly/prod/core.json'))
    expected_core = json.loads(invoke(['git', '-C', str(ROOT), 'show', MASTER + ':fly/prod/core.json']))
    if core != expected_core:
        raise Refused('packaged core settings differ from the recorded source')
    expected_manifest = hashlib.sha256(invoke(['git', '-C', str(ROOT), 'show', MASTER + ':rela/atlas.manifest.json']).encode()).hexdigest()
    for app in APPS:
        if remote(app, 'sha256sum /app/rela/atlas.manifest.json').split()[0] != expected_manifest:
            raise Refused('packaged description differs from recorded source')
    remote('eyra-atlas-rela', 'env ATLAS_RELA_DATA=/data/rela /app/rela/scripts/description.sh same')
    if core.get('env') != 'prod' or core.get('runtime') or core.get('bus_link') or core.get('agent'):
        raise Refused('unexpected Runtime/model/listener configuration')
    # Same-volume retained recovery archives; refuse insufficient capacity rather than resize.
    for app, name in APPS.items():
        command = "python3 -c \"import os,shutil;from pathlib import Path;p=Path('/data/" + name + "');files=[f for f in p.rglob('*') if f.is_file()];n=sum(f.stat().st_size+1024 for f in files)+1048576;assert files and not any(f.is_symlink() for f in p.rglob('*'));assert shutil.disk_usage('/data').free>2*n and shutil.disk_usage('/tmp').free>2*n\""
        remote(app, command)
    return pair


def validate_dets(folder):
    files = sorted(str(p) for p in folder.rglob('*.dets'))
    if not files:
        raise Refused('no persisted Facts files')
    code = "for path <- System.argv() do {:ok, t} = :dets.open_file(make_ref(), file: String.to_charlist(path), access: :read, repair: false); true = is_integer(:dets.info(t, :size)); :ok = :dets.close(t) end"
    invoke(['elixir', '-e', code, *files], label='read-only Facts DETS validation on private copy')


def retain(output, operation, pair):
    private = output / 'private'
    proof = {'operation': operation, 'backup_source_master': MASTER, 'release_ecc': ECC,
             'reviewed_backup_sha': invoke(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).strip(),
             'ci_run': os.environ.get('GITHUB_RUN_ID'),
             'before_pair': pair, 'components': {}, 'storage': 'existing per-app volumes; same failure domain',
             'consistency': 'core then rela held/restarted by existing fetch helper; both held and stable per-file manifests at transfer',
             'status': 'incomplete'}
    for app, name in APPS.items():
        local = manifest(output / 'data' / name)
        expected = (private / f'{name}.remote.sha256').read_text()
        if local != expected:
            raise Refused('held remote files differ from extracted backup')
        if name == 'beam' and not all((output / 'data' / name / f).is_file() for f in ['ledger.dets', 'links.dets']):
            raise Refused('Facts/Bus durable files missing')
        if name == 'rela' and not all((output / 'data' / name / f).exists() for f in ['entities', 'relations', 'schema.yaml', 'data-entry.yaml', 'atlas.json', 'atlas.manifest.json']):
            raise Refused('rela data/schema/description closure missing')
        wire = json.loads((private / f'{name}.wire.json').read_text())
        target = '/data/backups/' + operation
        remote(app, 'mkdir -p ' + target)
        for source, destination in [(private / f'{name}.tar.gz', name + '.tar.gz'),
                                    (private / f'{name}.remote.sha256', 'files.sha256'),
                                    (private / f'{name}.counts', 'counts.txt')]:
            fly(['ssh', 'sftp', 'put', '-a', app, str(source), target + '/' + destination + '.part'])
            remote(app, f'mv {target}/{destination}.part {target}/{destination}')
        actual = remote(app, f'sha256sum {target}/{name}.tar.gz').split()[0]
        if actual != wire['archive_sha256']:
            raise Refused('retained backup archive verification failed')
        proof['components'][name] = {**wire, 'app': app, 'location': target + '/' + name + '.tar.gz',
                                    'file_count': len(local.splitlines()),
                                    'file_manifest_sha256': hashlib.sha256(local.encode()).hexdigest(),
                                    'counts_sha256': digest(private / f'{name}.counts')}
    # Matching completion manifests must exist on BOTH volumes before this is usable.
    proof['status'] = 'complete'
    write_json(output / 'completion.json', proof)
    for app in APPS:
        target = '/data/backups/' + operation + '/complete.json'
        fly(['ssh', 'sftp', 'put', '-a', app, str(output / 'completion.json'), target + '.part'])
        remote(app, f'mv {target}.part {target}')
        if remote(app, 'sha256sum ' + target).split()[0] != digest(output / 'completion.json'):
            raise Refused('paired completion metadata not verified')
    return proof


def main(output):
    global CONTEXT
    CONTEXT = None
    sha = admission()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    (output / 'private').mkdir(mode=0o700)
    pair = preflight()
    operation = 'pre-ecc-' + time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-' + sha[:12]
    CONTEXT = output / 'private' / 'context.json'
    save_context(CONTEXT, {'operation': operation, 'pair': pair, 'phases': {app: 'initial' for app in APPS}})
    bindir = output / 'private' / 'bin'
    bindir.mkdir()
    (bindir / 'fly').symlink_to(Path(__file__).resolve())
    env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'],
               ATLAS_BACKUP_CONTEXT=str(CONTEXT), ATLAS_BACKUP_OUTPUT=str(output), ATLAS_FLY_APP='eyra-atlas',
               ATLAS_FLY_RELA_APP='eyra-atlas-rela', ATLAS_ENV='prod')
    def interrupted(_signum, _frame):
        raise Refused('job interrupted; release verification required')
    signal.signal(signal.SIGTERM, interrupted)
    began = False
    with open(output / 'private' / 'fetch.log', 'wb') as log:
        try:
            began = True
            result = subprocess.run([str(ROOT / 'fly/fetch-from-fly.sh'), '--to', str(output / 'data')],
                                    env=env, stdout=log, stderr=log)
            if result.returncode:
                raise Refused('supported fetch helper failed; private diagnostics retained')
        finally:
            if began:
                # Reconcile journal ownership even if health currently looks normal.
                # Initial/released sides are never restarted by failure cleanup.
                release_owned(pair)
    before_dets = manifest(output / 'data' / 'beam')
    validate_dets(output / 'data' / 'beam')
    if before_dets != manifest(output / 'data' / 'beam'):
        raise Refused('Facts validation changed backup bytes')
    proof = retain(output, operation, pair)
    holds_absent()
    proof['after_pair'] = {app: status(app) for app in APPS}
    if proof['after_pair'] != pair:
        raise Refused('production pair changed across backup')
    write_json(output / 'proof.json', proof)
    print('Verified paired backup retained on existing volumes; no plaintext data artifact.')


if __name__ == '__main__':
    destination = os.environ.get('ATLAS_BACKUP_OUTPUT')
    try:
        if Path(sys.argv[0]).name == 'fly':
            sys.stdout.write(transport(sys.argv[1:]))
        else:
            parser = argparse.ArgumentParser()
            parser.add_argument('--output', type=Path, required=True)
            args = parser.parse_args()
            destination = str(args.output.resolve())
            main(args.output.resolve())
    except (Refused, OSError, ValueError, KeyError) as error:
        # Only our bounded diagnostics are public. Never print exceptions from external data.
        reason = str(error) if isinstance(error, Refused) else type(error).__name__
        if destination:
            failure = Path(destination) / 'failure.json'
            if not failure.exists():
                write_json(failure, {'status': 'refused', 'operation': reason[:1500],
                                     'holds': 'do not infer released from a failed job; inspect the paired status'})
        print('backup refused: ' + reason, file=sys.stderr)
        sys.exit(1)
