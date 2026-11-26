import copy
"""Native extraction/operational regressions against the delivered #79 baseline."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
import yaml
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
# The Rela project the scripts serve: the product's generated description (bin/generate model
# writes it before these tests run).
PROJECT = ROOT.parents[2] / 'products/software_factory/model/targets/rela'
spec = importlib.util.spec_from_file_location('config', ROOT / 'scripts/config.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


def fits(root, data, binary, check=False):
    with tempfile.TemporaryDirectory() as tmp:
        proposed = Path(tmp)
        (proposed / 'schema.yaml').write_text(yaml.safe_dump(config.closure(root)[1], sort_keys=False))
        shutil.copy(root / 'data-entry.yaml', proposed / 'data-entry.yaml')
        return subprocess.run(['bash', str(ROOT / 'scripts/fits.sh'), str(proposed), str(data)],
                              env=dict(os.environ, ATLAS_RELA_BIN=str(Path(binary).parent)),
                              capture_output=True, text=True, check=check)


class SchemaTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'source'
        shutil.copytree(PROJECT, self.root)

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
        data = Path(self.tmp.name) / 'empty'
        data.mkdir()
        with self.assertRaises(subprocess.CalledProcessError) as error:
            fits(self.root, data, str(binary), check=True)
        self.assertEqual(error.exception.returncode, 2)

class NativeSchemaTest(unittest.TestCase):
    """Use only disposable stores and the already installed pinned CLI/server."""
    @classmethod
    def setUpClass(cls):
        import os
        # As e2e's AtlasE2E.Instance.rela_bin!/0: ATLAS_E2E_RELA_BIN, ATLAS_RELA_BIN, the
        # rela-bin folder beside the checkout when it holds rela-server-headless-sqlite, else the test instance's.
        beside = Path(__file__).resolve().parents[4].parent / 'rela-bin'
        named = os.environ.get('ATLAS_E2E_RELA_BIN') or os.environ.get('ATLAS_RELA_BIN')
        folder = Path(named) if named else beside if (beside / 'rela-server-headless-sqlite').exists() \
            else Path.home() / '.local/share/atlas/test/bin'
        cls.binary = folder / 'rela'
        if not cls.binary.exists():
            raise unittest.SkipTest('pinned rela not installed')

    def test_removed_populated_fields_and_relations_are_refused_without_data_changes(self):
        import subprocess
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / 'data'
            source = Path(tmp) / 'source'
            shutil.copytree(PROJECT, source)
            config.package(PROJECT, data)
            # Direct markdown fixtures: no user data or server involved.
            (data / 'entities/people').mkdir(parents=True)
            (data / 'entities/people/tester.md').write_text('---\nid: tester\ntype: person\nname: Tester\nobsolete: preserved\n---\n')
            (data / 'relations').mkdir()
            (data / 'relations/a--removed_link--b.md').write_text('untouched historical relation\n')
            before = {str(p.relative_to(data)): p.read_bytes() for p in data.rglob('*') if p.is_file()}
            result = fits(source, data, str(self.binary))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('obsolete', result.stdout + result.stderr)
            self.assertIn('removed_link', result.stdout + result.stderr)
            self.assertEqual(before, {str(p.relative_to(data)): p.read_bytes() for p in data.rglob('*') if p.is_file()})

    def test_removed_empty_field_passes_and_rela_gc_removes_it_after_deploy(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / 'data'
            config.package(PROJECT, data)
            (data / 'entities/people').mkdir(parents=True)
            # As Facts clears a field: the key stays, holding null (or nothing).
            (data / 'entities/people/a.md').write_text('---\nid: a\ntype: person\nname: A\nstep: null\n---\n')
            (data / 'entities/people/b.md').write_text('---\nid: b\ntype: person\nname: B\nstep: ""\n---\n')
            result = fits(PROJECT, data, str(self.binary))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('person.step (empty, removed after deploy)', result.stdout)
            env = dict(os.environ, ATLAS_RELA_DATA=str(data), ATLAS_RELA_BIN=str(self.binary.parent))
            gc = subprocess.run(['bash', str(ROOT / 'scripts/description.sh'), 'gc', 'person.step'],
                                env=env, capture_output=True, text=True)
            self.assertEqual(gc.returncode, 0, gc.stdout + gc.stderr)
            self.assertIn('deleted person.step', gc.stdout)
            for name in ('a', 'b'):
                text = (data / f'entities/people/{name}.md').read_text()
                self.assertNotIn('step', text)
                self.assertIn('name: ', text)

    def test_removed_field_with_a_value_still_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / 'data'
            config.package(PROJECT, data)
            (data / 'entities/people').mkdir(parents=True)
            (data / 'entities/people/a.md').write_text('---\nid: a\ntype: person\nname: A\nstep: null\n---\n')
            (data / 'entities/people/b.md').write_text('---\nid: b\ntype: person\nname: B\nstep: review\n---\n')
            result = fits(PROJECT, data, str(self.binary))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('person.step\n', result.stdout)
            self.assertNotIn('empty, removed after deploy', result.stdout)
            env = dict(os.environ, ATLAS_RELA_DATA=str(data), ATLAS_RELA_BIN=str(self.binary.parent))
            gc = subprocess.run(['bash', str(ROOT / 'scripts/description.sh'), 'gc'],
                                env=env, capture_output=True, text=True)
            self.assertNotEqual(gc.returncode, 0)
            self.assertIn('step: review', (data / 'entities/people/b.md').read_text())

    def test_flat_fly_preflight_on_previous_image(self):
        import os, subprocess
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'next'
            (root / 'scripts').mkdir(parents=True)
            (root / 'schema.yaml').write_text(yaml.safe_dump(config.closure(PROJECT)[1], sort_keys=False))
            shutil.copy(PROJECT / 'data-entry.yaml', root / 'data-entry.yaml')
            shutil.copy(ROOT.parents[2] / 'platform/ops/check-fits.sh', root / 'scripts/description.sh')
            for name in ('data.sh', 'fits.sh'):
                shutil.copy(ROOT / 'scripts' / name, root / 'scripts' / name)
            data = Path(tmp) / 'data'
            (data / 'entities/people').mkdir(parents=True)
            (data / 'entities/people/tester.md').write_text('---\nid: tester\ntype: person\nname: Tester\n---\n')
            env = dict(os.environ, ATLAS_RELA_DATA=str(data), ATLAS_RELA_BIN=str(self.binary.parent))
            result = subprocess.run(['bash', str(root / 'scripts/description.sh'), 'fits'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
