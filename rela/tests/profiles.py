"""Private dependency-direction fixtures; neither profile is an installed product."""
import copy
import json
from pathlib import Path
import shutil
import sys
import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import assemble


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')


def make(profile, dest):
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    groups = ['foundation']
    if profile == 'incident':
        groups += ['foundation/audit', 'software']
    elif profile != 'foundation':
        raise ValueError(profile)
    sources = []
    includes = []
    for group in groups:
        folder = dest / 'modules' / group
        # Foundation copy includes optional audit on disk, but the minimal root never selects it.
        folder.mkdir(parents=True, exist_ok=True)
        for name in ('schema.yaml', 'atlas.json'):
            shutil.copy(ROOT / 'modules' / group / name, folder / name)
        sources.append(f'modules/{group}/atlas.json')
        includes.append(f'modules/{group}/schema.yaml')
    runtime = json.loads((ROOT / 'flow-runtime.json').read_text())
    runtime['flow_runtime']['selection'] = {}
    write(dest / 'flow-runtime.json', runtime)
    shutil.copy(ROOT / 'data-entry.yaml', dest / 'data-entry.yaml')
    selected = {'version': '1.0', 'namespace': 'https://example.invalid/fixture#', 'description': 'Private dependency fixture', 'includes': includes}
    extension = {'start': {'assigned': {'empty': 'Nothing is assigned to you.'}}}
    # Each composition binds verdict subjects, including the foundation acceptance gate.
    about = {'label': 'about', 'from': ['gate_verdict'], 'to': ['decision'],
             'max_outgoing': 1, 'inverse': {'id': 'gate_verdicts', 'label': 'gate verdicts'}}
    binding = {'relations': {'about': about}}
    includes.append('bindings.yaml')
    if profile == 'incident':
        current = assemble.read(ROOT / 'compositions/atlas-eyra/atlas.json')
        binding['relations']['assignment'] = {'label': 'assignment', 'from': ['incident', 'issue', 'pull_request'], 'to': ['assignment'], 'max_outgoing': 1, 'inverse': {'id': 'assignment_of', 'label': 'assignment of'}}
        about['to'] += ['incident', 'issue', 'pull_request']
        workflow = {'entities': {'incident': {'label': 'Incident', 'plural': 'incidents', 'id_type': 'manual', 'id_prefix': 'INC-', 'properties': {'title': {'type': 'string', 'required': True}, 'description': {'type': 'string'}}}}, 'relations': {
          'in_incident': {'label': 'in incident', 'from': ['issue'], 'to': ['incident'], 'max_outgoing': 1, 'inverse': {'id': 'issues', 'label': 'issues'}},
          'resolved_by': {'label': 'resolved by', 'from': ['incident'], 'to': ['person'], 'max_outgoing': 1, 'inverse': {'id': 'resolved_incidents', 'label': 'resolved incidents'}}}}
        (dest / 'incident.yaml').write_text(yaml.safe_dump(workflow, sort_keys=False))
        includes.append('incident.yaml')
        extension['relations'] = {
            'assignment': copy.deepcopy(current['relations']['assignment']),
            'in_incident': {'parent': True},
            'resolved_by': {'only_target': {'error': 'only a person records service restoration'}, 'actions': {'set': {'key': 'a', 'label': 'Resolve'}, 'remove': {'key': 'a', 'label': 'Reopen'}}}}
        issue = copy.deepcopy(current['entities']['issue'])
        issue.setdefault('create', {})['id'] = {'prefix': 'IS-Maint-', 'digits': 2}
        extension['entities'] = {'incident': {'start': {'key': 'i', 'label': 'Incidents'}, 'create': {'ask': ['title', 'description'], 'id': {'prefix': 'INC-', 'digits': 2}}, 'completion': {'by': 'resolved_by'}}, 'issue': issue}
        extension['flows'] = {name: copy.deepcopy(current['flows'][name]) for name in ['build_and_merge', 'review_and_merge']}
        extension['flows']['build_and_merge']['states'][-1]['owner'] = {'kind': 'agent', 'key': 'runner'}
        extension['flows']['restore_service'] = {
            'kinds': ['incident'], 'on': 'assignment', 'field': 'expected', 'state_field': 'flow_state', 'handover_field': 'handover', 'owner_relation': 'assigned_to',
            'states': [{'name': 'done', 'when': {'completed': True}, 'done': True}, {'name': 'restore', 'owner': {'kind': 'agent', 'key': 'coordinator'}, 'expected': 'Restore service and record resolution', 'next': ['done']}]}
    (dest / 'bindings.yaml').write_text(yaml.safe_dump(binding, sort_keys=False))
    (dest / 'schema.yaml').write_text(yaml.safe_dump(selected, sort_keys=False))
    write(dest / 'fixture.json', extension)
    sources.append('fixture.json')
    write(dest / 'sources.json', {'sources': sources, 'output': 'atlas.json', 'provenance': 'atlas.manifest.json'})
    assemble.build(dest, 'sources.json', actors={'agent': ['coordinator', 'runner'], 'person': ['tester']})
    return dest


if __name__ == '__main__':
    make(sys.argv[1], sys.argv[2])
