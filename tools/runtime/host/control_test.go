package host

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/eyra/atlas/tools/runtime/workspace"
)

// stream reads every host record in the background, so tests can assert that none arrives in time.
func (host *hostProcess) stream(t *testing.T) <-chan map[string]any {
	t.Helper()
	records := make(chan map[string]any, 64)
	go func() {
		defer close(records)
		for {
			line, err := host.stdout.ReadBytes('\n')
			if len(line) > 0 {
				var record map[string]any
				if json.Unmarshal(line, &record) != nil {
					record = map[string]any{"type": "invalid", "line": string(line)}
				}
				records <- record
			}
			if err != nil {
				return
			}
		}
	}()
	return records
}

func next(t *testing.T, records <-chan map[string]any, within time.Duration) map[string]any {
	t.Helper()
	select {
	case record, ok := <-records:
		if !ok {
			t.Fatal("host ended before the expected record")
		}
		return record
	case <-time.After(within):
		t.Fatalf("no host record within %v", within)
	}
	return nil
}

func quiet(t *testing.T, records <-chan map[string]any, during time.Duration) {
	t.Helper()
	select {
	case record, ok := <-records:
		t.Fatalf("expected no host record, got %v (open=%v)", record, ok)
	case <-time.After(during):
	}
}

// started reads the host's process_started record and returns the owned group it reports.
func started(t *testing.T, records <-chan map[string]any) int {
	t.Helper()
	record := next(t, records, 5*time.Second)
	// A zero group would make kill(-group) address the test's own process group.
	if pid, _ := record["pid"].(float64); record["type"] == "runtime.process_started" && pid > 0 {
		return int(pid)
	}
	t.Fatalf("expected runtime.process_started, got %v", record)
	return 0
}

// drain collects the remaining records, then reaps the host. A host still running after 8 s
// fails with evidence about the owned group and descendants instead of hanging.
func (host *hostProcess) drain(t *testing.T, records <-chan map[string]any, group int, descendants ...int) ([]map[string]any, int) {
	t.Helper()
	var rest []map[string]any
	expired := time.After(8 * time.Second)
	for records != nil {
		select {
		case record, ok := <-records:
			if !ok {
				records = nil
			} else {
				rest = append(rest, record)
			}
		case <-expired:
			host.abandon(t, rest, group, descendants)
		}
	}
	host.command.Wait()
	host.done = true
	host.stdin.Close()
	return rest, host.command.ProcessState.ExitCode()
}

// abandon separates a live group member from a refused group probe, re-interrupts each owned
// descendant to show whether its handler is installed now, then kills the owned group and host.
func (host *hostProcess) abandon(t *testing.T, rest []map[string]any, group int, descendants []int) {
	t.Helper()
	report := []string{fmt.Sprintf("records=%v", rest),
		fmt.Sprintf("group %d probe: %v", group, syscall.Kill(-group, 0)),
		fmt.Sprintf("leader %d probe: %v", group, syscall.Kill(group, 0))}
	for _, pid := range descendants {
		before, after := syscall.Kill(pid, 0), error(nil)
		if before == nil {
			syscall.Kill(pid, syscall.SIGINT)
			for range 100 {
				if after = syscall.Kill(pid, 0); after != nil {
					break
				}
				time.Sleep(20 * time.Millisecond)
			}
		}
		report = append(report, fmt.Sprintf("descendant %d probe: %v, probe 2 s after a second SIGINT: %v", pid, before, after))
	}
	report = append(report, fmt.Sprintf("group SIGKILL: %v", syscall.Kill(-group, syscall.SIGKILL)))
	host.command.Process.Kill()
	host.command.Wait()
	host.done = true
	t.Fatalf("host did not end within 8 s: %s; stderr=%s", strings.Join(report, "; "), host.stderr.String())
}

func alive(pid int) bool {
	state := processState(pid)
	return state != "" && !strings.HasPrefix(state, "Z")
}

