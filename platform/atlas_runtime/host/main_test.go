package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// socketDirectory is a fresh Runtime home under TMPDIR for runtime.sock. It skips when the socket
// path would not fit macOS's 104-byte sockaddr_un path, terminating NUL included.
func socketDirectory(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "atlas-rt-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	if socket := filepath.Join(dir, "runtime.sock"); len(socket)+1 > 104 {
		t.Skipf("socket path %s exceeds the 104-byte sockaddr_un limit; use a shorter TMPDIR", socket)
	}
	return dir
}

func TestFailedTurnIsInspectableButCommandRefusalFails(t *testing.T) {
	for _, test := range []struct {
		name           string
		response       map[string]any
		commandFailure bool
	}{
		{"failed turn", map[string]any{"state": "failed", "id": "turn-1", "error": "runner exited 7"}, false},
		{"command refused", map[string]any{"command_error": "agent already active"}, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := socketDirectory(t)
			listener, err := net.Listen("unix", filepath.Join(dir, "runtime.sock"))
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			served := make(chan error, 1)
			go func() {
				conn, err := listener.Accept()
				if err != nil {
					served <- err
					return
				}
				defer conn.Close()
				var command map[string]any
				if err = json.NewDecoder(conn).Decode(&command); err == nil {
					err = json.NewEncoder(conn).Encode(test.response)
				}
				served <- err
			}()
			result, err := request(dir, map[string]any{"command": "status"})
			if test.commandFailure {
				if err == nil {
					t.Fatal("command refusal must fail the invocation")
				}
			} else {
				if err != nil {
					t.Fatalf("failed turn must remain inspectable: %v", err)
				}
				if result["state"] != "failed" || result["error"] != "runner exited 7" || result["id"] != "turn-1" {
					t.Fatalf("failed-turn context was lost: %#v", result)
				}
			}
			if err := <-served; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestExecuteRejectsInvalidEventsBeforeSocketRequest(t *testing.T) {
	t.Setenv("ATLAS_RUNTIME_HOME", t.TempDir())
	for _, test := range []struct {
		name string
		args []string
		want string
	}{
		{"zero limit", []string{"--limit", "0"}, "limit must be between 1 and 100"},
		{"negative limit", []string{"--limit=-1"}, "limit must be between 1 and 100"},
		{"above maximum", []string{"--limit", "101"}, "limit must be between 1 and 100"},
		{"noninteger limit", []string{"--limit", "1.5"}, "invalid value"},
		{"overflow limit", []string{"--limit", "999999999999999999999999"}, "invalid value"},
		{"empty limit", []string{"--limit="}, "invalid value"},
		{"missing limit", []string{"--limit"}, "flag needs an argument"},
		{"empty cursor", []string{"--cursor", ""}, "cursor must be nonempty"},
		{"empty cursor equals", []string{"--cursor="}, "cursor must be nonempty"},
		{"missing cursor", []string{"--cursor"}, "flag needs an argument"},
		{"positional", []string{"extra"}, "does not accept positional arguments"},
		{"trailing positional", []string{"--limit", "50", "extra"}, "does not accept positional arguments"},
		{"positional after separator", []string{"--", "extra"}, "does not accept positional arguments"},
		{"unknown flag", []string{"--unknown"}, "flag provided but not defined"},
		{"follow with limit", []string{"--follow", "--limit", "50"}, "does not accept --limit"},
		{"follow with empty cursor", []string{"--follow", "--cursor="}, "cursor must be nonempty"},
	} {
		t.Run(test.name, func(t *testing.T) {
			result, err := execute(append([]string{"events"}, test.args...))
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("expected argument refusal %q, got result %#v, error %v", test.want, result, err)
			}
			if result != nil {
				t.Fatalf("invalid request returned a result: %#v", result)
			}
		})
	}
}

func TestExecuteRejectsInvalidWorkerTargetsBeforeSocketRequest(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	for _, command := range []string{"question", "answer", "handoff"} {
		for _, worker := range []string{"", " ", "Reviewer", "1reviewer", "-reviewer", "_reviewer", "../reviewer", "reviewer/name", "réviewer", "reviewer\n", strings.Repeat("a", 65)} {
			t.Run(command+"/"+worker, func(t *testing.T) {
				if _, err := execute([]string{command, "--worker=" + worker}); err == nil || !strings.Contains(err.Error(), "worker must match") {
					t.Fatalf("expected worker refusal before request, got %v", err)
				}
			})
		}
	}
	for _, test := range []struct {
		args []string
		want string
	}{
		{[]string{"pause", "--worker", "reviewer"}, "unknown command"},
		{[]string{"resume", "--worker", "reviewer"}, "unknown command"},
		{[]string{"turns", "--worker", "reviewer"}, "unexpected arguments"},
		{[]string{"events", "--worker", "reviewer"}, "flag provided but not defined"},
		{[]string{"service", "status", "--worker", "reviewer"}, "use service"},
	} {
		t.Run(strings.Join(test.args, " "), func(t *testing.T) {
			if _, err := execute(test.args); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("expected %q before request, got %v", test.want, err)
			}
		})
	}
}

func TestAnswersRejectAmbiguousOrUnboundedInput(t *testing.T) {
	for _, raw := range []string{
		`null`, `[]`, `{}`, `{"q":null}`, `{"q":1}`, `{"q":[]}`, `{"q":{}}`,
		`{"q":""}`, `{"q":" "}`, `{" ":"answer"}`, `{"q":"a","q":"b"}`,
		`{"q":"a","\u0071":"b"}`, `{"q":"a"} {"q":"b"}`, `{"q":"a",}`,
		`{"a":"1","b":"2","c":"3","d":"4","e":"5"}`,
		`{"q":"` + strings.Repeat("x", 4097) + `"}`,
		`{"` + strings.Repeat("x", 4097) + `":"answer"}`,
		`{"q":"` + strings.Repeat("é", 2049) + `"}`,
		`{"q":"answer"}` + strings.Repeat(" ", 16384),
		"{\"q\":\"\xff\"}",
	} {
		if _, err := parseAnswers(raw); err == nil {
			t.Fatalf("invalid answer input accepted: %.80q", raw)
		}
	}
	answers, err := parseAnswers(`{"Which number?":"436849","Which text?":"quote \" and newline\n"}`)
	if err != nil || len(answers) != 2 || answers["Which number?"] != "436849" ||
		answers["Which text?"] != "quote \" and newline\n" {
		t.Fatalf("answer text changed: %#v, %v", answers, err)
	}
	long := strings.Repeat("x", 4096)
	answers, err = parseAnswers(`{"` + long + `":"` + long + `"}`)
	if err != nil || answers[long] != long {
		t.Fatalf("valid byte boundary refused: %v", err)
	}
}

func TestAnswerRequiresEveryTargetAndRejectsCapabilityChanges(t *testing.T) {
	t.Setenv("ATLAS_RUNTIME_HOME", t.TempDir())
	for _, args := range [][]string{
		{"answer", "--turn", "turn-1", "--question", "question-1", "--answers", `{"q":"a"}`},
		{"answer", "--worker", "server", "--question", "question-1", "--answers", `{"q":"a"}`},
		{"answer", "--worker", "server", "--turn", "turn-1", "--answers", `{"q":"a"}`},
		{"answer", "--worker", "server", "--turn", "turn-1", "--question", "question-1"},
		{"answer", "--worker", "server", "--turn", "turn-1", "--question", "question-1", "--answers", `{"q":"a"}`, "extra"},
		{"answer", "--worker", "server", "--turn", "turn-1", "--question", "question-1", "--answers", `{"q":"a"}`, "--permissions", "dedicated-repository"},
		{"question", "--turn", "turn-1", "--question", "question-1"},
		{"question", "--worker", "server", "--question", "question-1"},
		{"question", "--worker", "server", "--turn", "turn-1"},
		{"question", "--worker", "server", "--turn", "turn-1", "--question", "question-1", "--answers", `{"q":"a"}`},
		{"question", "--worker", "server", "--turn", "turn-1", "--question", "question-1", "extra"},
		{"continue", "--questions", "next"},
		{"start", "--backend", "codex", "--questions", "--cwd", ".", "next"},
	} {
		if _, err := execute(args); err == nil || strings.Contains(err.Error(), "Runtime service is stopped") {
			t.Fatalf("invalid answer/capability arguments reached socket: %q, %v", args, err)
		}
	}
}

func TestHandoffRejectsAmbiguousOrUnboundedJSON(t *testing.T) {
	for _, raw := range []string{
		"", "null", "[]", "{}", `{"kind":"completion","kind":"completion"}`,
		`{"kind":"completion","\u006bind":"completion"}`, `{"kind":`,
		`{"kind":"completion"} {}`, "{\"result\":\"\xff\"}",
		`{"result":"` + strings.Repeat("x", 32768) + `"}`,
	} {
		if _, err := parseHandoff(raw); err == nil {
			t.Fatalf("accepted ambiguous or unbounded handoff: %.100q", raw)
		}
	}
}

func TestHandoffRequiresExactTargetAndExplicitSubmission(t *testing.T) {
	t.Setenv("ATLAS_RUNTIME_HOME", t.TempDir())
	for _, args := range [][]string{
		{"handoff", "--turn", "turn-1"},
		{"handoff", "--worker", "server"},
		{"handoff", "--worker", "server", "--turn", "turn-1", "extra"},
		{"handoff", "--worker", "server", "--turn", "turn-1", "--handoff", `{"kind":"completion"}`},
		{"submit-handoff", "--turn", "turn-1", "--handoff", `{"kind":"completion"}`},
		{"submit-handoff", "--worker", "server", "--handoff", `{"kind":"completion"}`},
		{"submit-handoff", "--worker", "server", "--turn", "turn-1"},
		{"submit-handoff", "--worker", "server", "--turn", "turn-1", "--handoff", `{"kind":"completion"}`, "extra"},
		{"submit-handoff", "--worker", "server", "--turn", "turn-1", "--verified"},
		{"submit-handoff", "--worker", "server", "--turn", "turn-1", "--request-id", "new"},
	} {
		if _, err := execute(args); err == nil || strings.Contains(err.Error(), "Runtime service is stopped") {
			t.Fatalf("invalid handoff arguments reached socket: %q, %v", args, err)
		}
	}
}

func TestPeerCorrelationRequiresExactTargetsAndNoDispatchOptions(t *testing.T) {
	t.Setenv("ATLAS_RUNTIME_HOME", t.TempDir())
	for _, args := range [][]string{
		{"peer-question", "--turn", "turn-1", "--question", "question-1"},
		{"peer-question", "--worker", "sender", "--question", "question-1"},
		{"peer-question", "--worker", "sender", "--turn", "turn-1"},
		{"peer-question", "--worker", "sender", "--turn", "turn-1", "--question", "question-1", "--peer-worker", "peer"},
		{"route-peer-question", "--worker", "sender", "--turn", "turn-1", "--question", "question-1"},
		{"route-peer-question", "--worker", "sender", "--turn", "turn-1", "--question", "question-1", "--peer-worker", "peer"},
		{"route-peer-question", "--worker", "sender", "--turn", "turn-1", "--question", "question-1", "--peer-worker", "UPPER", "--peer-turn", "turn-2"},
		{"bind-peer-reply", "--worker", "sender", "--turn", "turn-1", "--question", "question-1"},
		{"bind-peer-reply", "--worker", "sender", "--turn", "turn-1", "--question", "question-1", "--response-turn", ""},
	} {
		if _, err := execute(args); err == nil || strings.Contains(err.Error(), "Runtime service is stopped") {
			t.Fatalf("incomplete peer correlation reached socket: %q, %v", args, err)
		}
	}
	for _, operation := range []string{"route-peer-question", "peer-question", "bind-peer-reply"} {
		for _, forbidden := range []string{"--assignment", "--answers", "--permissions", "--backend", "--request-id"} {
			args := []string{operation, "--worker", "sender", "--turn", "turn-1", "--question", "question-1", forbidden, "value"}
			if _, err := execute(args); err == nil || !strings.Contains(err.Error(), "flag provided but not defined") {
				t.Fatalf("peer record command accepted dispatch option: %q, %v", args, err)
			}
		}
	}
}

func TestSnapshotMaterializeNeedsExactFlagsAndNoRuntimeService(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	usage := "use snapshot materialize --snapshot sha256:HEX --dest NEW_PATH, snapshot prepare --dest PATH --npm-ci REPO_PATH[/SUBDIR] | --npm-run REPO_PATH[/SUBDIR] --script NAME --output REPO_PATH/OUT..., snapshot status|diff --dest PATH [--path REPO_PATH]..., snapshot submit --dest PATH [--path REPO_PATH] --change-id UUID [--fingerprint fpr_HEX], snapshot freeze --dest PATH --turn TURN_ID --packet NEW_PATH --packet-id UUID [--previous PACKET_ID] [--revision REVISION], snapshot findings --packet PATH --turn TURN_ID, snapshot packets --dest PATH, snapshot discard --packet PATH | --packet-id UUID, or snapshot rebind --dest PATH"
	for _, args := range [][]string{
		{"snapshot"},
		{"snapshot", "download"},
		{"snapshot", "materialize", "--snapshot", "sha256:x"},
		{"snapshot", "materialize", "--dest", filepath.Join(dir, "work")},
		{"snapshot", "materialize", "--snapshot", "sha256:x", "--dest", filepath.Join(dir, "work"), "extra"},
		{"snapshot", "status"},
		{"snapshot", "diff", "--path", "beta"},
		{"snapshot", "status", "--dest", dir, "extra"},
		{"snapshot", "submit", "--dest", dir},
		{"snapshot", "submit", "--change-id", "00000000-0000-0000-0000-000000000000"},
		{"snapshot", "rebind"},
		{"snapshot", "rebind", "--dest", dir, "extra"},
		{"snapshot", "freeze", "--dest", dir, "--turn", "turn-0000000000000000", "--packet", filepath.Join(dir, "p")},
		{"snapshot", "freeze", "--dest", dir, "--turn", "turn-0000000000000000", "--packet-id", "00000000-0000-0000-0000-000000000000"},
		{"snapshot", "freeze", "--dest", dir, "--packet", filepath.Join(dir, "p"), "--packet-id", "00000000-0000-0000-0000-000000000000"},
		{"snapshot", "freeze", "--turn", "turn-0000000000000000", "--packet", filepath.Join(dir, "p"), "--packet-id", "00000000-0000-0000-0000-000000000000"},
		{"snapshot", "findings", "--packet", filepath.Join(dir, "p")},
		{"snapshot", "findings", "--turn", "turn-0000000000000000"},
		{"snapshot", "findings", "--packet", filepath.Join(dir, "p"), "--turn", "turn-0000000000000000", "extra"},
		{"snapshot", "packets"},
		{"snapshot", "packets", "--dest", dir, "extra"},
		{"snapshot", "discard"},
		{"snapshot", "discard", "--packet", filepath.Join(dir, "p"), "--packet-id", "00000000-0000-0000-0000-000000000000"},
		{"snapshot", "discard", "--packet", filepath.Join(dir, "p"), "extra"},
		{"snapshot", "prepare", "--dest", dir},
		{"snapshot", "prepare", "--npm-ci", "repo/app"},
		{"snapshot", "prepare", "--dest", dir, "--npm-ci", "repo/app", "extra"},
		{"snapshot", "prepare", "--dest", dir, "--npm-ci", "repo/app", "--npm-run", "repo/app", "--script", "build", "--output", "repo/out"},
		{"snapshot", "prepare", "--dest", dir, "--npm-ci", "repo/app", "--script", "build"},
		{"snapshot", "prepare", "--dest", dir, "--npm-ci", "repo/app", "--output", "repo/out"},
		{"snapshot", "prepare", "--dest", dir, "--npm-run", "repo/app", "--output", "repo/out"},
		{"snapshot", "prepare", "--dest", dir, "--npm-run", "repo/app", "--script", "build"},
		{"snapshot", "prepare", "--dest", dir, "--script", "build", "--output", "repo/out"},
	} {
		if _, err := execute(args); err == nil || err.Error() != usage {
			t.Fatalf("%q: %v", args, err)
		}
	}
	for _, args := range [][]string{
		{"snapshot", "status", "--snapshot", "sha256:x", "--dest", dir},
		{"snapshot", "materialize", "--path", "beta", "--dest", dir},
		{"snapshot", "submit", "--snapshot", "sha256:x", "--dest", dir, "--change-id", "x"},
		{"snapshot", "rebind", "--path", "beta", "--dest", dir},
		{"snapshot", "prepare", "--path", "beta", "--dest", dir, "--npm-ci", "repo/app"},
		{"snapshot", "prepare", "--dest", dir, "--npm-ci", "repo/app", "--retries", "2"},
		{"snapshot", "status", "--dest", dir, "--output", "repo/out"},
		{"snapshot", "submit", "--dest", dir, "--change-id", "x", "--script", "build"},
		{"snapshot", "freeze", "--dest", dir, "--change-id", "x"},
		{"snapshot", "findings", "--dest", dir, "--packet", filepath.Join(dir, "p"), "--turn", "turn-0000000000000000"},
		{"snapshot", "packets", "--dest", dir, "--path", "beta"},
		{"snapshot", "discard", "--packet-id", "x", "--turn", "turn-0000000000000000"},
		{"snapshot", "discard", "--dest", dir, "--packet", filepath.Join(dir, "p")},
	} {
		if _, err := execute(args); err == nil || !strings.Contains(err.Error(), "flag provided but not defined") {
			t.Fatalf("%q: %v", args, err)
		}
	}
	// Reaches materialization without the Runtime socket; Code is not configured here.
	id := "sha256:" + strings.Repeat("0", 64)
	_, err := execute([]string{"snapshot", "materialize", "--snapshot", id, "--dest", filepath.Join(dir, "work")})
	if err == nil || !strings.HasPrefix(err.Error(), "Code service unavailable: not configured; write ") {
		t.Fatalf("got %v", err)
	}
	// Findings and packets run without the Runtime socket or Code.
	if _, err = execute([]string{"snapshot", "findings", "--packet", t.TempDir(), "--turn", "turn-0000000000000000"}); err == nil || !strings.Contains(err.Error(), "is not a review packet folder") {
		t.Fatalf("findings: %v", err)
	}
	if listed, err := execute([]string{"snapshot", "packets", "--dest", filepath.Join(dir, "work")}); err != nil || len(listed["packets"].([]any)) != 0 {
		t.Fatalf("packets: %v %v", listed, err)
	}
	// Preparation reaches the folder without the Runtime socket; this one, outside the home, was never materialized.
	if _, err = execute([]string{"snapshot", "prepare", "--dest", t.TempDir(), "--npm-ci", "repo/app"}); err == nil || !strings.HasPrefix(err.Error(), "no materialization record for ") {
		t.Fatalf("prepare: %v", err)
	}
	if _, err = execute([]string{"snapshot", "prepare", "--dest", t.TempDir(), "--npm-run", "repo/app", "--script", "build", "--output", "repo/out"}); err == nil || !strings.HasPrefix(err.Error(), "no materialization record for ") {
		t.Fatalf("prepare run: %v", err)
	}
	// Freeze reaches the folder offline, without the Runtime socket or Code; this one was never materialized.
	if _, err = execute([]string{"snapshot", "freeze", "--dest", dir, "--turn", "turn-0123456789abcdef", "--packet", filepath.Join(t.TempDir(), "packet"), "--packet-id", "00000000-0000-4000-8000-000000000000"}); err == nil || !strings.HasPrefix(err.Error(), "no materialization record for ") {
		t.Fatalf("freeze: %v", err)
	}
	// Discard reaches the packet records offline, without the Runtime socket or Code; this packet was never frozen.
	if _, err = execute([]string{"snapshot", "discard", "--packet-id", "00000000-0000-4000-8000-000000000000"}); err == nil || !strings.HasPrefix(err.Error(), "packet 00000000-0000-4000-8000-000000000000 does not exist under ") {
		t.Fatalf("discard: %v", err)
	}
	// Rebind reaches the folder without the Runtime socket; this one was never materialized.
	if _, err = execute([]string{"snapshot", "rebind", "--dest", dir}); err == nil || !strings.HasPrefix(err.Error(), "no materialization record for ") {
		t.Fatalf("rebind: %v", err)
	}
	// Status and diff reach inspection offline too; this folder was never materialized.
	for _, command := range []string{"status", "diff"} {
		_, err = execute([]string{"snapshot", command, "--dest", dir, "--path", "a", "--path", "b"})
		if err == nil || !strings.HasPrefix(err.Error(), "no materialization record for ") {
			t.Fatalf("%s: %v", command, err)
		}
	}
	// Submit validates the change ID before anything else, then needs the materialization record.
	if _, err = execute([]string{"snapshot", "submit", "--dest", dir, "--change-id", "0000"}); err == nil || err.Error() != "change ID must be a lowercase UUID" {
		t.Fatalf("got %v", err)
	}
	_, err = execute([]string{"snapshot", "submit", "--dest", dir, "--change-id", "00000000-0000-0000-0000-000000000000"})
	if err == nil || !strings.HasPrefix(err.Error(), "no materialization record for ") {
		t.Fatalf("got %v", err)
	}
}

// Workers inspect their folder inside a sandbox that may only read their record and baseline.
func TestSnapshotInspectionLeavesTheHomeUntouched(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	home, dest := filepath.Join(root, "runtime"), filepath.Join(root, "work")
	manifest := `{"entries":[],"repositories":[{"path":"repo","repository":"r","revision":"rev_` + strings.Repeat("a", 64) + `"}],"version":2}`
	sum := sha256.Sum256([]byte(manifest))
	id := "sha256:" + hex.EncodeToString(sum[:])
	baseline := filepath.Join(home, "snapshots", hex.EncodeToString(sum[:]))
	for _, directory := range []string{filepath.Join(baseline, "tree"), filepath.Join(home, "materializations"), filepath.Join(dest, "repo")} {
		if err := os.MkdirAll(directory, 0700); err != nil {
			t.Fatal(err)
		}
	}
	for path, body := range map[string]string{
		filepath.Join(baseline, "manifest.json"):                                                     manifest,
		filepath.Join(baseline, "complete"):                                                          id + "\n",
		filepath.Join(home, "materializations", fmt.Sprintf("%x.json", sha256.Sum256([]byte(dest)))): fmt.Sprintf(`{"destination":%q,"snapshot_id":%q}`, dest, id),
		filepath.Join(dest, "repo", "new.txt"):                                                       "new\n",
	} {
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chmod(home, 0500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(home, 0700) })
	t.Setenv("ATLAS_RUNTIME_HOME", home)
	for _, command := range []string{"status", "diff"} {
		result, err := execute([]string{"snapshot", command, "--dest", dest})
		if err != nil || result["snapshot_id"] != id || result["clean"] != false {
			t.Fatalf("%s: %v %v", command, result, err)
		}
		if info, err := os.Stat(home); err != nil || info.Mode().Perm() != 0500 {
			t.Fatalf("%s changed the home: %v %v", command, info, err)
		}
	}
	missing := filepath.Join(root, "missing")
	t.Setenv("ATLAS_RUNTIME_HOME", missing)
	if _, err := execute([]string{"snapshot", "status", "--dest", dest}); err == nil || !strings.HasPrefix(err.Error(), "no materialization record for ") {
		t.Fatalf("got %v", err)
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Fatalf("status created the home: %v", err)
	}
	t.Setenv("ATLAS_RUNTIME_HOME", "relative")
	if _, err := execute([]string{"snapshot", "diff", "--dest", dest}); err == nil || err.Error() != "ATLAS_RUNTIME_HOME must be an absolute path" {
		t.Fatalf("got %v", err)
	}
}
