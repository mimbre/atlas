package main

import (
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

var info = map[string]any{"runtime_build": "b1", "incarnation": "inc-1", "mode": "open", "policy_version": float64(3),
	"slots": []any{map[string]any{"name": "dev1", "busy": false}}}

// TestCLIProcess runs the CLI's main with ATLAS_TEST_CLI_ARGS (a JSON array) as its
// arguments, so a test sees what it prints and its exit code.
func TestCLIProcess(t *testing.T) {
	raw := os.Getenv("ATLAS_TEST_CLI_ARGS")
	if raw == "" {
		return
	}
	var args []string
	if err := json.Unmarshal([]byte(raw), &args); err != nil {
		os.Exit(3)
	}
	os.Args = append([]string{"atlas-runtime"}, args...)
	main()
	os.Exit(0)
}

// cli runs the CLI as a process against the Runtime home dir: its printed JSON and exit code.
func cli(t *testing.T, dir string, args ...string) (map[string]any, int) {
	t.Helper()
	encoded, _ := json.Marshal(args)
	cmd := exec.Command(os.Args[0], "-test.run=^TestCLIProcess$")
	cmd.Env = append(os.Environ(), "ATLAS_TEST_CLI_ARGS="+string(encoded), "ATLAS_RUNTIME_HOME="+dir)
	output, err := cmd.Output()
	code := 0
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		code = exit.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	var printed map[string]any
	if err := json.Unmarshal(output, &printed); err != nil {
		t.Fatalf("%q printed no JSON object: %s", args, output)
	}
	return printed, code
}

func TestOperationsCommandsSendTheContractRequest(t *testing.T) {
	policy := map[string]any{"version": float64(4), "buffer_size": float64(1), "profiles": []any{}}
	for _, test := range []struct {
		name  string
		args  []string
		reply map[string]any
		want  received
	}{
		{"service status", []string{"service", "status"}, info, received{method: "GET", path: "/v1/runtime"}},
		{"service pause", []string{"service", "pause"}, info, received{method: "POST", path: "/v1/control/pause"}},
		{"service resume", []string{"service", "resume"}, info, received{method: "POST", path: "/v1/control/resume"}},
		{"service drain", []string{"service", "drain"}, info, received{method: "POST", path: "/v1/control/drain"}},
		{"preferences", []string{"preferences"}, policy, received{method: "GET", path: "/v1/policy"}},
		{"preferences --reenable", []string{"preferences", "--reenable", "claude"}, map[string]any{},
			received{method: "POST", path: "/v1/harnesses/claude/clear-quota-mark"}},
		{"release", []string{"release", "--slot", "dev1"}, map[string]any{"slot": "dev1"},
			received{method: "POST", path: "/v1/slots/dev1/release"}},
		{"release escapes the slot", []string{"release", "--slot", "dev/1"}, map[string]any{"slot": "dev/1"},
			received{method: "POST", path: "/v1/slots/dev%2F1/release"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := socketDirectory(t)
			seen := backendServer(t, dir, http.StatusOK, test.reply)
			printed, code := cli(t, dir, test.args...)
			if code != 0 || !reflect.DeepEqual(printed, test.reply) {
				t.Fatalf("exit %d, printed %#v; want the answer as received", code, printed)
			}
			if len(*seen) != 1 || !reflect.DeepEqual((*seen)[0], test.want) {
				t.Fatalf("requests %#v, want one %#v", *seen, test.want)
			}
		})
	}
}

func TestOperationsRefusalsPrintTheProblemAndExitNonzero(t *testing.T) {
	for _, test := range []struct {
		name   string
		args   []string
		status int
		body   map[string]any
		error  string
	}{
		{"release of a live slot", []string{"release", "--slot", "dev1"}, 409,
			map[string]any{"type": "slot-busy", "title": "Conflict", "status": float64(409), "reason": "slot_busy"},
			"slot busy: dev1 still has a live process; release it after the process has ended (Runtime refused (HTTP 409 slot-busy): slot_busy)"},
		{"release of an unknown slot", []string{"release", "--slot", "nope"}, 404,
			map[string]any{"type": "not-found", "title": "Not Found", "status": float64(404)},
			"Runtime refused (HTTP 404 not-found): Not Found"},
		{"quota mark of an unknown harness", []string{"preferences", "--reenable", "nope"}, 404,
			map[string]any{"type": "not-found", "title": "Not Found", "status": float64(404)},
			"Runtime refused (HTTP 404 not-found): Not Found"},
		{"pause without the right", []string{"service", "pause"}, 403,
			map[string]any{"type": "not-permitted", "title": "Forbidden", "status": float64(403)},
			"Runtime refused (HTTP 403 not-permitted): Forbidden"},
		{"stop with a bad input", []string{"service", "stop"}, 400,
			map[string]any{"type": "invalid", "title": "Bad Request", "status": float64(400), "reason": "invalid"},
			"Runtime refused (HTTP 400 invalid): invalid"},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := socketDirectory(t)
			backendServer(t, dir, test.status, test.body)
			printed, code := cli(t, dir, test.args...)
			want := map[string]any{"error": test.error}
			for key, value := range test.body {
				want[key] = value
			}
			if code != 1 || !reflect.DeepEqual(printed, want) {
				t.Fatalf("exit %d, printed\n %#v\nwant\n %#v", code, printed, want)
			}
		})
	}
}

