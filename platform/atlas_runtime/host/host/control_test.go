package host

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/eyra/atlas/platform/atlas_runtime/host/workspace"
)

// escapeeListingFailsEnv makes the host child's descendant listing fail (the seam is set before TestMain).
const escapeeListingFailsEnv = "ATLAS_TEST_ESCAPEE_LISTING_FAILS"

func init() {
	if os.Getenv(escapeeListingFailsEnv) == "1" {
		listDescendants = func(int) ([]descendant, error) { return nil, errors.New("injected listing failure") }
	}
}

// listingFailed is the one line a failing listing leaves in the turn log, however often it fails.
const listingFailed = "Native runner escapee warning: descendant listing failed: injected listing failure"

// escapeeLines are the host's escapee warnings in a turn's stderr.log.
func escapeeLines(t *testing.T, directory string) []string {
	t.Helper()
	log, err := os.ReadFile(filepath.Join(directory, "stderr.log"))
	if err != nil {
		t.Fatal(err)
	}
	var lines []string
	for _, line := range strings.Split(string(log), "\n") {
		if strings.HasPrefix(line, "Native runner escapee warning: ") {
			lines = append(lines, line)
		}
	}
	return lines
}

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

func alive(t *testing.T, pid int) bool {
	t.Helper()
	return processState(t, pid) == processLive
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
	if pid := readPID(t, native+".pid"); !alive(t, pid) {
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
	if !alive(t, child) {
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
	// detach kills a leader whose descendant called setsid, and returns that descendant, the turn folder,
	// the host and the escapee lines already in stderr.log when runtime.process_ended arrived.
	detach := func(t *testing.T) (int, string, *hostProcess, []string) {
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
		ended := next(t, records, 5*time.Second)
		// The host writes the escapee record before it emits the end. Reading the log on arrival catches a
		// record written later than the end, but not one written microseconds after it (a race the host wins).
		atEnd := escapeeLines(t, directory)
		rest, code := host.drain(t, records, group)
		rest = append([]map[string]any{ended}, rest...)
		if code != 0 || !slices.Equal(types(rest), []string{"runtime.process_ended"}) {
			t.Fatalf("code=%d records=%v", code, rest)
		}
		// An escapee or a failed listing never changes how the turn ends: the SIGKILLed leader's end.
		if ended["stopped"] != true || ended["control"] != "kill" || ended["exit_code"] != float64(-int(syscall.SIGKILL)) {
			t.Fatalf("the turn's end changed: %v", ended)
		}
		// Documented limit: the confirmed end covers the owned process group, not a new session.
		if !alive(t, detached) {
			t.Fatalf("expected the session-detached descendant %d to survive the group kill", detached)
		}
		if _, err := os.Stat(native + ".detached"); err != nil {
			t.Fatal(err)
		}
		return detached, directory, host, atEnd
	}
	detached, directory, host, atEnd := detach(t)
	// The survivor is recorded, once, in the turn log and on the host's stderr.
	want := fmt.Sprintf("Native runner escapee warning: process %d (pgid %d) left the turn's process group and survived the confirmed end", detached, detached)
	if lines := escapeeLines(t, directory); !slices.Equal(lines, []string{want}) || !strings.Contains(host.stderr.String(), want+"\n") {
		t.Fatalf("escapee not recorded once: stderr.log=%q host stderr=%q", lines, host.stderr.String())
	}
	if !slices.Equal(atEnd, []string{want}) {
		t.Fatalf("escapee not recorded before runtime.process_ended: %q", atEnd)
	}

	t.Run("a failed listing never blocks the end", func(t *testing.T) {
		t.Setenv(escapeeListingFailsEnv, "1")
		_, directory, _, atEnd := detach(t)
		if lines := escapeeLines(t, directory); !slices.Equal(lines, []string{listingFailed}) || !slices.Equal(atEnd, lines) {
			t.Fatalf("expected only the listing failure, before the end: %q (at the end: %q)", lines, atEnd)
		}
	})
}

func TestStopConfirmedRecordsNoEscapeeForInGroupDescendants(t *testing.T) {
	// stopThenKill stops a leader whose in-group child ignores the interrupt, then kills, and returns the turn folder.
	stopThenKill := func(t *testing.T) string {
		directory := t.TempDir()
		// sh ignores SIGINT in its asynchronous child: the leader stops and the child stays in the owned group.
		native := fixture(t, directory, `trap 'exit 0' INT
sleep 60 </dev/null >/dev/null 2>&1 &
echo $! > "$0.child"
printf '%s\n' '{"type":"ready"}'
while :; do sleep 0.1; done
`)
		host := startHost(t, codexArgs(native, directory))
		records := host.stream(t)
		group := started(t, records)
		next(t, records, 5*time.Second)
		child := readPID(t, native+".child")
		host.stdin.Write([]byte("stop\n"))
		if signal := next(t, records, 5*time.Second); signal["control"] != "stop" || signal["error"] != nil {
			t.Fatalf("stop not delivered: %v", signal)
		}
		quiet(t, records, time.Second)
		host.stdin.Write([]byte("kill\n"))
		if signal := next(t, records, 5*time.Second); signal["control"] != "kill" || signal["error"] != nil {
			t.Fatalf("kill not delivered: %v", signal)
		}
		rest, code := host.drain(t, records, group, child)
		if code != 0 || !slices.Equal(types(rest), []string{"runtime.process_ended"}) || rest[0]["control"] != "kill" {
			t.Fatalf("code=%d records=%v stderr=%s", code, rest, host.stderr.String())
		}
		assertDead(t, child)
		return directory
	}
	if lines := escapeeLines(t, stopThenKill(t)); len(lines) != 0 {
		t.Fatalf("in-group descendants recorded as escapees: %q", lines)
	}

	t.Run("a listing that fails at stop and at kill is recorded once", func(t *testing.T) {
		t.Setenv(escapeeListingFailsEnv, "1")
		if lines := escapeeLines(t, stopThenKill(t)); !slices.Equal(lines, []string{listingFailed}) {
			t.Fatalf("expected the listing failure once: %q", lines)
		}
	})
}

func TestDescendantWalkVisitsEachProcessOnce(t *testing.T) {
	// pid, ppid, pgid: 10 → 11 → 12 → 11 is a cycle through a reused pid; 13 is its own parent; 20 is unrelated.
	table := [][3]int{{11, 10, 11}, {12, 11, 11}, {11, 12, 11}, {10, 11, 10}, {13, 13, 13}, {20, 1, 20}}
	walked := make(chan []descendant, 1)
	go func() { walked <- descendantsIn(table, 10) }()
	select {
	case found := <-walked:
		if want := []descendant{{11, 11}, {12, 11}}; !slices.Equal(found, want) {
			t.Fatalf("descendants=%v, want %v", found, want)
		}
	case <-time.After(time.Second):
		t.Fatal("the walk did not return on a cyclic listing")
	}
}

// The darwin route reads the kernel table (the sandboxed worker cannot exec the setuid ps); Linux CI
// runs this, so the /bin/ps route and its parser are exercised against real processes.
func TestDescendantListingThroughBinPsOnLinux(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("the /bin/ps listing route is used on Linux; darwin reads the kernel process table")
	}
	table, err := psProcesses()
	if err != nil {
		t.Fatal(err)
	}
	self := [3]int{os.Getpid(), os.Getppid(), syscall.Getpgrp()}
	if !slices.Contains(table, self) {
		t.Fatalf("/bin/ps listing lacks this process as %v (pid, ppid, pgid): %d rows", self, len(table))
	}
	// A leader in its own group, with one child in that group and one that left it.
	directory := t.TempDir()
	command := exec.Command("/bin/sh", "-c", `sleep 30 & echo $! > "$0/inner"
'`+perlOrSkip(t)+`' -MPOSIX -e 'POSIX::setsid(); sleep 30' & echo $! > "$0/outer"
wait`, directory)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err = command.Start(); err != nil {
		t.Fatal(err)
	}
	leader := command.Process.Pid
	t.Cleanup(func() {
		syscall.Kill(-leader, syscall.SIGKILL)
		command.Wait()
	})
	inner, outer := 0, 0
	for deadline := time.Now().Add(5 * time.Second); ; time.Sleep(50 * time.Millisecond) {
		inner, outer = pidIn(filepath.Join(directory, "inner")), pidIn(filepath.Join(directory, "outer"))
		if found, _ := descendantsOf(leader); inner > 0 && outer > 0 && slices.Contains(found, descendant{outer, outer}) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("setsid child %d never listed with its own group", outer)
		}
	}
	t.Cleanup(func() { syscall.Kill(outer, syscall.SIGKILL) })
	found, err := descendantsOf(leader)
	if err != nil {
		t.Fatal(err)
	}
	slices.SortFunc(found, func(a, b descendant) int { return a.pid - b.pid })
	want := []descendant{{inner, leader}, {outer, outer}}
	slices.SortFunc(want, func(a, b descendant) int { return a.pid - b.pid })
	if !slices.Equal(found, want) {
		t.Fatalf("descendants of %d through /bin/ps = %v, want %v", leader, found, want)
	}
}

func perlOrSkip(t *testing.T) string {
	t.Helper()
	perl, err := exec.LookPath("perl")
	if err != nil {
		t.Skip("perl is needed to create a session-detached descendant")
	}
	return perl
}

// pidIn reads a pid a fixture wrote, or 0 while it is not written yet.
func pidIn(path string) int {
	data, _ := os.ReadFile(path)
	pid := 0
	fmt.Sscan(string(data), &pid)
	return pid
}
