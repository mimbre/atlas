package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// received is one request the fake backend saw.
type received struct {
	method, path, query, key, contentType string
	body                                  map[string]any
}

// backendServer serves handler on dir/backend.sock, as the Runtime's listener does, and
// records each request.
func backendServer(t *testing.T, dir string, status int, reply map[string]any) *[]received {
	t.Helper()
	listener, err := net.Listen("unix", filepath.Join(dir, backendSocket))
	if err != nil {
		t.Fatal(err)
	}
	seen := &[]received{}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		request := received{method: r.Method, path: r.URL.EscapedPath(), query: r.URL.RawQuery,
			key: r.Header.Get("Idempotency-Key"), contentType: r.Header.Get("Content-Type")}
		if data, _ := io.ReadAll(r.Body); len(data) > 0 {
			if err := json.Unmarshal(data, &request.body); err != nil {
				t.Errorf("request body is no JSON object: %s", data)
			}
		}
		*seen = append(*seen, request)
		if status >= 400 {
			w.Header().Set("Content-Type", "application/problem+json")
		} else {
			w.Header().Set("Content-Type", "application/json")
		}
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(reply)
	}))
	server.Listener.Close()
	server.Listener = listener
	server.Start()
	t.Cleanup(server.Close)
	return seen
}

func TestWorkCommandsSendTheContractRequest(t *testing.T) {
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	folder := filepath.Join(cwd, "relative", "folder")
	work := map[string]any{"work_id": "work-1", "state": "buffered", "revision": float64(1)}
	for _, test := range []struct {
		name string
		args []string
		want received
	}{
		{"start on a folder", []string{"start", "--profile", "deep_coding", "--cost-class", "standard", "--cwd", "relative/folder",
			"--key", "task-7", "--slot", "dev1", "# Fix the parser\n\nDetails follow."},
			received{method: "POST", path: "/v1/work", key: "task-7", contentType: "application/json", body: map[string]any{
				"title": "Fix the parser", "instructions": "# Fix the parser\n\nDetails follow.", "profile": "deep_coding",
				"cost_class": "standard", "slot": "dev1",
				"workspace": map[string]any{"kind": "folder", "path": folder, "permissions": "read-only"}}}},
		{"start on a materialized folder", []string{"start", "--profile", "light_work", "--cost-class", "low", "--cwd", folder,
			"--permissions", "materialized-folder", "--title", "Review", "--", "-starts with a dash"},
			received{method: "POST", path: "/v1/work", contentType: "application/json", body: map[string]any{
				"title": "Review", "instructions": "-starts with a dash", "profile": "light_work", "cost_class": "low",
				"workspace": map[string]any{"kind": "folder", "path": folder, "permissions": "materialized-folder"}}}},
		{"start on a repository", []string{"start", "--profile", "deep_coding", "--cost-class", "high",
			"--repo", "https://github.com/o/r.git", "--branch", "task/x", "Change it"},
			received{method: "POST", path: "/v1/work", contentType: "application/json", body: map[string]any{
				"title": "Change it", "instructions": "Change it", "profile": "deep_coding", "cost_class": "high",
				"workspace": map[string]any{"kind": "repository", "url": "https://github.com/o/r.git", "branch": "task/x", "base": "develop"}}}},
		{"continue", []string{"continue", "--resume-from", "turn-0123456789abcdef", "--profile", "deep_coding", "--cost-class", "standard",
			"--cwd", folder, "Next step"},
			received{method: "POST", path: "/v1/work", contentType: "application/json", body: map[string]any{
				"title": "Next step", "instructions": "Next step", "profile": "deep_coding", "cost_class": "standard",
				"resume_from": "turn-0123456789abcdef",
				"workspace":   map[string]any{"kind": "folder", "path": folder, "permissions": "read-only"}}}},
		// Nothing is checked here: the Runtime answers a missing field with 400 invalid.
		{"start with only an assignment", []string{"start", "anything"},
			received{method: "POST", path: "/v1/work", contentType: "application/json",
				body: map[string]any{"title": "anything", "instructions": "anything"}}},
		{"status lists", []string{"status"}, received{method: "GET", path: "/v1/work"}},
		{"status filters", []string{"status", "--state", "running", "--changed-since", "41"},
			received{method: "GET", path: "/v1/work", query: "changed_since=41&state=running"}},
		{"status of one work", []string{"status", "--work", "work/1"}, received{method: "GET", path: "/v1/work/work%2F1"}},
		{"status by key", []string{"status", "--key", "task 7"}, received{method: "GET", path: "/v1/work", query: "key=task+7"}},
		{"capacity", []string{"capacity"}, received{method: "GET", path: "/v1/capacity"}},
		{"retry", []string{"retry", "--work", "work-1"},
			received{method: "POST", path: "/v1/work/work-1/attempts", contentType: "application/json", body: map[string]any{}}},
		{"retry resuming", []string{"retry", "--work", "work-1", "--resume"},
			received{method: "POST", path: "/v1/work/work-1/attempts", contentType: "application/json", body: map[string]any{"resume": true}}},
		{"stop", []string{"stop", "--work", "work-1", "--reason", "superseded by task 8"},
			received{method: "POST", path: "/v1/work/work-1/cancel", contentType: "application/json",
				body: map[string]any{"mode": "graceful", "reason": "superseded by task 8"}}},
		{"kill", []string{"kill", "--work", "work-1"},
			received{method: "POST", path: "/v1/work/work-1/cancel", contentType: "application/json", body: map[string]any{"mode": "force"}}},
		{"output", []string{"output", "--turn", "turn-0123456789abcdef"},
			received{method: "GET", path: "/v1/turns/turn-0123456789abcdef/output"}},
		{"output page", []string{"output", "--turn", "turn-0123456789abcdef", "--cursor", "c:2"},
			received{method: "GET", path: "/v1/turns/turn-0123456789abcdef/output", query: "cursor=c%3A2"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := socketDirectory(t)
			t.Setenv("ATLAS_RUNTIME_HOME", dir)
			seen := backendServer(t, dir, http.StatusOK, work)
			result, err := execute(test.args)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(result, work) {
				t.Fatalf("the answer is not printed as received: %#v", result)
			}
			if len(*seen) != 1 {
				t.Fatalf("expected one request, got %#v", *seen)
			}
			if got := (*seen)[0]; !reflect.DeepEqual(got, test.want) {
				t.Fatalf("request\n got %#v\nwant %#v", got, test.want)
			}
		})
	}
}

