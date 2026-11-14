import copy
"""Native extraction/operational regressions against the delivered #79 baseline."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('config', ROOT / 'scripts/config.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


def without_ledger(schema):
    """The schema without the decision ledger, gate verdicts, use case design phase and To-Dos, added since #79."""
    schema = copy.deepcopy(schema)
    schema['entities'].pop('decision')
    schema['entities'].pop('gate_verdict')
    for name in ('decided_by', 'delegated_by', 'supersedes', 'follows_from', 'based_on', 'follows', 'overruled_by', 'reviewed_by', 'about'):
        schema['relations'].pop(name)
    schema['relations']['assignment']['from'].remove('decision')
    for name in ('decision_category', 'decision_scope', 'decision_reversibility', 'decision_force', 'decision_status', 'design_status', 'gate_flavor', 'gate_purpose', 'gate_unsettled'):
        schema.get('types', {}).pop(name, None)
    for name in ('design', 'design_status'):
        schema['entities']['use_case']['properties'].pop(name)
    # The fields the flows (flows.yaml) read and write, and the review and test of a pull request.
    for kind in ('pr_review', 'pr_test'):
        schema['entities'].pop(kind)
    for name in ('review_of', 'test_of', 'verdict_by'):
        schema['relations'].pop(name)
    flow_fields = {
        'issue': ('pass_result', 'gate_result', 'effect_result', 'pr_outcome'),
        'pull_request': ('review_outcome', 'test_outcome', 'update', 'integration', 'revision'),
        'scene': ('children', 'open_children', 'verdict', 'pass_result'),
        'use_case': ('children', 'open_children', 'verdict', 'pass_result', 'gate_result'),
    }
    for kind, names in flow_fields.items():
        for name in names:
            schema['entities'][kind]['properties'].pop(name)
    # The To-Do: work no flow covers, assigned like any item.
    schema['entities'].pop('to_do')
    schema['types'].pop('to_do_status')
    schema['relations']['assignment']['from'].remove('to_do')
    # What a turn is about and the model it runs, for the worker page.
    for name in ('title', 'model'):
        assert not schema['entities']['turn']['properties'].pop(name).get('required', False)
    return schema


class SchemaTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'source'
        shutil.copytree(ROOT, self.root)

    def test_equivalence_and_property_order(self):
        baseline = yaml.load((ROOT / 'tests/fixtures/baseline-schema.yaml').read_text(), Loader=config.StrictLoader)
        _, resolved = config.closure(self.root)
        self.assertEqual(list(resolved['entities']['flow_run']['properties']), 'flow subject_kind subject_key generation definition_sha256 state entry entered_at status deadlines pending input_cursor last_input blocked_reason'.split())
        self.assertEqual(list(resolved['entities']['flow_input']['properties']), 'request_id run flow subject_kind subject_key generation entry source_version subject_version actor roles changed_fields links payload_digest status position prepared_at applied_at'.split())
        prior = without_ledger(resolved)
        for kind in ('worker_execution', 'interaction', 'interaction_receipt'):
            self.assertIn(kind, prior['entities'])
            del prior['entities'][kind]
        self.assertFalse(prior['entities']['turn']['properties'].pop('attempt').get('required', False))
        self.assertEqual(prior, baseline)
        self.assertEqual(resolved['relations']['turn_on']['label'], 'on')
        for name, entity in baseline['entities'].items():
            self.assertEqual([p for p in prior['entities'][name]['properties'] if not (name == 'turn' and p == 'attempt')], list(entity['properties']))

    def test_package_and_include_only_change(self):
        dest = Path(self.tmp.name) / 'data'
        config.package(self.root, dest)
        self.assertTrue(config.same(self.root, dest))
        included = dest / 'modules/foundation/schema.yaml'
        included.write_text(included.read_text() + '\n# an included file changed\n')
        self.assertFalse(config.same(self.root, dest))
        included.unlink()
        with self.assertRaises(FileNotFoundError):
            config.same(self.root, dest)

    def test_invalid_closure(self):
        root = self.root / 'schema.yaml'
        original = root.read_text()
        for suffix in ['\nunknown: {}\n', '\nincludes: []\n']:
            root.write_text(original + suffix)
            with self.assertRaises(config.ConfigError):
                config.closure(self.root)
        for includes in [['../escape.yaml'], ['missing.yaml'], ['cycle.yaml']]:
            root.write_text(yaml.safe_dump({'includes': includes}))
            (self.root / 'cycle.yaml').write_text('includes: [schema.yaml]\n')
            with self.assertRaises((config.ConfigError, FileNotFoundError)):
                config.closure(self.root)
        root.write_text('includes: [modules/foundation/schema.yaml]\nentities:\n  turn: {}\n')
        with self.assertRaisesRegex(config.ConfigError, 'duplicate entities.turn'):
            config.closure(self.root)
        root.write_text('includes: [partial.yaml]\n')
        (self.root / 'partial.yaml').write_text('flows: {}\n')
        with self.assertRaisesRegex(config.ConfigError, 'unknown keys'):
            config.closure(self.root)

    def test_scan_errors_fail_closed(self):
        binary = Path(self.tmp.name) / 'rela'
        binary.write_text('#!/bin/sh\ncase "$*" in *validate*) exit 0;; *) exit 2;; esac\n')
        binary.chmod(0o755)
        with self.assertRaises(config.subprocess.CalledProcessError):
            config.fits(self.root, Path(self.tmp.name) / 'empty', str(binary))

