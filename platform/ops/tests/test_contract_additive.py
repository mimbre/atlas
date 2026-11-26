"""contract-additive.py warns about a contract change that is not additive (D-0105)."""
import importlib.util
import io
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('contract_additive', ROOT / 'platform/ops/contract-additive.py')
additive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(additive)


def contract(version, blocks, models=(), markup=()):
    return {"version": version, "blocks": list(blocks), "models": list(models), "markup": list(markup)}


def entry(name, *fields, deprecated=None):
    e = {"name": name, "fields": [dict(f) for f in fields]}
    if deprecated:
        e["deprecated"] = deprecated
    return e


def field(name, type="string", deprecated=None):
    f = {"name": name, "type": type, "required": False}
    if deprecated:
        f["deprecated"] = deprecated
    return f


class Additive(unittest.TestCase):
    def test_new_blocks_models_markup_and_fields_are_additive(self):
        before = contract("0.1.0", [entry("list", field("title"))])
        after = contract("0.2.0", [entry("list", field("title"), field("tone")), entry("chart")],
                         [entry("row", field("label"))], [entry("section")])
        self.assertEqual(additive.breaking(before, after), [])

    def test_removed_or_retyped_without_deprecation_is_named(self):
        before = contract("0.1.0", [entry("list", field("title"), field("rows", "list of row")),
                                    entry("chart")], [entry("row", field("label"))])
        after = contract("0.2.0", [entry("list", field("rows", "string"))], [])
        self.assertEqual(additive.breaking(before, after), [
            "block list: field title is removed without being deprecated first",
            "block list: field rows is now string, was list of row, without being deprecated first",
            "block chart is removed without being deprecated first",
            "model row is removed without being deprecated first",
        ])

    def test_what_the_published_version_deprecated_may_go(self):
        before = contract("0.1.0", [entry("list", field("title", deprecated="use heading")),
                                    entry("chart", field("x"), deprecated="use list")])
        after = contract("0.2.0", [entry("list", field("heading"))])
        self.assertEqual(additive.breaking(before, after), [])

    def test_it_warns_as_annotations_and_never_fails(self):
        before = contract("0.1.0", [entry("chart")])
        out = io.StringIO()
        found = additive.report(before, contract("0.2.0", []), out)
        self.assertEqual(len(found), 1)
        self.assertIn("::warning title=Contract change is not additive (D-0105)::block chart is removed",
                      out.getvalue())
        self.assertIn("Contract 0.1.0 → 0.2.0: not additive", out.getvalue())

    def test_the_contract_today_is_additive_to_itself(self):
        path = ROOT / 'platform/atlas_control/backend/targets/json/blocks.json'
        if not path.exists():
            self.skipTest("bin/generate atlas writes it")
        import json
        current = json.loads(path.read_text())
        self.assertEqual(additive.breaking(current, current), [])


if __name__ == '__main__':
    unittest.main()
