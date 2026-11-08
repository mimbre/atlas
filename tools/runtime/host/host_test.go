package host

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/eyra/atlas/tools/runtime/workspace"
)

// The test binary doubles as the host, including its self-spawned pre-exec child,
// and as the fake native Claude CLI for question transport fixtures.
func TestMain(m *testing.M) {
	if os.Getenv("ATLAS_NATIVE_HOST_TEST") == "1" && len(os.Args) > 1 && os.Args[1] == "native-host" {
		Main(os.Args[2:])
	}
	if mode := os.Getenv("ATLAS_QUESTION_FIXTURE"); mode != "" {
		questionFixture(mode)
		os.Exit(0)
	}
	os.Exit(m.Run())
}

type hostProcess struct {
	command *exec.Cmd
	stdin   io.WriteCloser
	stdout  *bufio.Reader
	stderr  bytes.Buffer
	done    bool
}

func startHost(t *testing.T, args []string) *hostProcess {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	host := &hostProcess{command: exec.Command(self, append([]string{"native-host"}, args...)...)}
	host.command.Env = append(os.Environ(), "ATLAS_NATIVE_HOST_TEST=1")
	host.command.Stderr = &host.stderr
	if host.stdin, err = host.command.StdinPipe(); err != nil {
		t.Fatal(err)
	}
	stdout, err := host.command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	host.stdout = bufio.NewReader(stdout)
	if err = host.command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if !host.done {
			host.stdin.Close()
			io.Copy(io.Discard, host.stdout)
			host.command.Wait()
		}
	})
	return host
}

func (host *hostProcess) record(t *testing.T) map[string]any {
	t.Helper()
	line, err := host.stdout.ReadBytes('\n')
	if err != nil {
		t.Fatalf("host ended before a record: %v; stderr: %s", err, host.stderr.String())
	}
	var record map[string]any
	if err = json.Unmarshal(line, &record); err != nil {
		t.Fatalf("invalid host record %q: %v", line, err)
	}
	return record
}

// finish reads every remaining record, then reaps the host; stdin stays open unless the test closed it.
func (host *hostProcess) finish(t *testing.T) ([]map[string]any, int) {
	t.Helper()
	var records []map[string]any
	for {
		line, err := host.stdout.ReadBytes('\n')
		if err == io.EOF && len(line) == 0 {
			break
		}
		var record map[string]any
		if err != nil || json.Unmarshal(line, &record) != nil {
			t.Fatalf("invalid host record %q: %v", line, err)
		}
		records = append(records, record)
	}
	host.command.Wait()
	host.done = true
	host.stdin.Close()
	return records, host.command.ProcessState.ExitCode()
}

func fixture(t *testing.T, directory, body string) string {
	t.Helper()
	path := filepath.Join(directory, "native")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0700); err != nil {
		t.Fatal(err)
	}
	return path
}

// codexArgs is the Native argv for a read-only Codex start; tests override positions.
func codexArgs(native, directory string) []string {
	return []string{native, directory, directory, "fixture goal", "read-only", "", "null", "null", "codex", "null", "null", "false"}
}

func types(records []map[string]any) []string {
	var result []string
	for _, record := range records {
		result = append(result, record["type"].(string))
	}
	return result
}

func readPID(t *testing.T, path string) int {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	return pid
}

func processState(pid int) string {
	out, _ := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "stat=").Output()
	return strings.TrimSpace(string(out))
}