// stopServer answers POST /v1/control/stop on dir/backend.sock with 202 and the runtime info,
// as the Runtime does, and calls exit once with the request's body. runtime.sock is there too.
func stopServer(t *testing.T, dir string, exit func(body map[string]any, closeBackend func())) {
	t.Helper()
	command, err := net.Listen("unix", filepath.Join(dir, "runtime.sock"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { command.Close() })
	listener, err := net.Listen("unix", filepath.Join(dir, backendSocket))
	if err != nil {
		t.Fatal(err)
	}
	var server *httptest.Server
	server = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/control/stop" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		json.NewEncoder(w).Encode(map[string]any{"mode": "stopping", "incarnation": "inc-1"})
		// The process exits after the reply: runtime.sock goes first, backend.sock last.
		go exit(body, func() {
			command.Close()
			time.Sleep(300 * time.Millisecond)
			listener.Close()
		})
	}))
	server.Listener.Close()
	server.Listener = listener
	server.Start()
	t.Cleanup(server.Close)
}

func TestServiceStopReturnsOnlyOnceBackendSocketIsGone(t *testing.T) {
	for _, test := range []struct {
		args  []string
		force bool
	}{{[]string{"service", "stop"}, false}, {[]string{"service", "stop", "--force"}, true}} {
		t.Run(strings.Join(test.args, " "), func(t *testing.T) {
			dir := socketDirectory(t)
			t.Setenv("ATLAS_RUNTIME_HOME", dir)
			bodies := make(chan map[string]any, 1)
			stopServer(t, dir, func(body map[string]any, closeBackend func()) {
				bodies <- body
				closeBackend()
			})
			result, err := execute(test.args)
			if err != nil {
				t.Fatal(err)
			}
			if body := <-bodies; !reflect.DeepEqual(body, map[string]any{"force": test.force}) {
				t.Fatalf("stop body %#v", body)
			}
			// runtime.sock went 300 ms before backend.sock, whose listener unlinks it on close.
			if _, statErr := os.Stat(filepath.Join(dir, backendSocket)); !os.IsNotExist(statErr) {
				t.Fatal("service stop returned while backend.sock was still there")
			}
			if result["service"] != "stopped" || result["mode"] != "stopping" {
				t.Fatalf("result %#v", result)
			}
		})
	}
}

