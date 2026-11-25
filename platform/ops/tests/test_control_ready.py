"""control-ready.py says hello with the version the Control contract's source declares."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('control_ready', ROOT / 'platform/ops/control-ready.py')
control_ready = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control_ready)
CONTRACT = ROOT / 'platform/atlas_control/backend/contract/lib/contract.ex'


class ContractVersion(unittest.TestCase):
    def test_reads_the_version_the_contract_declares(self):
        version = control_ready.contract_version(CONTRACT.read_text())
        self.assertRegex(version, r'^\d+\.\d+\.\d+$')
        self.assertIn(f'version "{version}"', CONTRACT.read_text())

    def test_a_source_without_a_version_is_refused(self):
        with self.assertRaises(ValueError):
            control_ready.contract_version('defmodule X do\n  # version "1.0.0"\nend\n')


if __name__ == '__main__':
    unittest.main()