func TestWorkRefusalsKeepTheProblem(t *testing.T) {
	capacity := map[string]any{"accepting": true, "slots": map[string]any{"total": float64(2), "busy": float64(2), "free": float64(0)}}
	for _, test := range []struct {
		name   string
		status int
		body   map[string]any
		want   string
	}{
		{"at capacity", 503, map[string]any{"type": "at-capacity", "title": "Service Unavailable", "status": float64(503),
			"reason": "full", "retry_after": float64(60), "capacity": capacity},
			"Runtime refused (HTTP 503 at-capacity): full"},
		{"policy", 422, map[string]any{"type": "policy-forbids", "title": "Unprocessable Content", "status": float64(422),
			"reason": "policy_forbids", "detail": "profile deep_coding does not allow permission workspace-write"},
			"Runtime refused (HTTP 422 policy-forbids): policy_forbids: profile deep_coding does not allow permission workspace-write"},
		{"invalid", 400, map[string]any{"type": "invalid", "title": "Bad Request", "status": float64(400),
			"reason": "invalid", "detail": "missing field profile"},
			"Runtime refused (HTTP 400 invalid): invalid: missing field profile"},
		{"not found", 404, map[string]any{"type": "not-found", "title": "Not Found", "status": float64(404)},
			"Runtime refused (HTTP 404 not-found): Not Found"},
		{"pruned", 410, map[string]any{"type": "pruned", "title": "Gone", "status": float64(410), "work_id": "work-1", "kind": "completed"},
			"Runtime refused (HTTP 410 pruned): Gone"},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := socketDirectory(t)
			t.Setenv("ATLAS_RUNTIME_HOME", dir)
			backendServer(t, dir, test.status, test.body)
			result, err := execute([]string{"start", "--profile", "deep_coding", "--cost-class", "standard", "--cwd", dir, "x"})
			var problem *backendProblem
			if result != nil || !errors.As(err, &problem) || problem.status != test.status {
				t.Fatalf("expected the problem, got %#v, %v", result, err)
			}
			if err.Error() != test.want {
				t.Fatalf("error %q, want %q", err.Error(), test.want)
			}
			// What the CLI prints: every field of the problem, plus the error.
			var out bytes.Buffer
			writeCommandError(&out, err)
			var printed map[string]any
			if err := json.Unmarshal(out.Bytes(), &printed); err != nil {
				t.Fatal(err)
			}
			want := map[string]any{"error": test.want}
			for key, value := range test.body {
				want[key] = value
			}
			if !reflect.DeepEqual(printed, want) {
				t.Fatalf("printed\n got %#v\nwant %#v", printed, want)
			}
		})
	}
}