class NativeSchemaTest(unittest.TestCase):
    """Use only disposable stores and the already installed pinned CLI/server."""
    @classmethod
    def setUpClass(cls):
        import os
        # As e2e's AtlasE2E.Instance.rela_bin!/0: ATLAS_E2E_RELA_BIN, ATLAS_RELA_BIN, the
        # rela-bin folder beside the checkout when it holds rela-server, else the test instance's.
        beside = Path(__file__).resolve().parents[2].parent / 'rela-bin'
        named = os.environ.get('ATLAS_E2E_RELA_BIN') or os.environ.get('ATLAS_RELA_BIN')
        folder = Path(named) if named else beside if (beside / 'rela-server').exists() \
            else Path.home() / '.local/share/atlas/test/bin'
        cls.binary = folder / 'rela'
        if not cls.binary.exists():
            raise unittest.SkipTest('pinned rela not installed')

    def test_removed_populated_fields_and_relations_are_refused_without_data_changes(self):
        import subprocess
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / 'data'
            source = Path(tmp) / 'source'
            shutil.copytree(ROOT, source)
            config.package(ROOT, data)
            # Direct markdown fixtures: no user data or server involved.
            (data / 'entities/people').mkdir(parents=True)
            (data / 'entities/people/tester.md').write_text('---\nid: tester\ntype: person\nname: Tester\nobsolete: preserved\n---\n')
            (data / 'relations').mkdir()
            (data / 'relations/a--removed_link--b.md').write_text('untouched historical relation\n')
            before = {str(p.relative_to(data)): p.read_bytes() for p in data.rglob('*') if p.is_file()}
            import contextlib, io
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertFalse(config.fits(source, data, str(self.binary)))
            self.assertIn('obsolete', output.getvalue())
            self.assertIn('removed_link', output.getvalue())
            self.assertEqual(before, {str(p.relative_to(data)): p.read_bytes() for p in data.rglob('*') if p.is_file()})

    def test_native_resolved_http_schema_and_form_order_equal_baseline(self):
        import json, socket, subprocess, time, urllib.request
        def read_schema(root):
            with socket.socket() as s:
                s.bind(('127.0.0.1', 0))
                port = s.getsockname()[1]
            process = subprocess.Popen([str(self.binary.parent / 'rela-server'), '-project', str(root), '-bind', '127.0.0.1', '-port', str(port), '-quiet'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    try:
                        with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/v1/_schema', timeout=1) as r:
                            return json.load(r)
                    except OSError:
                        if process.poll() is not None:
                            self.fail('rela-server failed')
                        time.sleep(.05)
                self.fail('private rela did not answer')
            finally:
                process.terminate()
                process.wait(timeout=5)
        with tempfile.TemporaryDirectory() as tmp:
            old, new = Path(tmp) / 'old', Path(tmp) / 'new'
            config.package(ROOT, new)
            old.mkdir()
            shutil.copy(ROOT / 'tests/fixtures/baseline-schema.yaml', old / 'schema.yaml')
            shutil.copy(ROOT / 'data-entry.yaml', old / 'data-entry.yaml')
            baseline, current = read_schema(old), read_schema(new)
            previous = without_ledger(current)
            for kind in ('worker_execution', 'interaction', 'interaction_receipt'):
                del previous['entities'][kind]
            previous['entities']['turn']['properties'].pop('attempt')
            self.assertEqual(previous, baseline)
            for kind, entity in baseline['entities'].items():
                self.assertEqual([p for p in previous['entities'][kind]['properties'] if not (kind == 'turn' and p == 'attempt')], list(entity['properties']))

    def test_flat_fly_preflight_on_previous_image(self):
        import os, subprocess
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'next'
            (root / 'scripts').mkdir(parents=True)
            (root / 'schema.yaml').write_text(yaml.safe_dump(config.closure(ROOT)[1], sort_keys=False))
            shutil.copy(ROOT / 'data-entry.yaml', root / 'data-entry.yaml')
            shutil.copy(ROOT.parent / 'fly/check-fits.sh', root / 'scripts/description.sh')
            data = Path(tmp) / 'data'
            (data / 'entities/people').mkdir(parents=True)
            (data / 'entities/people/tester.md').write_text('---\nid: tester\ntype: person\nname: Tester\n---\n')
            env = dict(os.environ, ATLAS_RELA_DATA=str(data), ATLAS_RELA_BIN=str(self.binary.parent))
            result = subprocess.run(['bash', str(root / 'scripts/description.sh'), 'fits'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