func assertDead(t *testing.T, pid int) {
	t.Helper()
	for range 200 {
		if state := processState(pid); state == "" || strings.HasPrefix(state, "Z") {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("owned descendant %d is still running", pid)
}

// waitZombie leaves the leader unreaped; the regressions need an exited, unreaped PID.
func waitZombie(t *testing.T, pid int) {
	t.Helper()
	for range 200 {
		if strings.HasPrefix(processState(pid), "Z") {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("owned leader %d did not become a zombie", pid)
}

func TestRecordsAreBoundedUniqueObjects(t *testing.T) {
	for _, line := range []string{`{"a":{"b":[1,{"c":2}]}}`, " {\"a\":1}\r", `{"a":1}` + strings.Repeat(" ", 25)} {
		if _, err := jsonRecord([]byte(line), 32); err != nil {
			t.Errorf("%q refused: %v", line, err)
		}
	}
	for line, message := range map[string]string{
		`{"a":1}` + strings.Repeat(" ", 26): "exceeds its size limit",
		`{"a":1,"a":2}`:                     "Duplicate JSON key",
		`{"a":{"b":1,"b":2}}`:               "Duplicate JSON key",
		`[{"a":1,"a":2}]`:                   "Duplicate JSON key",
		`{"a":1,"\u0061":2}`:                "Duplicate JSON key",
		`[]`:                                "must be an object",
		`"text"`:                            "must be an object",
		`null`:                              "must be an object",
		`{} {}`:                             "extra data",
		"{\"a\":\"\xff\"}":                  "not UTF-8",
		`{"a":`:                             "",
		``:                                  "",
	} {
		_, err := jsonRecord([]byte(line), 32)
		if err == nil || !strings.Contains(err.Error(), message) {
			t.Errorf("%q: wanted refusal containing %q, got %v", line, message, err)
		}
	}
}

func TestSessionRefusalKillsGroupBeforeForwarding(t *testing.T) {
	directory := t.TempDir()
	native := fixture(t, directory, `sleep 60 </dev/null >/dev/null 2>&1 &
echo $! > "$0.child"
printf '%s\n' '{"type":"thread.started","thread_id":"wrong-session"}' '{"type":"turn.completed"}'
sleep 60
`)
	args := codexArgs(native, directory)
	args[5] = "expected-session"
	started := time.Now()
	records, code := startHost(t, args).finish(t)
	if code != 1 || !slices.Equal(types(records), []string{"runtime.process_started"}) {
		t.Fatalf("refusal forwarded or completed: code=%d records=%v", code, records)
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("refusal waited for the native process: %v", elapsed)
	}
	stream, err := os.ReadFile(filepath.Join(directory, "stream.jsonl"))
	if err != nil || !bytes.Contains(stream, []byte("wrong-session")) {
		t.Fatalf("raw native stdout must be saved before parsing: %q, %v", stream, err)
	}
	assertDead(t, readPID(t, native+".child"))
}

func TestSessionRefusalDiagnostic(t *testing.T) {
	directory := t.TempDir()
	native := fixture(t, directory, `printf '%s\n' '{"type":"thread.started","thread_id":"wrong-session"}'`+"\nsleep 60\n")
	args := codexArgs(native, directory)
	args[5] = "expected-session"
	host := startHost(t, args)
	host.finish(t)
	if diagnostic := host.stderr.String(); diagnostic != "Native runner: Codex did not confirm the requested session\n" {
		t.Fatalf("unexpected host diagnostic %q", diagnostic)
	}
}

func TestInvalidModelsNeverLaunchNative(t *testing.T) {
	for _, model := range []string{`""`, `"--dangerously-skip-permissions"`, `"opus --tools Bash"`, `"opus\nx"`,
		`"opus;touch /tmp/injected"`, `"` + strings.Repeat("x", 201) + `"`, "1", `["opus"]`} {
		t.Run(model, func(t *testing.T) {
			directory := t.TempDir()
			native := fixture(t, directory, "touch \"$0.executed\"\n")
			args := codexArgs(native, directory)
			args[3], args[9] = "--prompt stays one argument", model
			if err := run(args); err == nil || err.Error() != "Model must be a nonempty identifier of at most 200 characters" {
				t.Fatalf("wanted the model refusal, got %v", err)
			}
			for _, path := range []string{native + ".executed", filepath.Join(directory, "stderr.log")} {
				if _, err := os.Stat(path); err == nil {
					t.Fatalf("%s exists: validation must precede launch and every artifact", path)
				}
			}
		})
	}
}

func TestStopInterruptsGroupAndReportsStopped(t *testing.T) {
	for _, mode := range []string{"byte", "eof"} {
		t.Run(mode, func(t *testing.T) {
			directory := t.TempDir()
			native := fixture(t, directory, `trap 'touch "$0.interrupted"; exit 0' INT
printf '%s\n' '{"type":"ready"}'
while :; do sleep 0.1; done
`)
			host := startHost(t, codexArgs(native, directory))
			if record := host.record(t); record["type"] != "runtime.process_started" {
				t.Fatalf("first record %v", record)
			}
			if record := host.record(t); record["type"] != "runtime.event" {
				t.Fatalf("native event not forwarded: %v", record)
			}
			if mode == "byte" {
				host.stdin.Write([]byte("x"))
			} else {
				host.stdin.Close()
			}
			records, code := host.finish(t)
			ended := records[len(records)-1]
			if code != 0 || ended["type"] != "runtime.process_ended" || ended["stopped"] != true || ended["exit_code"] != 0.0 {
				t.Fatalf("stop did not end cleanly: code=%d records=%v stderr=%s", code, records, host.stderr.String())
			}
			if _, err := os.Stat(native + ".interrupted"); err != nil {
				t.Fatalf("stop must interrupt the native group first: %v", err)
			}
		})
	}
}

func TestIgnoredInterruptEscalatesToGroupKill(t *testing.T) {
	directory := t.TempDir()
	native := fixture(t, directory, `trap '' INT
printf '%s\n' '{"type":"ready"}'
exec sleep 60
`)
	host := startHost(t, codexArgs(native, directory))
	host.record(t)
	host.record(t)
	started := time.Now()
	host.stdin.Write([]byte("stop\n"))
	records, code := host.finish(t)
	ended := records[len(records)-1]
	if code != 0 || ended["stopped"] != true || ended["exit_code"] != -9.0 {
		t.Fatalf("ignored interrupt not escalated: code=%d records=%v", code, records)
	}
	if elapsed := time.Since(started); elapsed < 3*time.Second || elapsed > 8*time.Second {
		t.Fatalf("escalation outside the 3 s bound: %v", elapsed)
	}
}

func TestExitCodesFollowLeaderAfterStdoutEOF(t *testing.T) {
	for _, test := range []struct {
		name, body string
		code       float64
		minimum    time.Duration
	}{
		{"signalled exit is negative", "printf '%s\\n' '{\"type\":\"turn.completed\"}'\nkill -KILL $$\n", -9, 0},
		{"clean exit after EOF is not killed", "exec >&-\nsleep 1\nexit 0\n", 0, time.Second},
		{"leader stuck after EOF is killed", "exec >&-\nexec sleep 60\n", -9, 3 * time.Second},
	} {
		t.Run(test.name, func(t *testing.T) {
			directory := t.TempDir()
			started := time.Now()
			records, code := startHost(t, codexArgs(fixture(t, directory, test.body), directory)).finish(t)
			ended := records[len(records)-1]
			if code != 0 || ended["type"] != "runtime.process_ended" || ended["exit_code"] != test.code || ended["stopped"] != false {
				t.Fatalf("code=%d records=%v", code, records)
			}
			if time.Since(started) < test.minimum {
				t.Fatalf("leader was not given its exit window")
			}
		})
	}
}

// isolatedHome mirrors the workspace tests: no inherited Git or Codex configuration.
func isolatedHome(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range os.Environ() {
		if name, _, _ := strings.Cut(entry, "="); strings.HasPrefix(name, "GIT_") {
			t.Setenv(name, "")
			os.Unsetenv(name)
		}
	}
	t.Setenv("HOME", root)
	t.Setenv("CODEX_HOME", filepath.Join(root, ".codex"))
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	return root
}

func gitIn(t *testing.T, directory string, args ...string) string {
	t.Helper()
	out, err := exec.Command("git", append([]string{"-C", directory, "-c", "user.name=Test", "-c", "user.email=test@example.invalid"}, args...)...).CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func dedicatedRepository(t *testing.T) (string, map[string]any) {
	t.Helper()
	repository := filepath.Join(isolatedHome(t), "repo")
	if out, err := exec.Command("git", "init", "-q", repository).CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, out)
	}
	scope, err := workspace.Scope(repository)
	if err != nil {
		t.Fatal(err)
	}
	return repository, scope
}

func scopedArgs(t *testing.T, native, repository, folder string, scope map[string]any) []string {
	t.Helper()
	encoded, err := json.Marshal(scope)
	if err != nil {
		t.Fatal(err)
	}
	args := codexArgs(native, repository)
	args[2], args[4], args[6] = folder, "", string(encoded)
	return args
}

func TestPreExecRefusalGoesToTurnStderrAndNeverExecutes(t *testing.T) {
	repository, scope := dedicatedRepository(t)
	folder := t.TempDir()
	native := fixture(t, folder, "touch \"$0.executed\"\n")
	scope["network_hosts"] = []string{"example.com"}
	host := startHost(t, scopedArgs(t, native, repository, folder, scope))
	records, code := host.finish(t)
	if code != 0 || !slices.Equal(types(records), []string{"runtime.process_started", "runtime.process_ended"}) ||
		records[1]["exit_code"] != 1.0 || records[1]["stopped"] != false {
		t.Fatalf("code=%d records=%v stderr=%s", code, records, host.stderr.String())
	}
	diagnostic, err := os.ReadFile(filepath.Join(folder, "stderr.log"))
	if err != nil || string(diagnostic) != "Native runner: Dedicated repository permission scope changed\n" {
		t.Fatalf("pre-exec refusal must reach stderr.log: %q, %v", diagnostic, err)
	}
	if host.stderr.Len() != 0 {
		t.Fatalf("pre-exec refusal leaked to host stderr: %s", host.stderr.String())
	}
	if _, err = os.Stat(native + ".executed"); err == nil {
		t.Fatal("native CLI executed despite a changed scope")
	}
}

func TestScopedLaunchKeepsLeaderPIDAndHoldsLockUntilReaped(t *testing.T) {
	repository, scope := dedicatedRepository(t)
	folder := t.TempDir()
	native := fixture(t, folder, `echo $$ > "$0.pid"
sleep 60 </dev/null >/dev/null 2>&1 &
echo $! > "$0.child"
printf '%s\n' '{"type":"ready"}'
wait
`)
	host := startHost(t, scopedArgs(t, native, repository, folder, scope))
	started := host.record(t)
	if event := host.record(t); event["type"] != "runtime.event" {
		t.Fatalf("native event not forwarded: %v", event)
	}
	if pid := readPID(t, native+".pid"); started["pid"] != float64(pid) {
		t.Fatalf("native %d must keep the group leader PID %v", pid, started["pid"])
	}
	if lock, _, err := workspace.Lock(repository, false); err == nil || !strings.Contains(err.Error(), "active Runtime owner") {
		if lock != nil {
			lock.Close()
		}
		t.Fatalf("running group must own the repository: %v", err)
	}
	host.stdin.Close()
	records, code := host.finish(t)
	if code != 0 || records[len(records)-1]["stopped"] != true {
		t.Fatalf("code=%d records=%v stderr=%s", code, records, host.stderr.String())
	}
	assertDead(t, readPID(t, native+".child"))
	lock, _, err := workspace.Lock(repository, false)
	if err != nil {
		t.Fatalf("lock not released after the group was reaped: %v", err)
	}
	lock.Close()
}

func TestManagedRepositoryIsPreparedBeforeNativeEventsAndContinues(t *testing.T) {
	home := isolatedHome(t)
	source := filepath.Join(home, "source")
	gitIn(t, home, "init", "-q", "-b", "develop", source)
	gitIn(t, source, "commit", "--allow-empty", "-qm", "base")
	url := "https://github.com/test/fixture.git"
	var response bytes.Buffer
	if err := workspace.Run([]string{"request", filepath.Join(home, "runtime"), url, "task/first"}, &response); err != nil {
		t.Fatal(err)
	}
	var request struct {
		Permissions map[string]any `json:"permissions"`
		Repository  map[string]any `json:"repository"`
	}
	if err := json.Unmarshal(response.Bytes(), &request); err != nil {
		t.Fatal(err)
	}
	root := request.Permissions["root"].(string)
	folder := t.TempDir()
	// As Codex's sandbox prefix, run Git in -C over a local transport; otherwise act as Codex.
	native := fixture(t, folder, `if [ "$1" = sandbox ]; then
  while [ "$1" != -C ]; do shift; done
  cd "$2" || exit 1
  while [ "$1" != -- ]; do shift; done
  shift 2
  case " $* " in *" clone "*|*" fetch "*) exec git -c "url.file://`+source+`.insteadOf=`+url+`" "$@" ;; esac
  exec git "$@"
fi
printf '%s\n' '{"type":"thread.started","thread_id":"native-session"}' '{"type":"turn.completed"}'
`)
	launch := func(session string, repository map[string]any) []map[string]any {
		encoded, err := json.Marshal(repository)
		if err != nil {
			t.Fatal(err)
		}
		args := scopedArgs(t, native, root, folder, request.Permissions)
		args[5], args[7] = session, string(encoded)
		host := startHost(t, args)
		records, code := host.finish(t)
		want := []string{"runtime.process_started", "runtime.repository_prepared", "runtime.event", "runtime.event", "runtime.process_ended"}
		if code != 0 || !slices.Equal(types(records), want) || records[4]["exit_code"] != 0.0 {
			stderr, _ := os.ReadFile(filepath.Join(folder, "stderr.log"))
			t.Fatalf("code=%d records=%v host=%s turn=%s", code, records, host.stderr.String(), stderr)
		}
		return records
	}

	base := gitIn(t, source, "rev-parse", "HEAD")
	records := launch("", request.Repository)
	prepared := records[1]["repository"].(map[string]any)
	if prepared["base_sha"] != base || gitIn(t, root, "branch", "--show-current") != "task/first" {
		t.Fatalf("fresh task branch not prepared at the fetched base: %v", prepared)
	}

	unfinished := filepath.Join(root, "unfinished.txt")
	if err := os.WriteFile(unfinished, []byte("keep this work\n\x00\xff"), 0600); err != nil {
		t.Fatal(err)
	}
	gitIn(t, source, "commit", "--allow-empty", "-qm", "new remote base")
	records = launch("native-session", prepared)
	if continued := records[1]["repository"].(map[string]any); continued["base_sha"] != base {
		t.Fatalf("continuation changed the saved repository: %v", continued)
	}
	if data, err := os.ReadFile(unfinished); err != nil || string(data) != "keep this work\n\x00\xff" || gitIn(t, root, "rev-parse", "HEAD") != base {
		t.Fatalf("continuation lost unfinished work: %q %v", data, err)
	}
	lock, _, err := workspace.Lock(root, false)
	if err != nil {
		t.Fatalf("lock not released: %v", err)
	}
	lock.Close()
}

func launchGroup(t *testing.T, command *exec.Cmd) *process {
	t.Helper()
	if command.SysProcAttr == nil {
		command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	leader := &process{pid: command.Process.Pid}
	t.Cleanup(func() {
		syscall.Kill(-leader.pid, syscall.SIGKILL)
		leader.wait(-1)
	})
	return leader
}

func TestSignallingUnreapedExitedLeaderSucceeds(t *testing.T) {
	leader := launchGroup(t, exec.Command("/bin/sh", "-c", "exit 0"))
	waitZombie(t, leader.pid)
	if err := leader.signalGroup(syscall.SIGKILL); err != nil {
		t.Fatalf("exited leader masked cleanup: %v", err)
	}
	if exited, err := leader.wait(5 * time.Second); !exited || err != nil || leader.code() != 0 {
		t.Fatalf("leader exit lost: %v %v %d", exited, err, leader.code())
	}
}

func TestExitedLeaderDoesNotExemptLiveDescendants(t *testing.T) {
	command := exec.Command("/bin/sh", "-c", "sleep 60 </dev/null >/dev/null 2>&1 & echo $!")
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	leader := launchGroup(t, command)
	line, err := bufio.NewReader(stdout).ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	child, err := strconv.Atoi(strings.TrimSpace(line))
	if err != nil {
		t.Fatal(err)
	}
	waitZombie(t, leader.pid)
	if err := leader.signalGroup(syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	if exited, _ := leader.wait(5 * time.Second); !exited || leader.code() != 0 {
		t.Fatalf("leader exit lost: %d", leader.code())
	}
	assertDead(t, child)
}

func denySignals(t *testing.T) {
	t.Helper()
	kill = func(int, syscall.Signal) error { return syscall.EPERM }
	t.Cleanup(func() { kill = syscall.Kill })
}

func TestDeniedSignalToLiveLeaderFailsWithinBound(t *testing.T) {
	leader := launchGroup(t, exec.Command("/bin/sleep", "10"))
	denySignals(t) // injected denial; never signal a foreign process for a real EPERM
	started := time.Now()
	if err := leader.signalGroup(syscall.SIGKILL); err != syscall.EPERM {
		t.Fatalf("denial must stay a permission failure: %v", err)
	}
	if elapsed := time.Since(started); elapsed > 6*time.Second {
		t.Fatalf("denial wait unbounded: %v", elapsed)
	}
	if leader.exited {
		t.Fatal("permission failure must not claim the leader exited")
	}
}

func TestPersistentDenialAfterReapingIsNotCleanupSuccess(t *testing.T) {
	leader := launchGroup(t, exec.Command("/bin/sh", "-c", "exit 0"))
	waitZombie(t, leader.pid)
	denySignals(t) // injected: the second denial after reaping must stay visible
	if err := leader.signalGroup(syscall.SIGKILL); err != syscall.EPERM {
		t.Fatalf("second denial hidden: %v", err)
	}
	if !leader.exited || leader.code() != 0 {
		t.Fatal("owned leader must still be reaped")
	}
}