func TestIgnoredInterruptStaysStoppingUntilExplicitKill(t *testing.T) {
	directory := t.TempDir()
	native := fixture(t, directory, `trap '' INT
echo $$ > "$0.pid"
printf '%s\n' '{"type":"ready"}'
exec sleep 60
`)
	host := startHost(t, codexArgs(native, directory))
	records := host.stream(t)
	group := started(t, records)
	next(t, records, 5*time.Second)
	host.stdin.Write([]byte("stop\nstop\n"))
	if signal := next(t, records, 5*time.Second); signal["control"] != "stop" || signal["signal"] != "SIGINT" || signal["error"] != nil {
		t.Fatalf("stop not delivered once: %v", signal)
	}
	// Past the former 3 s escalation: still running, no second interrupt, no end.
	quiet(t, records, 4*time.Second)
	if pid := readPID(t, native+".pid"); !alive(pid) {
		t.Fatalf("stop escalated: native %d is gone", pid)
	}
	host.stdin.Write([]byte("stop\n"))
	quiet(t, records, 300*time.Millisecond)
	started := time.Now()
	host.stdin.Write([]byte("kill\nkill\nstop\n"))
	if signal := next(t, records, 5*time.Second); signal["control"] != "kill" || signal["signal"] != "SIGKILL" || signal["error"] != nil {
		t.Fatalf("kill not delivered: %v", signal)
	}
	rest, code := host.drain(t, records, group)
	if code != 0 || len(rest) != 1 || rest[0]["type"] != "runtime.process_ended" || rest[0]["exit_code"] != -9.0 ||
		rest[0]["stopped"] != true || rest[0]["control"] != "kill" {
		t.Fatalf("kill did not end once: code=%d records=%v stderr=%s", code, rest, host.stderr.String())
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("kill was not immediate: %v", elapsed)
	}
}

func TestStopAfterNativeOutputEndsNeverEscalates(t *testing.T) {
	directory := t.TempDir()
	// The completion path: native stdout closes while its leader keeps running and ignores SIGINT.
	native := fixture(t, directory, `trap '' INT
printf '%s\n' '{"type":"ready"}'
exec >&-
exec sleep 60
`)
	host := startHost(t, codexArgs(native, directory))
	records := host.stream(t)
	group := started(t, records)
	next(t, records, 5*time.Second)
	time.Sleep(200 * time.Millisecond)
	host.stdin.Write([]byte("stop\n"))
	if signal := next(t, records, 5*time.Second); signal["control"] != "stop" {
		t.Fatalf("stop not delivered: %v", signal)
	}
	quiet(t, records, 4*time.Second)
	host.stdin.Write([]byte("kill\n"))
	next(t, records, 5*time.Second)
	rest, code := host.drain(t, records, group)
	if code != 0 || len(rest) != 1 || rest[0]["exit_code"] != -9.0 || rest[0]["control"] != "kill" {
		t.Fatalf("code=%d records=%v stderr=%s", code, rest, host.stderr.String())
	}
}

func TestStopWaitsForDescendantsAndKeepsLockUntilKill(t *testing.T) {
	repository, scope := dedicatedRepository(t)
	folder := t.TempDir()
	// sh ignores SIGINT in its asynchronous child, so the leader stops and the child stays.
	native := fixture(t, folder, `trap 'exit 0' INT
sleep 60 </dev/null >/dev/null 2>&1 &
echo $! > "$0.child"
printf '%s\n' '{"type":"ready"}'
while :; do sleep 0.1; done
`)
	host := startHost(t, scopedArgs(t, native, repository, folder, scope))
	records := host.stream(t)
	group := started(t, records)
	next(t, records, 5*time.Second)
	child := readPID(t, native+".child")
	host.stdin.Write([]byte("stop\n"))
	next(t, records, 5*time.Second)
	quiet(t, records, 3500*time.Millisecond)
	if !alive(child) {
		t.Fatalf("stop escalated to descendant %d", child)
	}
	if lock, _, err := workspace.Lock(repository, false); err == nil || !strings.Contains(err.Error(), "active Runtime owner") {
		if lock != nil {
			lock.Close()
		}
		t.Fatalf("lock released while a descendant still runs: %v", err)
	}
	host.stdin.Write([]byte("kill\n"))
	if signal := next(t, records, 5*time.Second); signal["control"] != "kill" || signal["error"] != nil {
		t.Fatalf("kill not delivered: %v", signal)
	}
	rest, code := host.drain(t, records, group, child)
	if code != 0 || len(rest) != 1 || rest[0]["control"] != "kill" || rest[0]["exit_code"] != 0.0 {
		t.Fatalf("code=%d records=%v stderr=%s", code, rest, host.stderr.String())
	}
	assertDead(t, child)
	lock, _, err := workspace.Lock(repository, false)
	if err != nil {
		t.Fatalf("lock not released after the group was confirmed gone: %v", err)
	}
	lock.Close()
}

