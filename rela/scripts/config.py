#!/usr/bin/env python3
"""Selected native schema closure. Rela remains the semantic schema validator.

Paths follow rela 26.11.2: every include is relative to the root schema directory.
Only configuration is copied; entities, relations and actor records are never written.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys_path = str(Path(__file__).resolve().parent)
if sys_path not in sys.path:
    sys.path.insert(0, sys_path)
from verify import verify

try:
    import yaml
except ImportError:
    sys.exit('config: install rela/scripts/requirements.txt; set ATLAS_CONFIG_PYTHON to that Python')


class ConfigError(ValueError):
    pass


class StrictLoader(yaml.SafeLoader):
    # Match rela's YAML 1.2 booleans: words such as the relation label "on"
    # are strings, not YAML 1.1 booleans.
    yaml_implicit_resolvers = {
        key: [(tag, regexp) for tag, regexp in entries
              if tag != 'tag:yaml.org,2002:bool']
        for key, entries in yaml.SafeLoader.yaml_implicit_resolvers.items()
    }


StrictLoader.add_implicit_resolver('tag:yaml.org,2002:bool', re.compile(r'^(?:true|false)$', re.I), list('tTfF'))


def mapping(loader, node, deep=False):
    # Check explicit keys before expanding YAML merges (native anchors remain supported).
    explicit = [loader.construct_object(k, deep=deep) for k, _ in node.value if k.tag != 'tag:yaml.org,2002:merge']
    if len(explicit) != len(set(explicit)):
        raise ConfigError('duplicate YAML key')
    loader.flatten_mapping(node)
    return yaml.SafeLoader.construct_mapping(loader, node, deep=deep)


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
PARTIAL_KEYS = {'includes', 'types', 'entities', 'relations', 'validations'}
ROOT_KEYS = PARTIAL_KEYS | {'version', 'namespace', 'description', 'worlds', 'copies', 'default_world'}


def closure(root):
    root = Path(root).resolve()
    files, active, seen = [], set(), set()
    resolved = {}

    def visit(name):
        path = root / name
        if not isinstance(name, str) or not name or Path(name).is_absolute() or '..' in Path(name).parts or not re.fullmatch(r'[A-Za-z0-9_./-]+', name):
            raise ConfigError(f'unsafe include path: {name}')
        if not path.resolve().is_relative_to(root) or path.is_symlink():
            raise ConfigError(f'include escapes root: {name}')
        if name in active:
            raise ConfigError(f'include cycle: {name}')
        if name in seen:
            return
        active.add(name)
        if len(active | seen) > 64 or path.stat().st_size > 2_000_000:
            raise ConfigError('schema closure exceeds 64 files or 2 MB per file')
        doc = yaml.load(path.read_text(), Loader=StrictLoader)
        if not isinstance(doc, dict):
            raise ConfigError(f'{name}: expected a YAML map')
        unknown = set(doc) - (ROOT_KEYS if name == 'schema.yaml' else PARTIAL_KEYS)
        if unknown:
            raise ConfigError(f'{name}: unknown keys {sorted(unknown)}')
        includes = doc.get('includes', [])
        if not isinstance(includes, list) or not all(isinstance(x, str) for x in includes):
            raise ConfigError(f'{name}: includes must be a list of paths')
        for child in includes:
            visit(child)
        for section, definitions in doc.items():
            if section == 'includes':
                continue
            if section in {'types', 'entities', 'relations'}:
                if not isinstance(definitions, dict):
                    raise ConfigError(f'{name}: {section} must be a map')
                target = resolved.setdefault(section, {})
                for key, value in definitions.items():
                    if key in target:
                        raise ConfigError(f'duplicate {section}.{key}')
                    target[key] = value
            elif section == 'validations':
                target = resolved.setdefault(section, [])
                names = {x.get('name') for x in target}
                for rule in definitions:
                    if rule.get('name') in names:
                        raise ConfigError('duplicate validation')
                    target.append(rule)
                    names.add(rule.get('name'))
            else:
                resolved[section] = definitions
        active.remove(name)
        seen.add(name)
        files.append(name)
    visit('schema.yaml')
    return files + ['data-entry.yaml'], resolved


def package(root, dest):
    files, _ = closure(root)
    if (Path(root) / 'atlas.manifest.json').exists():
        provenance = verify(root)
        files = sorted(set(files + list(provenance['inputs']) + ['atlas.json', 'atlas.manifest.json']))
    # Read/validate the entire closure before touching the destination.
    content = {name: (Path(root) / name).read_bytes() for name in files}
    for name, data in content.items():
        target = Path(dest) / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


def same(root, data):
    files, _ = closure(root)
    old_files, _ = closure(data)
    return set(files) == set(old_files) and all(
        (Path(root) / name).read_bytes() == (Path(data) / name).read_bytes() for name in files)


def fits(root, data, binary):
    _, schema = closure(root)
    with tempfile.TemporaryDirectory(prefix='atlas-fits-') as tmp:
        package(root, tmp)
        for part in ('entities', 'relations'):
            src = Path(data) / part
            if src.exists():
                shutil.copytree(src, Path(tmp) / part)
            else:
                (Path(tmp) / part).mkdir()
        # Validation/scan failures must not be mistaken for an empty orphan list.
        subprocess.run([binary, '--project', tmp, '--quiet', 'validate'], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        scan = subprocess.run([binary, '--project', tmp, '--quiet', 'migrate', 'gc', '--scan'],
                              check=True, capture_output=True, text=True)
        orphans = re.findall(r'^  ([A-Za-z0-9_.]+)$', scan.stdout, re.M)
        plurals = {spec.get('plural') for spec in schema.get('entities', {}).values()}
        for folder in sorted((Path(tmp) / 'entities').iterdir()):
            if folder.is_dir() and any(folder.iterdir()) and folder.name not in plurals:
                orphans.append(f'{folder.name} (a kind this build has no more)')
        relations = schema.get('relations', {})
        # Disk files use canonical names; accept inverses too, as older stores can use them.
        names = set(relations) | {s.get('inverse', {}).get('id') for s in relations.values()}
        for file in sorted((Path(tmp) / 'relations').glob('*.md')):
            parts = file.stem.split('--')
            if len(parts) == 3 and parts[1] not in names:
                orphans.append(f'{parts[1]} (a relation this build has no more)')
        if orphans:
            print('\n'.join(sorted(set(orphans))))
            return False
        return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['files', 'resolved', 'flat', 'copy', 'same', 'fits'])
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--data', type=Path)
    parser.add_argument('--bin', default='rela')
    args = parser.parse_args()
    if args.command == 'files':
        print('\n'.join(closure(args.root)[0]))
    elif args.command == 'flat':
        print(yaml.safe_dump(closure(args.root)[1], sort_keys=False))
    elif args.command == 'resolved':
        print(json.dumps(closure(args.root)[1], indent=2))
    else:
        if args.data is None:
            parser.error('--data is required')
        if args.command == 'copy':
            package(args.root, args.data)
        elif args.command == 'same':
            return 0 if same(args.root, args.data) else 1
        elif args.command == 'fits':
            return 0 if fits(args.root, args.data, args.bin) else 1
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ConfigError, OSError, yaml.YAMLError, subprocess.CalledProcessError) as e:
        print(f'config: {e}', file=sys.stderr)
        if isinstance(e, subprocess.CalledProcessError):
            print(e.stderr.decode() if isinstance(e.stderr, bytes) else e.stderr, file=sys.stderr)
        sys.exit(1)