func TestServiceStopTimesOutNonzeroWhileBackendSocketAnswers(t *testing.T) {
	saved := stopWait
	stopWait = 300 * time.Millisecond
	t.Cleanup(func() { stopWait = saved })
	dir := socketDirectory(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	// runtime.sock goes; backend.sock stays.
	stopServer(t, dir, func(_ map[string]any, _ func()) {})
	os.Remove(filepath.Join(dir, "runtime.sock"))
	result, err := execute([]string{"service", "stop"})
	if err == nil || result != nil || !strings.Contains(err.Error(), "exit not confirmed: backend.sock still answers") {
		t.Fatalf("expected a timeout, got %#v, %v", result, err)
	}
}

func TestServiceOnAStoppedRuntimeReportsStopped(t *testing.T) {
	dir := socketDirectory(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	stopped := map[string]any{"service": "stopped"}
	// No backend.sock, then a socket file nobody listens on (a Runtime that was killed).
	for _, stale := range []bool{false, true} {
		if stale {
			listener, err := net.Listen("unix", filepath.Join(dir, backendSocket))
			if err != nil {
				t.Fatal(err)
			}
			listener.(*net.UnixListener).SetUnlinkOnClose(false)
			listener.Close()
		}
		for _, args := range [][]string{{"service", "status"}, {"service", "stop"}} {
			if result, err := execute(args); err != nil || !reflect.DeepEqual(result, stopped) {
				t.Fatalf("%q (stale socket %v): %#v, %v", args, stale, result, err)
			}
		}
		for _, args := range [][]string{{"service", "pause"}, {"preferences"}, {"release", "--slot", "dev1"}} {
			if _, err := execute(args); !errors.Is(err, errStopped) {
				t.Fatalf("%q (stale socket %v): %v", args, stale, err)
			}
		}
	}
}

func TestServiceStartChecksBackendSocket(t *testing.T) {
	saved := repoRoot
	repoRoot = ""
	t.Cleanup(func() { repoRoot = saved })

	// Already running: the runtime info, and nothing is built or started.
	dir := socketDirectory(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	seen := backendServer(t, dir, http.StatusOK, info)
	result, err := execute([]string{"service", "start"})
	if err != nil || !reflect.DeepEqual(result, info) || len(*seen) != 1 || (*seen)[0].path != "/v1/runtime" {
		t.Fatalf("running service: %#v, %v, %#v", result, err, *seen)
	}

	// A service that answers only on runtime.sock is never replaced.
	dir = socketDirectory(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	command, err := net.Listen("unix", filepath.Join(dir, "runtime.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer command.Close()
	if _, err = execute([]string{"service", "start"}); err == nil || !strings.Contains(err.Error(), "answers on runtime.sock but not on backend.sock") {
		t.Fatalf("expected a refusal, got %v", err)
	}
	if _, err = os.Stat(filepath.Join(dir, "runtime.sock")); err != nil {
		t.Fatalf("the live runtime.sock was removed: %v", err)
	}
	command.Close()

	// Nothing answers: the start goes ahead (and stops here, without the checkout location).
	if _, err = execute([]string{"service", "start"}); err == nil || err.Error() != "CLI was not built with the Atlas checkout location" {
		t.Fatalf("expected the start to proceed, got %v", err)
	}
}

func TestRemovedOperationFlagsNameTheReplacement(t *testing.T) {
	dir := socketDirectory(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	seen := backendServer(t, dir, http.StatusOK, map[string]any{"slot": "dev1"})
	for _, test := range []struct {
		args []string
		want string
	}{
		{[]string{"release", "--worker", "dev1"}, "use release --slot SLOT (--worker was removed)"},
		{[]string{"release", "--slot", "dev1", "--worker", "dev1"}, "use release --slot SLOT (--worker was removed)"},
		{[]string{"preferences", "--preferred", "claude", "--fallback", "codex"}, "edit policy.json"},
		{[]string{"preferences", "--preferred-model", "sonnet"}, "edit policy.json"},
		{[]string{"preferences", "--reenable", "claude", "--fallback", "codex"}, "edit policy.json"},
	} {
		t.Run(strings.Join(test.args, " "), func(t *testing.T) {
			printed, code := cli(t, dir, test.args...)
			if code != 1 || !strings.Contains(printed["error"].(string), test.want) {
				t.Fatalf("exit %d, printed %#v; want %q", code, printed, test.want)
			}
		})
	}
	if len(*seen) != 0 {
		t.Fatalf("a removed flag reached the Runtime: %#v", *seen)
	}
}

func TestOperationsArgumentShapes(t *testing.T) {
	t.Setenv("ATLAS_RUNTIME_HOME", t.TempDir())
	for _, test := range []struct {
		args []string
		want string
	}{
		{[]string{"service"}, serviceUsage},
		{[]string{"service", "restart"}, serviceUsage},
		{[]string{"service", "status", "--worker", "reviewer"}, serviceUsage},
		{[]string{"service", "pause", "now"}, serviceUsage},
		{[]string{"service", "stop", "now"}, serviceUsage},
		{[]string{"service", "stop", "--force=maybe"}, "invalid boolean value"},
		{[]string{"preferences", "claude"}, "does not accept positional arguments"},
		{[]string{"preferences", "--reenable="}, "use preferences --reenable HARNESS"},
		{[]string{"preferences", "--reenable"}, "flag needs an argument"},
		{[]string{"preferences", "--model", "sonnet"}, "flag provided but not defined"},
		{[]string{"release"}, "use release --slot SLOT"},
		{[]string{"release", "--slot="}, "use release --slot SLOT"},
		{[]string{"release", "--slot", "dev1", "extra"}, "unexpected arguments"},
		{[]string{"release", "--slot", "dev1", "--turn", "t"}, "flag provided but not defined"},
	} {
		t.Run(strings.Join(test.args, " "), func(t *testing.T) {
			result, err := execute(test.args)
			if err == nil || !strings.Contains(err.Error(), test.want) || result != nil {
				t.Fatalf("expected %q before any request, got %#v, %v", test.want, result, err)
			}
		})
	}
}
