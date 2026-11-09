"""No OS calls: the PID guard refuses before any native or /proc read."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('process_identity', ROOT/'tools/process_identity.py')
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


class ProcessIdentityTest(unittest.TestCase):
    def test_inspector_rejects_invalid_pid_domain_without_os_calls(self):
        for platform in ['darwin', 'linux']:
            for pid in [0, 1, -2, True, 2.0, '123', 2**31, 2**32+123, 10**10000]:
                with self.subTest(platform=platform, kind=type(pid).__name__), patch.object(identity.sys, 'platform', platform), patch.object(identity.ctypes, 'CDLL') as native, patch.object(Path, 'read_text', side_effect=AssertionError('OS read forbidden')):
                    with self.assertRaises(ValueError): identity.process_identity(pid)
                    with self.assertRaises(ValueError): identity.process_state(pid)
                    native.assert_not_called()

    def test_pid_records_are_bounded_decimal_text(self):
        self.assertEqual(identity.parse_pid(' 1234\n'), 1234)
        for record in [None, 1234, '', '1', '0', '-5', '12a', '١٢٣', '9' * 11, str(2**31)]:
            with self.subTest(record=record), self.assertRaises(ValueError):
                identity.parse_pid(record)


if __name__ == '__main__':
    unittest.main()
