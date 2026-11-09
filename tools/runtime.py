#!/usr/bin/env python3
"""Local Runtime lifecycle. No Fly settings or secrets are changed here."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


def runtime_paths(environment):
    base = Path(os.environ.get("ATLAS_RUNTIME_HOME", str(Path.home() / ".local/share/atlas" / (environment + "-runtime")))).expanduser().resolve()
    settings = Path(os.environ.get("ATLAS_RUNTIME_FILE", str(base / "runtime.json"))).expanduser().resolve()
    return base, settings


def observe_status(root, environment, request, inspect_process=None, client_file="unused"):
    """Readonly IS91 projection. PID presence alone never establishes node ownership."""
    import importlib.util
    import re
    target = request['target']
    base, settings_file = runtime_paths(environment)
    status = dict(target=target, state='unsupported', basis='invalid_identity', message='invalid machine identity',
                  capabilities=dict(local_status=True, local_start=False, local_stop=False, remote_status=False), log=str(base/'runtime.log'))
    if target['environment'] != environment or not re.fullmatch(r'[a-zA-Z0-9_.-]+', target['machine']):
        return status
    settings = None
    controller = None
    try:
        settings = json.loads(settings_file.read_text())
        if not isinstance(settings, dict) or settings.get('env') != environment:
            return dict(status, basis='wrong_environment', message='local Runtime configuration belongs to a different or unknown environment')
        runtime = settings.get('runtime', {})
        link = settings.get('bus_link', {})
        if not isinstance(runtime, dict) or not isinstance(link, dict) or runtime.get('machine') != target['machine'] or link.get('machine') != target['machine']:
            return dict(status, basis='wrong_machine', message='selected machine does not match the local Runtime configuration')
    except FileNotFoundError:
        if (base/'runtime.pid').exists():
            return dict(status, state='unverified', basis='missing_configuration', message='retained PID has no matching machine configuration; ownership unknown')
    except (OSError, ValueError):
        return dict(status, basis='unreadable_configuration', message='local Runtime configuration is unavailable or malformed')
    if (base/'runtime.processes.json').exists() or (isinstance(settings, dict) and settings.get('bus_link', {}).get('mode') == 'client'):
        try:
            controller = load_lifecycle(root, environment, target['machine'], client_file)
            controller.configuration_data()
            status['capabilities']['local_start'] = True
        except (OSError, ValueError, KeyError, TypeError):
            pass
    try:
        record = (base/'runtime.pid').read_text()
    except FileNotFoundError:
        if (base/'runtime.processes.json').exists():
            try:
                if controller is None or controller.verify()['phase'] != 'stopped':
                    raise ValueError('incomplete ownership')
            except (OSError, ValueError, KeyError, TypeError):
                status['capabilities']['local_start'] = False
                return dict(status, state='unverified', basis='incomplete_ownership', message='managed startup/ownership record is incomplete; no process action permitted')
        return dict(status, state='absent', basis='no_pid_record', message='no retained local Runtime PID; remote availability is not queried')
    except (OSError, ValueError):
        status['capabilities']['local_start'] = False
        return dict(status, state='stale', basis='invalid_pid_record', message='retained PID record is invalid or unreadable; ownership not established')
    status['capabilities']['local_start'] = False
    # Reuse the shared pure PID parser before invoking any inspector. Its native
    # boundary independently checks pid_t bounds too; no stop path is used here.
    spec = importlib.util.spec_from_file_location('atlas_process_identity', Path(root)/'tools/process_identity.py')
    inspector = importlib.util.module_from_spec(spec)
    previous = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(inspector)
    finally:
        sys.dont_write_bytecode = previous
    try:
        pid = inspector.parse_pid(record)
    except ValueError:
        return dict(status, state='stale', basis='invalid_pid_record', message='retained PID is malformed or outside supported pid_t bounds; no inspection performed')
    if inspect_process is None:
        inspect_process = inspector.process_identity
    try:
        identity = inspect_process(pid)
    except (OSError, ValueError):
        return dict(status, state='stale', basis='process_unavailable', pid=pid, message='retained process is unavailable or cannot be inspected; no Runtime claim')
    if identity['uid'] != os.getuid():
        return dict(status, state='stale', basis='owner_mismatch', pid=pid, message='retained PID belongs to another user; ownership refused')
    if (base/'runtime.processes.json').exists():
        try:
            controller = load_lifecycle(root, environment, target['machine'], client_file)
            owned = controller.verify()
            if owned['phase'] != 'stopped' and owned.get('processes', {}).get('runtime', {}).get('pid') == pid:
                return dict(status, state='owned', basis='owned_process', pid=pid, process_present=True, message='exact owned OS process; Runtime/link/worker health is not inferred', capabilities=dict(local_status=True, local_start=True, local_stop=True, remote_status=False))
        except (OSError, ValueError, KeyError, TypeError):
            return dict(status, state='stale', basis='ownership_mismatch', pid=pid, message='retained Runtime ownership cannot be proven; no lifecycle action permitted')
    return dict(status, state='unverified', basis='pid_only_legacy', pid=pid, process_present=True,
                message='OS process exists, but no retained role/instance/start binding proves it is this Runtime; health and ownership unknown')


def status_cli(root, environment, options, operation="status", client_file="unused"):
    # Use already-built shared codecs. A status invocation never compiles, installs,
    # creates a Runtime directory, resolves credentials or opens a proxy.
    candidates = [Path(root)/part/'_build'/mode/'lib' for part in ('bff/contract', 'beam') for mode in ('dev', 'test', 'prod')]
    build = next((path for path in candidates if (path/'atlas_bff_contract/ebin/Elixir.AtlasBFFContract.Wire.Runtime.MachineProtocol.beam').is_file()), None)
    if build is None:
        print('Runtime status: unsupported (machine status codec not built; build bff/contract first)', file=sys.stderr)
        return 2
    executable = shutil.which('elixir')
    if executable is None:
        print('Runtime status: unsupported (Elixir codec interpreter unavailable)', file=sys.stderr)
        return 2
    paths = [argument for path in sorted(build.glob('*/ebin')) for argument in ('-pa', str(path))]
    _, settings = runtime_paths(environment)
    env = dict(os.environ, ELIXIR_ERL_OPTIONS='+S 1:1', PYTHONDONTWRITEBYTECODE='1')
    env.pop('ATLAS_RUNTIME_READ_TOKEN', None)
    return subprocess.call([executable, *paths, str(Path(root)/'tools/runtime_status.exs'), root, environment, str(settings), '--operation', operation, str(Path(client_file).resolve()), *options], env=env)


def load_lifecycle(root, environment, machine, client_file):
    spec = __import__('importlib.util', fromlist=['util']).spec_from_file_location('runtime_process_policy', Path(root)/'tools/runtime_process.py')
    module = __import__('importlib.util', fromlist=['util']).module_from_spec(spec)
    previous = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous
    base, configuration = runtime_paths(environment)
    return module.LocalRuntime(root, environment, machine, base, configuration, client_file)


def operate(root, client_file, environment, request):
    target = request['target']
    controller = load_lifecycle(root, environment, target['machine'], client_file)
    action = {'machine_start': 'start', 'machine_stop': 'stop'}.get(request['op'])
    report = dict(target=target, state='unsupported', basis='ownership_refused', message='unproven Runtime ownership',
                  capabilities=dict(local_status=True, local_start=False, local_stop=False, remote_status=False))
    if action is None or target['environment'] != environment:
        return report
    try:
        record = getattr(controller, action)()
        if record is None or record['phase'] == 'stopped':
            can_start = False
            try:
                controller.configuration_data(); can_start = True
            except (OSError, ValueError, KeyError, TypeError): pass
            return dict(report, state='stopped', basis='owned_stop_complete' if record else 'no_records', message='no managed Runtime process remains', capabilities=dict(local_status=True, local_start=can_start, local_stop=False, remote_status=False))
        return dict(report, state='owned', basis='owned_process', pid=record['processes']['runtime']['pid'], process_present=True, message='exact owned OS process; '+('startup acknowledged' if record['phase']=='started' else 'startup not yet acknowledged')+'; worker/link health is not inferred', capabilities=dict(local_status=True, local_start=True, local_stop=True, remote_status=False))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        return dict(report, message='local Runtime lifecycle refused: '+str(error))


def main():
    command, root, client_file, environment, *options = sys.argv[1:]
    if command in ('runtime-status', 'runtime', 'runtime-stop', 'runtime-start'):
        action = {'runtime-status': 'status', 'runtime': 'start', 'runtime-start': 'start', 'runtime-stop': 'stop'}[command]
        return status_cli(root, environment, options, action, client_file)
    if command == '_runtime-status-observe':
        print(json.dumps(observe_status(root, environment, json.loads(options[0]), client_file=client_file)))
        return 0
    if command == '_runtime-machine-operate':
        print(json.dumps(operate(root, client_file, environment, json.loads(options[0]))))
        return 0
    sys.exit('unsupported Runtime operation')


if __name__ == '__main__':
    sys.exit(main())