func TestWorkCommandsWithoutBackendSayTheServiceIsStopped(t *testing.T) {
	dir := socketDirectory(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	for _, args := range [][]string{
		{"start", "--profile", "p", "--cost-class", "low", "--cwd", dir, "x"},
		{"status"}, {"capacity"}, {"stop", "--work", "w"}, {"output", "--turn", "t"}, {"turns"}, {"events"},
	} {
		if _, err := execute(args); err == nil || err.Error() != "Runtime service is stopped; run atlas-runtime service start" {
			t.Fatalf("%q: %v", args, err)
		}
	}
}

func TestWorkArgumentShapes(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	for _, test := range []struct {
		args []string
		want string
	}{
		{[]string{"start"}, "use start [flags] \"assignment\""},
		{[]string{"start", "one", "two"}, "use start [flags] \"assignment\""},
		{[]string{"start", "assignment", "--profile", "p"}, "use start [flags] \"assignment\""},
		{[]string{"continue", "--cwd", dir, "next"}, "use continue --resume-from TURN_ID"},
		{[]string{"start", "--cwd", dir, "--repo", "https://github.com/o/r.git", "x"}, "not both"},
		{[]string{"start", "--permissions", "read-only", "--branch", "b", "x"}, "not both"},
		{[]string{"stop"}, "use stop --work WORK_ID"},
		{[]string{"kill", "--reason", "r"}, "use kill --work WORK_ID"},
		{[]string{"stop", "--work", "w", "extra"}, "unexpected arguments"},
		{[]string{"retry"}, "use retry --work WORK_ID"},
		{[]string{"output"}, "use output --turn TURN_ID"},
		{[]string{"output", "--turn", "t", "extra"}, "unexpected arguments"},
		{[]string{"status", "extra"}, "unexpected arguments"},
		{[]string{"capacity", "extra"}, "unexpected arguments"},
		// Removed with the cutover: the Runtime picks slot and harness; work replaces the
		// worker and turn as what stop, kill and status name.
		{[]string{"start", "--worker", "w", "--cwd", dir, "x"}, "flag provided but not defined: -worker"},
		{[]string{"start", "--backend", "claude", "--cwd", dir, "x"}, "flag provided but not defined: -backend"},
		{[]string{"start", "--sandbox", "read-only", "--cwd", dir, "x"}, "flag provided but not defined: -sandbox"},
		{[]string{"start", "--questions", "--cwd", dir, "x"}, "flag provided but not defined: -questions"},
		{[]string{"start", "--request-id", "r1", "--cwd", dir, "x"}, "flag provided but not defined: -request-id"},
		{[]string{"continue", "--turn", "t", "x"}, "flag provided but not defined: -turn"},
		{[]string{"status", "--worker", "w"}, "flag provided but not defined: -worker"},
		{[]string{"stop", "--worker", "w", "--turn", "t"}, "flag provided but not defined: -worker"},
		{[]string{"output", "--follow"}, "flag provided but not defined: -follow"},
		{[]string{"output", "--worker", "w"}, "flag provided but not defined: -worker"},
	} {
		t.Run(strings.Join(test.args, " "), func(t *testing.T) {
			result, err := execute(test.args)
			if err == nil || !strings.Contains(err.Error(), test.want) || result != nil {
				t.Fatalf("expected %q before any request, got %#v, %v", test.want, result, err)
			}
		})
	}
}

func TestTitleIsTheFirstLineCutOnACharacter(t *testing.T) {
	for assignment, want := range map[string]string{
		"\n\n  ## Fix it  \nbody":           "Fix it",
		"plain":                             "plain",
		"":                                  "",
		strings.Repeat("é", 150):            strings.Repeat("é", 100),
		"x" + strings.Repeat("é", 150):      "x" + strings.Repeat("é", 99),
		strings.Repeat("a", 250) + "\nnext": strings.Repeat("a", 200),
	} {
		if got := title(assignment); got != want {
			t.Fatalf("title(%.20q) = %q, want %q", assignment, got, want)
		}
	}
}

// readServer answers runtime.read/1 requests on dir/read.sock with reply, recording them.
func readServer(t *testing.T, dir string, reply map[string]any) chan map[string]any {
	t.Helper()
	listener, err := net.Listen("unix", filepath.Join(dir, "read.sock"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	seen := make(chan map[string]any, 4)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			var request map[string]any
			if json.NewDecoder(conn).Decode(&request) == nil {
				seen <- request
				json.NewEncoder(conn).Encode(reply)
			}
			conn.Close()
		}
	}()
	return seen
}

func TestHistoryIsReadOnReadSocket(t *testing.T) {
	turns := []any{map[string]any{"turn_id": "turn-0000000000000001", "worker_id": "default", "state": "finished"}}
	for _, test := range []struct {
		name    string
		args    []string
		request map[string]any
		reply   map[string]any
		result  map[string]any
	}{
		{"turns", []string{"turns"}, map[string]any{"api": readAPI, "op": "turns"},
			map[string]any{"api": readAPI, "op": "turns", "turns": turns}, map[string]any{"turns": turns}},
		{"events", []string{"events", "--cursor", "e:1:5", "--limit", "5"},
			map[string]any{"api": readAPI, "op": "events", "cursor": "e:1:5", "limit": float64(5)},
			map[string]any{"api": readAPI, "op": "events", "events": []any{}, "cursor": "e:1:5", "more": false},
			map[string]any{"events": []any{}, "cursor": "e:1:5", "more": false}},
	} {
		t.Run(test.name, func(t *testing.T) {
			dir := socketDirectory(t)
			t.Setenv("ATLAS_RUNTIME_HOME", dir)
			seen := readServer(t, dir, test.reply)
			result, err := execute(test.args)
			if err != nil {
				t.Fatal(err)
			}
			if request := <-seen; !reflect.DeepEqual(request, test.request) {
				t.Fatalf("request %#v, want %#v", request, test.request)
			}
			if !reflect.DeepEqual(result, test.result) {
				t.Fatalf("result %#v, want %#v", result, test.result)
			}
		})
	}
	dir := socketDirectory(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	readServer(t, dir, map[string]any{"api": readAPI, "error": map[string]any{"code": "invalid_cursor", "message": "Cursor does not identify a position in this stream"}})
	_, err := execute([]string{"events", "--cursor", "stale"})
	var out bytes.Buffer
	writeCommandError(&out, err)
	var printed map[string]any
	if json.Unmarshal(out.Bytes(), &printed); printed["code"] != "invalid_cursor" ||
		printed["error"] != "invalid_cursor: Cursor does not identify a position in this stream" {
		t.Fatalf("read refusal lost its code: %s", out.String())
	}
}

func TestHelpShowsTheWorkCommandsAndNoRemovedFlag(t *testing.T) {
	var out bytes.Buffer
	printHelp(&out)
	help := out.String()
	for _, removed := range []string{"--backend", "--sandbox", "--questions", "--request-id", "--follow | --turn",
		"start [--worker", "continue [--worker", "status [--worker", "stop|kill --worker", "output [--worker",
		"preferences --preferred", "preferences --reenable", "atlas-runtime node"} {
		if strings.Contains(help, removed) {
			t.Errorf("help still shows %q", removed)
		}
	}
	for _, shown := range []string{"--profile", "--cost-class", "--slot", "--resume-from", "--key", "--work WORK_ID",
		"output --turn TURN_ID", "backend.sock", "read.sock", "events --follow", "release --worker NAME"} {
		if !strings.Contains(help, shown) {
			t.Errorf("help does not show %q", shown)
		}
	}
}
