#!/usr/bin/env bash
# The pull-e2e's wrapper (plan rev 2 §10; review round 1), run by `bin/atlas-dev pull-e2e`
# from products/software_factory/e2e:
#   1. compile once, before the timed run, into the warm cache (`--prepare`; Main's ruling);
#   2. make the run folder and run the test BEAM in it, with TMPDIR inside;
#   3. reap on every way out, and keep the reap's verdict (F4):
#      - a signal (atlas-heavy's timeout): the BEAM is TERMed (then KILLed) first, so nothing
#        races the reaper, then a KILL-only reap and its proof (`--reap --fast`);
#      - any exit: the same fast reap (a proof only, when the BEAM reaped already).
#      A reap whose proof found something left makes the exit 5 and prints
#      "pull-e2e: LEAK" whatever the other status was.
# Every child of the BEAMs is tethered: it ends with them. It never sleeps; it waits for the BEAMs.
set -uo pipefail

run=""
pid=""
# PULL_E2E_TRACE (a test's file) records what the trap does, in order.
trace() { if [ -n "${PULL_E2E_TRACE:-}" ]; then echo "$1" >>"$PULL_E2E_TRACE"; fi; }

reap() {
  [ -n "$run" ] || return 0
  local tmp="${TMPDIR:-/tmp}"
  [ -d "$run/tmp" ] && tmp="$run/tmp"
  TMPDIR="$tmp" mix atlas.pull_e2e --reap "$run" --fast
}
verdict() {
  if [ "$1" -eq 5 ]; then echo "pull-e2e: LEAK: the reap's proof found what was left of $run" >&2; exit 5; fi
  exit "$2"
}
on_signal() {
  trap - EXIT INT TERM
  trace beam-term
  if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; fi
  reap
  verdict $? 143
}
trap on_signal INT TERM
trap 'status=$?; trap - EXIT; reap; verdict $? $status' EXIT

mix atlas.pull_e2e --prepare &
pid=$!
wait "$pid" || exit $?

run="$(cd "$(mktemp -d "${PULL_E2E_RUN_PARENT:-/tmp}/pe.XXXXXX")" && pwd -P)"
mkdir -p "$run/tmp"
TMPDIR="$run/tmp" mix atlas.pull_e2e --run "$run" "$@" &
pid=$!
wait "$pid"
