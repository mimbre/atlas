"""One bounded actual IS91 Runtime, private stub configuration, no backend or model."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import runtime_cli

ROOT = Path(__file__).resolve().parents[2]
parent = os.environ.get('ATLAS_LIFECYCLE_PROOF_DIR')
if parent:
    Path(parent).mkdir(parents=True, exist_ok=True)
directory = Path(tempfile.mkdtemp(prefix='is136-', dir=parent)).resolve()
print('Private Runtime lifecycle evidence:', directory, flush=True)
# Reserve an unused loopback port without listening: this fixture cannot reach a Bus.
reservation = socket.socket(); reservation.bind(('127.0.0.1', 0))
config = directory/'runtime.json'; client = directory/'client.json'; home = directory/'instance'
config.write_text(json.dumps(dict(env='test', bus_link=dict(mode='client', host='127.0.0.1', port=reservation.getsockname()[1], machine='private136'), runtime=dict(machine='private136', agents={'private-stub': {'port':'stub'}}, round_seconds=1))))
client.write_text(json.dumps(dict(env='test',control=dict(port=1))))
environment = {key:value for key,value in os.environ.items() if not key.startswith('ATLAS_')}
environment.update(ATLAS_NO_UPDATE='1', ATLAS_ENV_FILE=str(client), ATLAS_RUNTIME_FILE=str(config), ATLAS_RUNTIME_HOME=str(home), ATLAS_BUS_LINK_TOKEN='private-synthetic-token', PYTHONDONTWRITEBYTECODE='1', ELIXIR_ERL_OPTIONS='+S 1:1')
transcript = []

def command(action):
    result = subprocess.run([runtime_cli.executable(),'node',action,'--env','test','--machine','private136','--checkout',str(ROOT),'--json'],env=environment,text=True,capture_output=True,timeout=35)
    transcript.append(dict(operation=action,code=result.returncode,stdout=result.stdout,stderr=result.stderr))
    (directory/'transcript.json').write_text(json.dumps(transcript,indent=2))
    assert result.returncode == 0, transcript[-1]
    frame = json.loads(result.stdout)
    assert frame['op'] == 'machine_'+action+'_result', frame
    assert frame['target'] == frame['status']['target'] == dict(environment='test',machine='private136'), frame
    return frame['status']

try:
    # Readonly invocation must not create even the instance directory.
    assert command('status')['state'] == 'absent'
    assert not home.exists()
    first = command('start'); assert first['state'] == 'owned'
    manifest = json.loads((home/'runtime.processes.json').read_text())
    assert manifest['phase'] == 'started' and set(manifest['processes']) == {'runtime'}
    assert command('status')['pid'] == command('start')['pid'] == first['pid']
    assert command('stop')['state'] == command('stop')['state'] == 'stopped'
    assert command('status')['state'] == 'absent'
    assert not (home/'runtime.pid').exists()
    assert (home/'runtime.log').exists() and (home/('runtime-ready-'+manifest['instance']+'.json')).exists()
    again = command('start'); assert again['state'] == 'owned'
    next_manifest = json.loads((home/'runtime.processes.json').read_text())
    assert next_manifest['instance'] != manifest['instance']
    assert (home/('stopped-'+manifest['instance']+'.json')).exists()
    assert command('stop')['state'] == 'stopped'
    assert 'core layers remain stopped' in (home/'runtime.log').read_text()
    print('PASS: readonly absence, actual Runtime ready, one-process idempotence, exact stop, restart, retained proof', flush=True)
finally:
    # Only the ownership-verified CLI may stop this fixture; retain any failed proof.
    if (home/'runtime.pid').exists():
        command('stop')
    reservation.close()
