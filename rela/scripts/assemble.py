#!/usr/bin/env python3
"""Build one bounded Atlas extension; not a runtime include/plugin mechanism."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from config import ConfigError, closure


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ConfigError(f'duplicate JSON key: {key}')
        result[key] = value
    return result


def read(path):
    path = Path(path)
    if path.stat().st_size > 2_000_000:
        raise ConfigError(f'{path}: JSON input exceeds 2 MB')
    return json.loads(path.read_text(), object_pairs_hook=unique, parse_constant=lambda value: (_ for _ in ()).throw(ConfigError(f'invalid JSON constant {value}')))


def keys(value, allowed, path):
    if not isinstance(value, dict):
        raise ConfigError(f'{path}: expected a map')
    unknown = set(value) - set(allowed.split())
    if unknown:
        raise ConfigError(f'{path}: unknown keys {sorted(unknown)}')


def combine(left, right, path=''):
    for key, value in right.items():
        at = f'{path}.{key}' if path else key
        if key not in left:
            left[key] = copy.deepcopy(value)
        elif isinstance(left[key], dict) and isinstance(value, dict) and left[key] and value:
            combine(left[key], value, at)
        else:
            raise ConfigError(f'duplicate extension leaf: {at}')
    return left


def validate(extra, schema, actors=None):
    """Only current Atlas annotation vocabulary, with schema-resolved references."""
    keys(extra, '_about todo runtime guidance start shell types entities relations progress flows', 'extension')
    entities, relations, types = (schema.get(k, {}) for k in ('entities', 'relations', 'types'))

    def entity(kind):
        if kind not in entities:
            raise ConfigError(f'unknown kind: {kind}')
        return entities[kind]

    def field(kind, name):
        if name not in entity(kind).get('properties', {}):
            raise ConfigError(f'{kind}: unknown field {name}')
        return entity(kind)['properties'][name]

    def relation(name, kind=None, direction='from'):
        if name not in relations:
            raise ConfigError(f'unknown relation: {name}')
        rel = relations[name]
        if kind is not None and kind not in rel.get(direction, []):
            raise ConfigError(f'{name}: {direction} does not contain {kind}')
        return rel

    def values(kind, mapping):
        for name, allowed in mapping.items():
            prop = field(kind, name)
            enum = types.get(prop.get('type'), {}).get('values')
            if enum and any(v not in enum for v in (allowed if isinstance(allowed, list) else [allowed])):
                raise ConfigError(f'{kind}.{name}: unknown enum value')

    def navigation(spec, path):
        keys(spec, 'key label', path)
        if not isinstance(spec.get('key'), str) or len(spec['key']) != 1:
            raise ConfigError(f'{path}: shortcut must be one character')

    def condition(kind, rule, path, progress=False):
        keys(rule, 'by over through field value shows' if not progress else 'over field own while', path)
        if 'own' in rule:
            field(kind, rule['own'])
        if 'while' in rule:
            for item in rule['while']:
                condition(kind, item, path + '.while')
        if 'by' in rule:
            relation(rule['by'], kind)
        target = [kind]
        if 'over' in rule:
            target = relation(rule['over'], kind, 'to')['from']
        if 'through' in rule:
            target = relation(rule['through'], kind)['to']
        if 'field' in rule:
            for k in target:
                field(k, rule['field'])
                if 'value' in rule:
                    values(k, {rule['field']: [rule['value']]})

    if 'guidance' in extra:
        required = {
            'execution': 'environment worker turn attempt machine harness harness_version configured_model reported_model capability_version queued_input durable_accept_query consumption_evidence recorded_at recorded_position',
            'interaction': 'environment actor client_key body body_digest worker turn attempt mode execution cause recorded_at recorded_position',
            'receipt': 'environment interaction worker turn attempt execution stage evidence_id admission_id consumption_id reason writer cause recorded_at recorded_position',
        }
        keys(extra['guidance'], 'execution interaction receipt', 'guidance')
        if set(extra['guidance']) != set(required):
            raise ConfigError('guidance: all three durable roles required')
        kinds = []
        for role, slots in required.items():
            mapping = extra['guidance'][role]
            keys(mapping, 'kind fields', 'guidance.' + role)
            kind = mapping['kind']
            entity(kind)
            kinds.append(kind)
            if set(mapping['fields']) != set(slots.split()):
                raise ConfigError('guidance.' + role + ': incomplete field mapping')
            if len(set(mapping['fields'].values())) != len(mapping['fields']):
                raise ConfigError('guidance.' + role + ': duplicate field mapping')
            for name in mapping['fields'].values():
                field(kind, name)
        if len(set(kinds)) != 3:
            raise ConfigError('guidance: roles must use separate kinds')
        turn = extra.get('runtime', {}).get('turn', {})
        field(turn.get('kind'), turn.get('attempt'))

    if 'todo' in extra:
        keys(extra['todo'], 'title why instructions answers', 'todo')
    if 'shell' in extra:
        shell = extra['shell']
        keys(shell, 'title tabs', 'shell')
        if not isinstance(shell.get('title'), str) or not shell['title'].strip() or len(shell['title'].encode()) > 128:
            raise ConfigError('shell.title: expected nonempty text')
        if not isinstance(shell.get('tabs'), list) or not shell['tabs'] or len(shell['tabs']) > 64:
            raise ConfigError('shell.tabs: expected nonempty list')
        ids, targets = set(), set()
        for tab in shell['tabs']:
            keys(tab, 'id label to assigned', 'shell.tabs')
            if any(not isinstance(tab.get(k), str) or not tab[k].strip() for k in ('id', 'label', 'to')):
                raise ConfigError('shell.tabs: id, label and to require nonempty text')
            if any(len(tab[k].encode()) > limit for k, limit in [('id', 64), ('label', 128), ('to', 2048)]):
                raise ConfigError('shell.tabs: text exceeds size limit')
            if not isinstance(tab.get('assigned', False), bool):
                raise ConfigError('shell.tabs.assigned: expected boolean')
            target = tab['to']
            if target == '/':
                if tab.get('assigned') is not True or not extra.get('start', {}).get('assigned'):
                    raise ConfigError('shell.tabs: root requires an assigned start')
            elif target.startswith('/k/') and target.count('/') == 2:
                entity(target[3:])
            else:
                raise ConfigError('shell.tabs: destination must be an index page')
            if tab['id'] in ids or target in targets:
                raise ConfigError('shell.tabs: duplicate id or destination')
            ids.add(tab['id'])
            targets.add(target)
    if 'start' in extra:
        keys(extra['start'], 'assigned open', 'start')
        if 'assigned' in extra['start']:
            spec = extra['start']['assigned']
            keys(spec, 'relation title count empty', 'start.assigned')
            relation(spec['relation'])
        if 'open' in extra['start']:
            keys(extra['start']['open'], 'title empty', 'start.open')
    for name, spec in extra.get('types', {}).items():
        if name not in types:
            raise ConfigError(f'unknown type: {name}')
        keys(spec, 'format', f'types.{name}')
        if spec.get('format') != 'url':
            raise ConfigError('unknown type format')
    shortcuts = []
    for kind, spec in extra.get('entities', {}).items():
        entity(kind)
        keys(spec, 'top primary start create properties completion progress connector agent order by_hand late actions counts requires authority frozen replaces layering', f'entities.{kind}')
        if 'start' in spec:
            navigation(spec['start'], kind + '.start')
            shortcuts.append(spec['start']['key'])
        if 'primary' in spec:
            field(kind, spec['primary'])
        create = spec.get('create', {})
        keys(create, 'ask id defaults', kind + '.create')
        for name in create.get('ask', []):
            field(kind, name)
        for name, value in create.get('defaults', {}).items():
            field(kind, name)
            values(kind, {name: [value]})
        identity = create.get('id', {})
        keys(identity, 'prefix digits first from pattern template replace lower error', kind + '.create.id')
        if 'from' in identity:
            field(kind, identity['from'])
        for name, annotation in spec.get('properties', {}).items():
            field(kind, name)
            keys(annotation, 'set_by multiline label cause', f'{kind}.properties.{name}')
        if 'late' in spec:
            keys(spec['late'], 'after while label', kind + '.late')
            for key in ('after', 'while'):
                field(kind, spec['late'][key])
        for count in spec.get('counts', []):
            keys(count, 'relation text', kind + '.counts')
            relation(count['relation'], kind, 'to')
        if 'completion' in spec:
            rules = spec['completion'] if isinstance(spec['completion'], list) else [spec['completion']]
            for rule in rules:
                condition(kind, rule, kind + '.completion')
        if 'progress' in spec:
            condition(kind, spec['progress'], kind + '.progress', progress=True)
        connector = spec.get('connector', {})
        keys(connector, 'system address fields until names', kind + '.connector')
        if 'address' in connector:
            field(kind, connector['address'])
        for name in connector.get('fields', {}):
            field(kind, name)
        values(kind, connector.get('until', {}))
        if 'names' in connector:
            names = connector['names']
            keys(names, 'field relation when', kind + '.connector.names')
            field(kind, names['field'])
            relation(names['relation'], kind, 'to')
            values(kind, names.get('when', {}))
        for action in spec.get('actions', []):
            keys(action, 'key label to when', kind + '.actions')
            values(kind, action.get('when', {}))
        for rule in spec.get('requires', []):
            keys(rule, 'when fields error', kind + '.requires')
            values(kind, rule.get('when', {}))
            for name in rule.get('fields', []):
                field(kind, name)
        if 'authority' in spec:
            rule = spec['authority']
            keys(rule, 'when by kind only_kind_when delegated_by error writes writer_error also', kind + '.authority')
            values(kind, rule.get('writes', {}))
            values(kind, rule.get('when', {}))
            if rule['kind'] not in relation(rule['by'], kind)['to']:
                raise ConfigError(f'{kind}.authority: {rule["by"]} does not point at {rule["kind"]}')
            for condition_values in rule.get('only_kind_when', []):
                values(kind, condition_values)
            if 'delegated_by' in rule:
                relation(rule['delegated_by'], kind)
        if 'layering' in spec:
            rule = spec['layering']
            keys(rule, 'relation field not error', kind + '.layering')
            if relation(rule['relation'], kind)['to'] != [kind]:
                raise ConfigError(f'{kind}.layering: {rule["relation"]} must point at {kind}')
            field(kind, rule['field'])
            values(kind, {rule['field']: list(rule['not'])})
            for banned in rule['not'].values():
                values(kind, {rule['field']: banned})
        if 'frozen' in spec:
            keys(spec['frozen'], 'when only error', kind + '.frozen')
            values(kind, spec['frozen'].get('when', {}))
            values(kind, spec['frozen'].get('only', {}))
        if 'replaces' in spec:
            rule = spec['replaces']
            keys(rule, 'relation when of set error', kind + '.replaces')
            if relation(rule['relation'], kind)['to'] != [kind]:
                raise ConfigError(f'{kind}.replaces: {rule["relation"]} must point at {kind}')
            values(kind, rule.get('when', {}))
            values(kind, rule.get('of', {}))
            values(kind, rule.get('set', {}))
    if len(shortcuts) != len(set(shortcuts)):
        raise ConfigError('duplicate navigation shortcut')
    parents = {}
    for name, annotation in extra.get('relations', {}).items():
        rel = relation(name)
        keys(annotation, 'parent add component set_by limit actions only_target requires_completed_children closes_parent', 'relations.' + name)
        if annotation.get('parent'):
            for kind in rel['from']:
                if kind in parents:
                    raise ConfigError(f'ambiguous parent for {kind}')
                parents[kind] = name
        if 'component' in annotation:
            component = annotation['component']
            keys(component, 'key values', name + '.component')
            template = component.get('key')
            if not isinstance(template, str) or not template.strip() or len(template.encode()) > 2048:
                raise ConfigError(f'{name}: component key template must be nonempty text within 2048 bytes')
            if len(rel['to']) != 1:
                raise ConfigError(f'{name}: component needs one target kind')
            for prop in component.get('values', {}):
                field(rel['to'][0], prop)
        if 'limit' in annotation:
            keys(annotation['limit'], 'max field values error', name + '.limit')
            for kind in rel['from']:
                values(kind, {annotation['limit']['field']: annotation['limit']['values']})
        if 'only_target' in annotation:
            keys(annotation['only_target'], 'error also', name + '.only_target')
        actions = annotation.get('actions', {})
        keys(actions, 'set remove change', name + '.actions')
        for action_name, action in actions.items():
            keys(action, 'key label with cause', name + '.actions.' + action_name)
            for prop in action.get('with', []):
                for kind in rel['from']:
                    field(kind, prop)
    if 'progress' in extra:
        keys(extra['progress'], 'order done_label to_test', 'progress')
        order = extra['progress'].get('order', [])
        known = {v for spec in types.values() for v in spec.get('values', [])}
        known.add(extra['progress'].get('to_test', {}).get('value'))
        if len(order) != len(set(order)) or any(v not in known for v in order):
            raise ConfigError('progress order has duplicate or unknown values')
        if 'to_test' in extra['progress']:
            keys(extra['progress']['to_test'], 'value label', 'progress.to_test')
    used_kinds = set()
    for name, flow in extra.get('flows', {}).items():
        if extra.get('runtime', {}).get('turn') and 'handover_field' not in flow:
            raise ConfigError(f'{name}: Runtime flows require handover_field')
        keys(flow, 'on state_field handover_field owner_relation kinds field states', 'flows.' + name)
        kinds = flow.get('kinds', [])
        if used_kinds.intersection(kinds):
            raise ConfigError('overlapping flow kinds')
        used_kinds.update(kinds)
        for kind in kinds:
            entity(kind)
        written = kinds
        if 'on' in flow:
            rel = relation(flow['on'])
            for kind in kinds:
                relation(flow['on'], kind)
            written = rel['to']
        for kind in written:
            for f in ('field', 'state_field', 'handover_field'):
                if f in flow:
                    field(kind, flow[f])
            if 'owner_relation' in flow:
                relation(flow['owner_relation'], kind)
        for state in flow.get('states', []):
            keys(state, 'name when done owner expected why next every_seconds todo', name + '.state')
            when = state.get('when', {})
            keys(when, 'completed progress reopened values empty', name + '.when')
            if 'progress' in when and when['progress'] not in extra.get('progress', {}).get('order', []):
                raise ConfigError(f'{name}: unknown progress condition')
            for kind in kinds:
                values(kind, when.get('values', {}))
                if 'reopened' in when:
                    relation(when['reopened'], kind)
            if 'empty' in when:
                relation(when['empty'])
            owner = state.get('owner')
            if owner is not None:
                keys(owner, 'kind key', name + '.owner')
                entity(owner['kind'])
                if actors is not None and owner['key'] not in actors.get(owner['kind'], []):
                    raise ConfigError(f'missing actor: {owner["kind"]}/{owner["key"]}')
            todo = state.get('todo', {})
            keys(todo, 'instructions section answers', name + '.todo')
            if 'section' in todo:
                keys(todo['section'], 'field heading', name + '.todo.section')
                for kind in kinds:
                    field(kind, todo['section']['field'])
            answers = todo.get('answers', [])
            answer_keys = [a.get('key') for a in answers]
            if len(answer_keys) != len(set(answer_keys)):
                raise ConfigError('duplicate answer shortcut')
            for answer in answers:
                keys(answer, 'key label set remove', name + '.todo.answer')
                for action in ('set', 'remove'):
                    if action in answer:
                        for kind in kinds:
                            relation(answer[action], kind)
    runtime = extra.get('runtime', {})
    keys(runtime, 'turn agent', 'runtime')
    if runtime and not {'turn', 'agent'}.issubset(runtime):
        raise ConfigError('runtime requires both turn and agent mappings')
    if 'agent' in runtime:
        keys(runtime['agent'], 'cannot_run', 'runtime.agent')
        # Runtime obtains agent kinds from the target of turn.by, not a fixed name.
    if 'turn' in runtime:
        turn = runtime['turn']
        keys(turn, 'kind key on by state running ended machine lease activity why ended_at outcome attempt', 'runtime.turn')
        kind = turn['kind']
        entity(kind)
        for key in ('state', 'machine', 'lease', 'activity', 'why', 'ended_at', 'outcome'):
            if key not in turn:
                raise ConfigError(f'runtime.turn: missing {key}')
            field(kind, turn[key])
        values(kind, {turn['state']: [turn['running'], turn['ended']]})
        relation(turn['on'], kind)
        agent_kinds = relation(turn['by'], kind)['to']
        for agent in agent_kinds:
            if 'agent' in runtime:
                field(agent, runtime['agent']['cannot_run'])
    return extra


def flow_check(description):
    # Call the actual generic engine check, with no application/model/server started.
    repo = Path(__file__).resolve().parents[2]
    code = 'd = System.argv() |> hd() |> File.read!() |> JSON.decode!(); p = AtlasState.Flows.check(d); if Enum.any?(p, fn {_, v} -> v != [] end), do: (IO.inspect(p); System.halt(1))'
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as file:
        json.dump(description, file)
        file.flush()
        env = dict(os.environ, ELIXIR_ERL_OPTIONS='+S 2:2')
        subprocess.run(['elixir', '-r', str(repo / 'beam/apps/atlas_state/lib/atlas_state/flows.ex'), '-e', code, file.name], check=True, env=env)


def native_check(root):
    bindir = os.environ.get('ATLAS_E2E_RELA_BIN') or os.environ.get('ATLAS_RELA_BIN') or str(Path.home() / '.local/share/atlas/test/bin')
    binary = Path(bindir) / 'rela'
    if not binary.exists():
        raise ConfigError('install pinned rela with start-test.sh install before assembling')
    version = subprocess.check_output([str(binary), 'version'], text=True).strip()
    if version != 'rela version 26.11.2':
        raise ConfigError(f'expected rela 26.11.2, got {version}')
    subprocess.run([str(binary), '--project', str(root), '--quiet', 'validate'], check=True)


def build(root, manifest, check=False, actors=None):
    root = Path(root).resolve()
    if not (root / manifest).resolve().is_relative_to(root) or '..' in Path(manifest).parts:
        raise ConfigError('manifest escapes selected root')
    spec = read(root / manifest)
    keys(spec, 'sources output provenance', 'sources manifest')
    files, schema = closure(root)
    native_check(root)
    assembled = {}
    sources = spec['sources']
    if not isinstance(sources, list) or not sources or len(sources) != len(set(sources)) or len(sources) > 32:
        raise ConfigError('sources: expected 1..32 distinct paths')
    for source in sources:
        path = root / source
        if not path.resolve().is_relative_to(root) or '..' in Path(source).parts or path.is_symlink():
            raise ConfigError(f'unsafe source path: {source}')
        fragment = read(path)
        if not isinstance(fragment, dict):
            raise ConfigError(f'{source}: expected a map')
        combine(assembled, fragment)
    validate(assembled, schema, actors)
    description = copy.deepcopy(schema)
    # This merge is safe only after the annotation whitelist rejects structural writes.
    def overlay(left, right):
        for key, value in right.items():
            if isinstance(left.get(key), dict) and isinstance(value, dict):
                overlay(left[key], value)
            else:
                left[key] = copy.deepcopy(value)
    overlay(description, assembled)
    flow_check(description)
    output = (json.dumps(assembled, indent=2, ensure_ascii=False) + '\n').encode()
    inputs = sorted(set(files + sources + [manifest]))
    hashes = {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in inputs}
    provenance = (json.dumps({'inputs': hashes, 'output_sha256': hashlib.sha256(output).hexdigest()}, indent=2) + '\n').encode()
    outputs = {spec['output']: output, spec['provenance']: provenance}
    for name in outputs:
        if not (root / name).resolve().is_relative_to(root) or name in inputs:
            raise ConfigError(f'unsafe output path: {name}')
    if check:
        for name, content in outputs.items():
            if not (root / name).exists() or (root / name).read_bytes() != content:
                raise ConfigError(f'stale generated artifact: {name}; run assemble.py')
    else:
        # Validation finishes before any generated file is replaced.
        for name, content in outputs.items():
            target = root / name
            with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as temp:
                temp.write(content)
            os.replace(temp.name, target)
    return assembled


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    p.add_argument('--manifest', default='compositions/atlas-eyra/sources.json')
    p.add_argument('--check', action='store_true')
    p.add_argument('--actors', type=Path, help='read-only Control inventory: {kind: [actor keys]}')
    a = p.parse_args()
    build(a.root, a.manifest, a.check, read(a.actors) if a.actors else None)


if __name__ == '__main__':
    try:
        main()
    except (ConfigError, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as e:
        sys.exit(f'assemble: {e}')
