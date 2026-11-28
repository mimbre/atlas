"""CI and local worktrees must use the same Elixir formatter release."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]


class CIToolchain(unittest.TestCase):
    def test_every_setup_beam_uses_the_worktree_elixir_patch(self):
        versions = dict(line.split(maxsplit=1) for line in
                        (ROOT / '.tool-versions').read_text().splitlines() if line.strip())
        local = versions['elixir'].split('-otp-', 1)[0]
        self.assertRegex(local, r'^\d+\.\d+\.\d+$')
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        setups = re.findall(
            r'(?ms)^      - uses: erlef/setup-beam@\S+\n(.*?)(?=^      - |\Z)',
            workflow,
        )
        self.assertTrue(setups)
        for setup in setups:
            if 'version-file: .tool-versions' in setup:
                self.assertRegex(setup, r'(?m)^\s*version-type: strict\s*$')
            else:
                self.assertRegex(setup, rf'(?m)^\s*elixir-version: "{re.escape(local)}"\s*$')


if __name__ == '__main__':
    unittest.main()
