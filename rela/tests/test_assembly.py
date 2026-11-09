import copy
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import assemble
import config
import profiles
from verify import verify


class AssemblyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'rela'
        shutil.copytree(ROOT, self.root)
        self.manifest = 'compositions/atlas-eyra/sources.json'
        self.schema = config.closure(self.root)[1]
        self.original = assemble.read(ROOT / 'tests/fixtures/baseline-atlas.json')

    def test_equivalence_and_freshness(self):
        result = assemble.build(self.root, self.manifest)
        prior = copy.deepcopy(result)
        self.assertEqual(prior.pop('shell')['title'], 'Atlas Console')
        self.assertEqual(set(prior.pop('guidance')), {'execution', 'interaction', 'receipt'})
        for kind in ('worker_execution', 'interaction', 'interaction_receipt'):
            self.assertEqual(prior['entities'].pop(kind), {'top': False, 'by_hand': False})
        prior['runtime']['turn'].pop('attempt')
        prior['entities']['turn']['properties'].pop('attempt')
        # The decision ledger and the use case design phase, added since the baseline.
        self.assertTrue(prior['_about'].startswith(self.original['_about']))
        prior['_about'] = self.original['_about']
        self.assertEqual(set(prior['entities'].pop('decision')), {'primary', 'order', 'create', 'properties', 'requires', 'authority', 'frozen', 'replaces', 'layering'})
        self.assertIn('only_target', prior['relations'].pop('decided_by'))
        self.assertEqual(prior['flows'].pop('decide')['kinds'], ['decision'])
        self.assertEqual(prior['flows'].pop('design_and_accept')['kinds'], ['use_case'])
        self.assertEqual(prior['flows']['test_and_accept']['kinds'], ['scene'])
        prior['flows']['test_and_accept']['kinds'] = ['scene', 'use_case']
        use_case = prior['entities']['use_case']
        self.assertEqual(use_case['create']['defaults'].pop('design_status'), 'writing')
        for name in ('design', 'design_status'):
            use_case['properties'].pop(name)
        self.assertEqual(prior, self.original)
        assemble.build(self.root, self.manifest, check=True)
        path = self.root / 'modules/foundation/atlas.json'
        path.write_text(path.read_text() + '\n')
        with self.assertRaisesRegex(config.ConfigError, 'stale generated'):
            assemble.build(self.root, self.manifest, check=True)

    def test_shell_navigation_references_and_uniqueness(self):
        extra = assemble.build(self.root, self.manifest)
        for mutate in [
            lambda s: s['tabs'].append(dict(s['tabs'][0])),
            lambda s: s['tabs'][0].update({'to': '/k/missing'}),
            lambda s: s['tabs'][0].update({'to': '/k/scene/new'}),
            lambda s: s['tabs'][0].update({'assigned': 'true'}),
            lambda s: s['tabs'][0].update({'layout': 'terminal'}),
            lambda s: s.update({'tabs': []}),
        ]:
            bad = copy.deepcopy(extra)
            mutate(bad['shell'])
            with self.assertRaises(config.ConfigError):
                assemble.validate(bad, self.schema)

    def test_decision_rules_reference_described_fields_and_relations(self):
        extra = assemble.build(self.root, self.manifest)
        mutations = [
            lambda d: d.update({'guards': {}}),
            lambda d: d['requires'][0]['fields'].append('missing'),
            lambda d: d['requires'][0]['when'].update({'force': ['unknown']}),
            lambda d: d['authority'].update({'by': 'missing'}),
            lambda d: d['authority'].update({'kind': 'decision'}),
            lambda d: d['authority'].update({'delegated_by': 'missing'}),
            lambda d: d['authority']['only_kind_when'].append({'category': ['unknown']}),
            lambda d: d['frozen']['only'].update({'status': ['unknown']}),
            lambda d: d['frozen'].update({'except': {}}),
            lambda d: d['replaces'].update({'relation': 'decided_by'}),
            lambda d: d['replaces']['set'].update({'status': 'unknown'}),
            lambda d: d['create']['id'].update({'start': 24}),
            lambda d: d['authority']['writes'].update({'status': ['unknown']}),
            lambda d: d['layering'].update({'relation': 'decided_by'}),
            lambda d: d['layering'].update({'field': 'missing'}),
            lambda d: d['layering']['not'].update({'unknown': ['instance']}),
            lambda d: d['layering']['not'].update({'platform': ['unknown']}),
            lambda d: d['layering'].update({'below': {}}),
        ]
        for mutate in mutations:
            bad = copy.deepcopy(extra)
            mutate(bad['entities']['decision'])
            with self.assertRaises((config.ConfigError, KeyError)):
                assemble.validate(bad, self.schema)

    def test_decision_flow_and_design_phase_are_sound(self):
        extra = assemble.build(self.root, self.manifest)
        decide = {s['name']: s for s in extra['flows']['decide']['states']}
        self.assertEqual({n for n, s in decide.items() if s.get('done')}, {'accepted', 'rejected', 'superseded'})
        self.assertEqual(decide['proposed']['next'], ['accepted', 'rejected'])
        design = [s['name'] for s in extra['flows']['design_and_accept']['states']]
        self.assertLess(design.index('design'), design.index('design_review'))
        self.assertLess(design.index('design_review'), design.index('building'))
        scene = [s['name'] for s in extra['flows']['test_and_accept']['states']]
        self.assertNotIn('design', scene)
        self.assertEqual(scene, [s['name'] for s in self.original['flows']['test_and_accept']['states']])

    def test_component_key_templates_are_usable_and_bounded(self):
        for template in ['', ' \t', None, 'x' * 2049]:
            bad = copy.deepcopy(self.original)
            bad['relations']['assignment']['component']['key'] = template
            with self.assertRaises(config.ConfigError):
                assemble.validate(bad, self.schema)

    def test_duplicate_leaves_arrays_and_json_keys(self):
        for value in [1, [], 'text', {}]:
            with self.assertRaisesRegex(config.ConfigError, 'duplicate'):
                assemble.combine({'a': value}, {'a': value})
        with self.assertRaisesRegex(config.ConfigError, 'duplicate JSON'):
            json.loads('{"a":1,"a":1}', object_pairs_hook=assemble.unique)
        self.assertEqual(assemble.combine({'a': {'b': 1}}, {'a': {'c': 2}}), {'a': {'b': 1, 'c': 2}})

    def test_negative_references_unknown_keys_and_structural_overwrites(self):
        mutations = [
            lambda x: x.update({'mystery': {}}),
            lambda x: x['entities']['issue'].update({'plural': 'wrong'}),
            lambda x: x['entities']['issue']['properties'].update({'title': {'type': 'boolean'}}),
            lambda x: x['relations']['assignment'].update({'from': ['person']}),
            lambda x: x['entities']['issue']['create']['ask'].append('missing'),
            lambda x: x['entities']['scene']['progress'].update({'over': 'missing'}),
            lambda x: x['runtime']['turn'].pop('outcome'),
            lambda x: x['runtime'].pop('turn'),
            lambda x: x['progress']['order'].append('unknown'),
            lambda x: x['runtime']['turn'].update({'outcome': 'missing'}),
            lambda x: x['flows']['build_and_merge'].update({'handover_field': 'missing'}),
            lambda x: x['flows']['build_and_merge'].pop('handover_field'),
            lambda x: x['flows'].update({'overlap': copy.deepcopy(x['flows']['build_and_merge'])}),
            lambda x: x['entities']['agent']['start'].update({'key': 's'}),
            lambda x: x['relations']['done_in'].update({'parent': True}),
        ]
        for mutate in mutations:
            extra = copy.deepcopy(self.original)
            mutate(extra)
            with self.assertRaises((config.ConfigError, KeyError)):
                assemble.validate(extra, self.schema)
        with self.assertRaisesRegex(config.ConfigError, 'missing actor'):
            assemble.validate(self.original, self.schema, {'agent': [], 'person': []})

    def test_guidance_mapping_is_complete_and_unambiguous(self):
        current = assemble.read(ROOT / 'atlas.json')
        for mutate in [
            lambda x: x['guidance'].pop('receipt'),
            lambda x: x['guidance']['interaction']['fields'].pop('actor'),
            lambda x: x['guidance']['interaction']['fields'].update({'actor': 'body'}),
            lambda x: x['guidance']['receipt'].update({'kind': 'interaction'}),
            lambda x: x['runtime']['turn'].pop('attempt'),
        ]:
            extra = copy.deepcopy(current)
            mutate(extra)
            with self.assertRaises((config.ConfigError, KeyError)):
                assemble.validate(extra, self.schema)

    def test_failure_retains_previous_artifacts(self):
        before = (self.root / 'atlas.json').read_bytes()
        extra = self.root / 'compositions/atlas-eyra/atlas.json'
        contents = assemble.read(extra)
        contents['flows']['build_and_merge']['states'][-1]['next'] = ['nowhere']
        profiles.write(extra, contents)
        with self.assertRaises(assemble.subprocess.CalledProcessError):
            assemble.build(self.root, self.manifest)
        self.assertEqual((self.root / 'atlas.json').read_bytes(), before)

    def test_foundation_and_incident_omit_eyra(self):
        for profile in ['foundation', 'incident']:
            target = profiles.make(profile, Path(self.tmp.name) / profile)
            _, schema = config.closure(target)
            self.assertNotIn('scene', schema['entities'])
            self.assertNotIn('use_case', schema['entities'])
            self.assertNotIn('accepted_by', schema['relations'])
            extra = assemble.read(target / 'atlas.json')
            self.assertNotIn('test_and_accept', extra.get('flows', {}))
            if profile == 'foundation':
                self.assertNotIn('issue', schema['entities'])
                self.assertNotIn('pull_request', schema['entities'])
                self.assertNotIn('agent_request', schema['entities'])
            else:
                self.assertIn('incident', schema['entities'])
            binary = Path(__import__('os').environ.get('ATLAS_E2E_RELA_BIN', str(Path.home() / '.local/share/atlas/test/bin'))) / 'rela'
            if binary.exists():
                assemble.subprocess.run([str(binary), '--project', str(target), '--quiet', 'validate'], check=True)

    def test_packaged_provenance_and_missing_inputs(self):
        assembled = assemble.build(self.root, self.manifest)
        dest = Path(self.tmp.name) / 'package'
        config.package(self.root, dest)
        verify(dest)
        (dest / 'modules/foundation/atlas.json').unlink()
        with self.assertRaises(OSError):
            verify(dest)
        (self.root / 'atlas.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'stale generated'):
            verify(self.root)

    def test_manifest_missing_unsafe_sources_and_unknown_keys(self):
        path = self.root / self.manifest
        original = assemble.read(path)
        for source in ['missing.json', '../outside.json']:
            changed = copy.deepcopy(original)
            changed['sources'] = [source]
            profiles.write(path, changed)
            with self.assertRaises((config.ConfigError, OSError)):
                assemble.build(self.root, self.manifest)
        changed = copy.deepcopy(original)
        changed['unknown'] = True
        profiles.write(path, changed)
        with self.assertRaisesRegex(config.ConfigError, 'unknown keys'):
            assemble.build(self.root, self.manifest)

    def test_incident_profile_refuses_populated_eyra_data(self):
        import contextlib, io, os
        incident = profiles.make('incident', Path(self.tmp.name) / 'incident')
        data = Path(self.tmp.name) / 'populated'
        config.package(self.root, data)
        (data / 'entities/scenes').mkdir(parents=True)
        file = data / 'entities/scenes/SC-Atlas-01.md'
        before = b'---\nid: SC-Atlas-01\ntype: scene\ntitle: Keep this existing work\n---\n'
        file.write_bytes(before)
        binary = Path(os.environ.get('ATLAS_E2E_RELA_BIN', str(Path.home() / '.local/share/atlas/test/bin'))) / 'rela'
        if not binary.exists():
            self.skipTest('pinned rela not installed')
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertFalse(config.fits(incident, data, str(binary)))
        self.assertIn('scenes', output.getvalue())
        self.assertEqual(file.read_bytes(), before)

    def test_both_image_recipes_package_matching_closure_without_facts(self):
        import shlex
        for part in ['entities', 'relations']:
            (self.root / part).mkdir(exist_ok=True)
            (self.root / part / 'private-fact.md').write_text('Never package this fact')
        for recipe in ['core', 'rela']:
            image = Path(self.tmp.name) / recipe
            # Exercise only COPY's repository-owned configuration inputs in the recipes.
            # verify() then detects missing schema/fragment/generated files in either app.
            instructions = (ROOT.parent / f'fly/{recipe}.Dockerfile').read_text().splitlines()
            for line in instructions:
                if not line.startswith('COPY rela/'):
                    continue
                *sources, target = shlex.split(line)[1:]
                target = image / target.lstrip('/')
                directory_target = str(line).endswith('/') or len(sources) > 1
                for source in sources:
                    src = self.root / Path(source).relative_to('rela')
                    dest = target / src.name if directory_target else target
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    if src.is_dir():
                        shutil.copytree(src, dest, dirs_exist_ok=True)
                    else:
                        shutil.copy(src, dest)
            verify(image / 'app/rela')
            self.assertTrue((image / 'app/rela/scripts/verify.py').exists())
            self.assertFalse((image / 'app/rela/entities').exists())
            self.assertFalse((image / 'app/rela/relations').exists())
