"""IS136 local Runtime ownership and lifecycle policy. No CLI or remote listener."""
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time
import uuid


class OwnershipError(ValueError):
    pass


class LocalRuntime:
    def __init__(self, root, environment, machine, base, configuration, client_file, inspector=None):
        self.root = Path(root).resolve()
        self.target = dict(environment=environment, machine=machine)
        self.base = Path(base).resolve()
        self.configuration = Path(configuration).resolve()
        self.client_file = Path(client_file).resolve()
        self.file = self.base/'runtime.processes.json'
        if inspector is None:
            spec = importlib.util.spec_from_file_location('owned_runtime_inspector', self.root/'tools/process_identity.py')
            inspector = importlib.util.module_from_spec(spec)
            previous = sys.dont_write_bytecode
            try:
                sys.dont_write_bytecode = True
                spec.loader.exec_module(inspector)
            finally:
                sys.dont_write_bytecode = previous
        self.os = inspector

    def configuration_data(self):
        if self.target['environment'] not in ('test', 'prod') or not re.fullmatch(r'[A-Za-z0-9_.-]+', self.target['machine']):
            raise OwnershipError('invalid exact Runtime identity')
        settings = json.loads(self.configuration.read_text())
        if not isinstance(settings, dict):
            raise OwnershipError('Runtime configuration must be an object')
        runtime, link = settings.get('runtime', {}), settings.get('bus_link', {})
        if not isinstance(runtime, dict) or not isinstance(link, dict):
            raise OwnershipError('Runtime and Bus configuration must be objects')
        if settings.get('env') != self.target['environment'] or runtime.get('machine') != self.target['machine'] or link.get('machine') != self.target['machine'] or link.get('mode') != 'client':
            raise OwnershipError('Runtime configuration identity mismatch')
        if not isinstance(runtime.get('agents'), dict):
            raise OwnershipError('Runtime configuration needs its declared agents')
        if type(link.get('port')) is not int or not 0 < link['port'] < 65536:
            raise OwnershipError('invalid private Bus port')
        return settings

    def _directory(self):
        info = self.base.stat()
        if info.st_uid != os.getuid() or info.st_mode & 0o022 or not stat.S_ISDIR(info.st_mode):
            raise OwnershipError('Runtime instance directory is not protected and owned')

    @contextmanager
    def locked(self, create=False):
        if create:
            self.base.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._directory()
        path = self.base/'runtime.lock'
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError as error:
            raise OwnershipError('Runtime lifecycle busy; no process action performed') from error
        identity = os.fstat(descriptor)
        try:
            os.write(descriptor, uuid.uuid4().hex.encode())
            yield
        finally:
            os.close(descriptor)
            current = path.lstat()
            if (current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino):
                path.unlink()

    def _read(self, path):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise OwnershipError('unproven Runtime control record')
        return path.read_text()

    def _write(self, path, contents):
        temporary = self.base/('.record-'+uuid.uuid4().hex)
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, 'w') as file:
                file.write(contents); file.flush(); os.fsync(file.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

    def _save(self, record):
        self._write(self.file, json.dumps(record))

    def _scope(self, record):
        expected = dict(version='1', target=self.target, directory=str(self.base), configuration=str(self.configuration), root=str(self.root))
        if not isinstance(record, dict) or any(record.get(key) != value for key, value in expected.items()) or not isinstance(record.get('instance'), str) or not re.fullmatch('[0-9a-f]{32}', record['instance']):
            raise OwnershipError('Runtime record does not bind this exact instance/configuration')
        if record.get('phase') not in ('starting', 'started', 'stopped'):
            raise OwnershipError('unknown Runtime lifecycle phase')
        if not isinstance(record.get('processes'), dict):
            raise OwnershipError('Runtime process records must be an object')

    def _boot_args(self, instance):
        return [str(self.root/'beam/runtime-node.exs'), '--environment', self.target['environment'], '--machine', self.target['machine'], '--configuration', str(self.configuration), '--directory', str(self.base), '--instance', instance]

    def _role(self, record, role, identity):
        if identity['uid'] != os.getuid():
            raise OwnershipError('Runtime process owner mismatch')
        if role == 'runtime':
            expected = self._boot_args(record['instance'])
            valid = Path(identity['exe']).name == 'beam.smp' and identity['argv'][-len(expected):] == expected
        else:
            valid = False
        if not valid:
            raise OwnershipError('Runtime process role/argument binding mismatch')

    def verify(self, record=None):
        self._directory()
        record = json.loads(self._read(self.file)) if record is None else record
        self._scope(record)
        if record.get('phase') == 'stopped':
            if record.get('processes') != {} or (self.base/'runtime.pid').exists():
                raise OwnershipError('unexpected PID record after stop')
            return record
        processes = record.get('processes', {})
        if not isinstance(processes, dict) or set(processes) != {'runtime'}:
            raise OwnershipError('Runtime has no proven process records')
        # All PID domains and file bindings precede any OS lookup.
        for role, birth in processes.items():
            if not isinstance(birth, dict) or set(birth) != {'pid', 'uid', 'start'} or type(birth['uid']) is not int or birth['uid'] != os.getuid() or not isinstance(birth['start'], list) or len(birth['start']) != 2 or any(type(part) not in (int, str) for part in birth['start']):
                raise OwnershipError('malformed Runtime process birth record')
            self.os.validate_pid(birth['pid'])
            if self.os.parse_pid(self._read(self.base/f'{role}.pid')) != birth['pid']:
                raise OwnershipError('Runtime retained PID mismatch')
        for role, birth in processes.items():
            current = self.os.process_identity(birth['pid'])
            if any(current[key] != birth[key] for key in ('pid', 'uid', 'start')):
                raise OwnershipError('Runtime PID is stale or reused')
            self._role(record, role, current)
        return record

    def _capture(self, record, role, child):
        birth = self.os.process_state(child.pid)
        if birth['uid'] != os.getuid() or birth['terminal']:
            raise OwnershipError('spawned Runtime process cannot be proven')
        record['processes'][role] = {key: birth[key] for key in ('pid', 'uid', 'start')}
        self._write(self.base/f'{role}.pid', str(child.pid))
        self._save(record)

    def start(self):
        startup_env = dict(os.environ)
        startup_env.pop('ATLAS_RUNTIME_READ_TOKEN', None)
        settings = self.configuration_data()
        client = json.loads(self.client_file.read_text())
        if not isinstance(client, dict) or client.get('env') != self.target['environment']:
            raise OwnershipError('client configuration environment mismatch')
        with self.locked(create=True):
            if self.file.exists():
                record = self.verify()
                if record['phase'] != 'stopped':
                    if record['phase'] != 'started' or 'runtime' not in record['processes']:
                        raise OwnershipError('Runtime startup incomplete; records retained, no duplicate start')
                    return record  # Proven same node: do not spawn, read credentials or replay start.
                history = self.base/('stopped-'+record['instance']+'.json')
                self._write(history, json.dumps(record))
            elif (self.base/'runtime.pid').exists():
                raise OwnershipError('legacy PID-only Runtime records refuse start')
            instance = uuid.uuid4().hex
            record = dict(version='1', target=self.target, directory=str(self.base), configuration=str(self.configuration), root=str(self.root), client=str(self.client_file), instance=instance, phase='starting', processes={})
            token = startup_env.get('ATLAS_BUS_LINK_TOKEN')
            if not token:
                token = subprocess.check_output(['security', 'find-generic-password', '-s', 'atlas-bus-link-'+self.target['environment'], '-a', self.target['machine'], '-w'], stderr=subprocess.DEVNULL, timeout=5, env=startup_env).decode().strip()
            if not token:
                raise OwnershipError('Bus link authority unavailable; no Runtime started')
            self._save(record)
            # The Bus link dials bus_link.host:port itself: on Fly, the core's tailnet name (D-0089).
            child_env = dict(startup_env, ATLAS_ROOT=str(self.root), ATLAS_ENV=self.target['environment'], ATLAS_ROLE='runtime', ATLAS_ENV_FILE=str(self.configuration), ATLAS_RUNTIME_HOME=str(self.base), ATLAS_RUNTIME_INSTANCE=instance, ATLAS_CLIENT_ENV_FILE=str(self.client_file), ATLAS_BUS_LINK_TOKEN=token, MIX_ENV='dev', PYTHONDONTWRITEBYTECODE='1', ELIXIR_ERL_OPTIONS='+S 1:1')
            child_env.pop('ATLAS_RUNTIME_DISCOVERY_TOKEN', None)
            child_env.pop('ATLAS_RUNTIME_READ_TOKEN', None)
            with (self.base/'runtime.log').open('ab') as log:
                child = subprocess.Popen(['mix', 'run', '--no-start', '--no-halt', *self._boot_args(instance)], cwd=self.root/'beam', env=child_env, stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
            self._capture(record, 'runtime', child)
            deadline = time.monotonic()+20
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    raise OwnershipError('Runtime exited during startup; records retained')
                receipt = self.base/('runtime-ready-'+instance+'.json')
                if receipt.exists():
                    data = json.loads(self._read(receipt))
                    if data != dict(target=self.target, instance=instance, pid=child.pid):
                        raise OwnershipError('Runtime startup acknowledgement mismatch')
                    self.verify(record)
                    record['phase'] = 'started'; self._save(record)
                    return record
                time.sleep(.05)
            raise OwnershipError('Runtime startup acknowledgement timed out; records retained, no blind cleanup')

    def stop(self):
        if not self.base.exists():
            return None
        with self.locked():
            if not self.file.exists():
                if (self.base/'runtime.pid').exists():
                    raise OwnershipError('legacy PID-only Runtime records refuse stop')
                return None
            record = self.verify()
            if record['phase'] == 'stopped': return record
            # Recheck every role before its signal; never signal groups or replacements.
            for role in [name for name in ('runtime',) if name in record['processes']]:
                birth = record['processes'][role]
                self.verify(record)
                os.kill(birth['pid'], signal.SIGTERM)
                if not self._wait_gone(birth):
                    raise OwnershipError('Runtime exit unconfirmed; no escalation; records retained')
                # Remove only the exact control PID file already proved for this role.
                if self.os.parse_pid(self._read(self.base/f'{role}.pid')) != birth['pid']:
                    raise OwnershipError('Runtime PID record changed during stop')
                (self.base/f'{role}.pid').unlink()
                record.setdefault('completed_processes', {})[role] = birth
                # Later verification must not require a deliberately stopped role.
                record['processes'] = {key: value for key, value in record['processes'].items() if key != role}
                self._save(record)
            record['phase'] = 'stopped'; self._save(record)
            return record

    def _wait_gone(self, birth):
        deadline = time.monotonic()+5
        while time.monotonic() < deadline:
            try:
                current = self.os.process_state(birth['pid'])
            except (ProcessLookupError, FileNotFoundError): return True
            except (OSError, ValueError): return False
            if current['start'] != birth['start'] or current['terminal']: return True
            time.sleep(.05)
        return False
