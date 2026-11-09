"""ensure_tunnel keeps a shared tunnel whose port accepts; fakes only, no network, no timers."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

# Sources bin/lib/tunnel.sh, starts a stand-in for the open proxy, then replaces what
# touches the network or the clock. FAKE_PORT: `open` (the port always accepts) or
# `reopened` (it accepts only once the fake fly has started a new proxy).
# FAKE_PROXY_DIES: the stand-in dies during the third probe. ensure_tunnel runs in a
# subshell so that its exit status is the script's.
SCRIPT = r'''
set -euo pipefail
root="$TUNNEL_ROOT"; prog=atlas; env=test; fly_app=app-under-test; port=7693; fly_port=7691
. "$root/bin/lib/tunnel.sh"
sleep 300 & original=$!
echo "$original" >"$(tunnel_pidfile)"
sleep() { :; }
listening() {
  [ "$FAKE_PORT" = open ] || [ -f "$ATLAS_TEST_ROOT/fly-args" ]
}
control_ready() {
  echo "${1:-default}" >>"$ATLAS_TEST_ROOT/probes"
  if [ -f "$ATLAS_TEST_ROOT/fly-args" ]; then return 0; fi
  if [ "$FAKE_PROXY_DIES" = 1 ] && [ "$(wc -l <"$ATLAS_TEST_ROOT/probes")" -eq 3 ]; then
    kill "$original"; wait "$original" || true
  fi
  probe_error="Control is not reachable: Control handshake timed out"
  return 1
}
fly_cli() { echo "$FAKE_FLY"; }
status=0
( ensure_tunnel ) || status=$?
if kill -0 "$original" 2>/dev/null && [ "$(cat "$(tunnel_pidfile)" 2>/dev/null)" = "$original" ]; then
  echo original-kept
  kill "$original"
else
  echo original-stopped
  kill "$(cat "$(tunnel_pidfile)" 2>/dev/null)" 2>/dev/null || true
fi
exit "$status"
'''


class TunnelReuseTest(unittest.TestCase):
    def run_tunnel(self, port, proxy_dies=False):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        state = Path(temporary.name)
        fly = state / 'fly'
        fly.write_text('#!/bin/sh\necho "$@" >"$ATLAS_TEST_ROOT/fly-args"\nexec sleep 300\n')
        fly.chmod(0o755)
        env = dict(os.environ, TUNNEL_ROOT=str(ROOT), ATLAS_TEST_ROOT=str(state),
                   FAKE_FLY=str(fly), FAKE_PORT=port, FAKE_PROXY_DIES='1' if proxy_dies else '0')
        result = subprocess.run(['bash', '-c', SCRIPT], env=env, text=True,
                                capture_output=True, timeout=20)
        probes = (state / 'probes').read_text().split()
        fly_args = (state / 'fly-args').read_text().split() if (state / 'fly-args').exists() else None
        return result, probes, fly_args

    def test_a_slow_probe_on_an_accepting_port_keeps_the_tunnel(self):
        result, probes, fly_args = self.run_tunnel('open')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'original-kept')
        self.assertEqual(probes, ['10', '10', '10'])
        self.assertIsNone(fly_args)
        self.assertNotEqual(result.stderr.strip(), '')

    def test_a_dead_proxy_is_not_kept_while_its_port_still_accepts(self):
        result, probes, fly_args = self.run_tunnel('open', proxy_dies=True)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'original-stopped')
        self.assertEqual(probes, ['10', '10', '10'])
        self.assertIsNone(fly_args)

    def test_a_port_that_no_longer_accepts_is_reopened(self):
        result, probes, fly_args = self.run_tunnel('reopened')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'original-stopped')
        # Three 10 s probes of the old tunnel, then the new tunnel's loop with the default 3 s.
        self.assertEqual(probes, ['10', '10', '10', 'default'])
        self.assertEqual(fly_args, ['proxy', '7693:7691', '-a', 'app-under-test', '-q'])


if __name__ == '__main__':
    unittest.main()