func TestCooperativeDescendantsEndStopWithoutKill(t *testing.T) {
	perl, err := exec.LookPath("perl")
	if err != nil {
		t.Skip("perl is needed for a descendant that installs its own SIGINT handler")
	}
	directory := t.TempDir()
	// sh starts an asynchronous child with SIGINT ignored; perl reinstalls a handler, so one interrupt ends
	// the group. Ready waits for the child's PID, which perl publishes only after installing that handler.
	native := fixture(t, directory, `trap 'exit 0' INT
'`+perl+`' -e '$SIG{INT} = sub { exit 0 }; open(my $f, ">", "$ARGV[0].tmp") or die; print $f $$; close($f); rename("$ARGV[0].tmp", $ARGV[0]) or die; select(undef, undef, undef, 0.1) while 1' "$0.child" </dev/null >/dev/null 2>&1 &
while [ ! -s "$0.child" ]; do sleep 0.05; done
printf '%s\n' '{"type":"ready"}'
while :; do sleep 0.1; done
`)
	host := startHost(t, codexArgs(native, directory))
	records := host.stream(t)
	group := started(t, records)
	next(t, records, 5*time.Second)
	child := readPID(t, native+".child")
	host.stdin.Write([]byte("stop\n"))
	next(t, records, 5*time.Second)
	rest, code := host.drain(t, records, group, child)
	if code != 0 || len(rest) != 1 || rest[0]["control"] != "stop" || rest[0]["exit_code"] != 0.0 {
		t.Fatalf("code=%d records=%v stderr=%s", code, rest, host.stderr.String())
	}
	assertDead(t, child)
}

func TestAcceptedStopKeepsUndecodedProviderOutputRaw(t *testing.T) {
	directory := t.TempDir()
	// After the interrupt the provider writes an invalid line and unterminated JSON, then exits cleanly.
	native := fixture(t, directory, `trap 'printf "%s\n%s" "not json" "{\"type\":\"item.completed\",\"ite"; exit 0' INT
printf '%s\n' '{"type":"ready"}'
while :; do sleep 0.1; done
`)
	host := startHost(t, codexArgs(native, directory))
	records := host.stream(t)
	group := started(t, records)
	next(t, records, 5*time.Second)
	host.stdin.Write([]byte("stop\n"))
	if signal := next(t, records, 5*time.Second); signal["control"] != "stop" || signal["signal"] != "SIGINT" || signal["error"] != nil {
		t.Fatalf("stop not delivered: %v", signal)
	}
	rest, code := host.drain(t, records, group)
	if code != 0 || len(rest) != 1 || rest[0]["type"] != "runtime.process_ended" || rest[0]["control"] != "stop" ||
		rest[0]["exit_code"] != 0.0 {
		t.Fatalf("code=%d records=%v stderr=%s", code, rest, host.stderr.String())
	}
	stream, err := os.ReadFile(filepath.Join(directory, "stream.jsonl"))
	if err != nil || !bytes.HasSuffix(stream, []byte("not json\n{\"type\":\"item.completed\",\"ite")) {
		t.Fatalf("undecoded provider output was not kept raw: %q, %v", stream, err)
	}
}

func TestDetachedDescendantLeavesOwnedGroup(t *testing.T) {
	perl, err := exec.LookPath("perl")
	if err != nil {
		t.Skip("perl is needed to create a session-detached descendant")
	}
	directory := t.TempDir()
	native := fixture(t, directory, `'`+perl+`' -MPOSIX -e 'POSIX::setsid(); open(my $f, ">", "$ARGV[0].detached"); print $f $$; close($f); sleep 30' "$0" </dev/null >/dev/null 2>&1 &
while [ ! -s "$0.detached" ]; do sleep 0.05; done
printf '%s\n' '{"type":"ready"}'
exec sleep 60
`)
	host := startHost(t, codexArgs(native, directory))
	records := host.stream(t)
	group := started(t, records)
	next(t, records, 5*time.Second)
	detached := readPID(t, native+".detached")
	t.Cleanup(func() { syscall.Kill(detached, syscall.SIGKILL) })
	host.stdin.Write([]byte("kill\n"))
	next(t, records, 5*time.Second)
	rest, code := host.drain(t, records, group)
	if code != 0 || !slices.Equal(types(rest), []string{"runtime.process_ended"}) {
		t.Fatalf("code=%d records=%v", code, rest)
	}
	// Documented limit: the confirmed end covers the owned process group, not a new session.
	if !alive(detached) {
		t.Fatalf("expected the session-detached descendant %d to survive the group kill", detached)
	}
	if _, err := os.Stat(native + ".detached"); err != nil {
		t.Fatal(err)
	}
}
