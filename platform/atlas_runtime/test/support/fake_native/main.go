// Synthetic native CLI fixtures for Runtime ExUnit tests; never launches a provider or model.
// test_helper.exs builds this file; tests exec it from small sh wrappers:
//
//	fake-native question|peer ARGV0 ARGS...   Claude stream-json question fixtures
//	fake-native admission ROOT ARGV0 ARGS...  Codex/Claude admission fixture (backend from ARGV0)
//	fake-native protocol MODE CAPTURE         Claude SDK protocol projection fixture
//	fake-native detach COMMAND ARGS...        COMMAND in a new session (the e2e's Runtime, so it can be killed as a group)
//	fake-native work ROOT ARGV0 ARGS...       Codex/Claude turn for the work core (goal: complete|hang|stubborn|linger|wait NAME|fail|model_change|subagent_model|resume ...);
//	                                          as codex, `sandbox -P PROFILE -C DIR ARGS... -- ARGV` runs ARGV in DIR (passthrough)
//	fake-native hostcheck host check ...      Stand-in for P6's `atlas-runtime host check` (I-H3 as amended), for the work core
package main

import (
	"bufio"
	"bytes"
	"crypto/sha1"
	"encoding/json"
	"fmt"
	"io"
	"maps"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

var (
	stdin  = bufio.NewReader(os.Stdin)
	stdout = bufio.NewWriter(os.Stdout)
)

func main() {
	if len(os.Args) < 2 {
		fail("usage: fake-native question|peer|admission|protocol|work|detach ...")
	}
	switch mode, args := os.Args[1], os.Args[2:]; mode {
	case "question":
		question(args)
	case "peer":
		peer(args)
	case "admission":
		if len(args) < 2 {
			fail("admission requires ROOT and ARGV0")
		}
		admission(args[0], args[1:])
	case "protocol":
		protocol(args)
	case "detach":
		if len(args) < 1 {
			fail("detach requires COMMAND")
		}
		detach(args)
	case "work":
		if len(args) < 2 {
			fail("work requires ROOT and ARGV0")
		}
		if filepath.Base(args[1]) == "codex" && len(args) > 2 && args[2] == "sandbox" {
			sandbox(args[0], args[1:])
		}
		work(args[0], args[1:])
	case "hostcheck":
		if len(args) < 2 || args[0] != "host" || args[1] != "check" || os.Getenv("ATLAS_RUNTIME_HOME") == "" {
			fail("hostcheck requires host check ... and ATLAS_RUNTIME_HOME")
		}
		hostCheck(os.Getenv("ATLAS_RUNTIME_HOME"), args[2:])
	default:
		fail("unknown fixture mode " + mode)
	}
	exit(0)
}

func fail(message string) {
	stdout.Flush()
	fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
}

func check(err error) {
	if err != nil {
		fail(err.Error())
	}
}

func exit(code int) {
	check(stdout.Flush())
	os.Exit(code)
}

func encode(value any) []byte {
	var data bytes.Buffer
	encoder := json.NewEncoder(&data)
	encoder.SetEscapeHTML(false)
	check(encoder.Encode(value))
	return data.Bytes()
}

// emit writes one JSONL record and flushes it, like print(json.dumps(...), flush=True).
func emit(value any) {
	stdout.Write(encode(value))
	check(stdout.Flush())
}

func decode(data []byte) any {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value any
	check(decoder.Decode(&value))
	if _, err := decoder.Token(); err != io.EOF {
		fail("expected exactly one JSON value")
	}
	return value
}

// readLine returns one stdin line; ok is false at EOF without data.
func readLine() (line []byte, ok bool) {
	line, err := stdin.ReadBytes('\n')
	if err == io.EOF && len(line) == 0 {
		return nil, false
	}
	if err != nil && err != io.EOF {
		check(err)
	}
	return line, true
}

func readJSON() map[string]any {
	line, ok := readLine()
	if !ok {
		fail("unexpected end of control input")
	}
	value, _ := decode(line).(map[string]any)
	return value
}

func appendFile(path string, data []byte) {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0600)
	check(err)
	_, err = file.Write(data)
	check(err)
	check(file.Close())
}

func waitWhile(exists bool, path string) {
	for {
		if _, err := os.Stat(path); (err == nil) != exists {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func arg(argv []string, name, fallback string) string {
	if index := slices.Index(argv, name); index >= 0 && index+1 < len(argv) {
		return argv[index+1]
	}
	return fallback
}

// claude is the shared stream-json conversation: session, model, init, result and the question.
type claude struct {
	session, model string
	host           bool
	init, result   map[string]any
	assistant      map[string]any
	control        map[string]any
}

func newClaude(argv []string, resultText string) claude {
	session := arg(argv, "--session-id", arg(argv, "--resume", "15113671-40b9-4677-8b2b-c6c1180db993"))
	model := arg(argv, "--model", "claude-sonnet-4-6")
	host := slices.Contains(argv, "--permission-prompt-tool")
	tools := []string{"Read", "Glob", "Grep"}
	if host {
		tools = append(tools, "AskUserQuestion")
	}
	input := map[string]any{"questions": []any{map[string]any{
		"question": "Choose?", "header": "Choice", "multiSelect": false,
		"options": []any{map[string]any{"label": "A", "description": "A"}, map[string]any{"label": "B", "description": "B"}},
	}}}
	return claude{
		session: session, model: model, host: host,
		init:   map[string]any{"type": "system", "subtype": "init", "session_id": session, "model": model, "tools": tools},
		result: map[string]any{"type": "result", "session_id": session, "subtype": "success", "is_error": false, "result": resultText},
		assistant: map[string]any{"type": "assistant", "session_id": session, "message": map[string]any{"model": model, "content": []any{
			map[string]any{"type": "tool_use", "id": "tool-1", "name": "AskUserQuestion", "input": input}}}},
		control: map[string]any{"type": "control_request", "request_id": "request-1", "request": map[string]any{
			"subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": input,
			"tool_use_id": "tool-1", "requires_user_interaction": true}},
	}
}

func (c claude) initialize(initialize map[string]any) {
	emit(map[string]any{"type": "control_response", "response": map[string]any{
		"subtype": "success", "request_id": initialize["request_id"], "response": map[string]any{}}})
}

func (c claude) processed() {
	emit(map[string]any{"type": "user", "session_id": c.session, "message": map[string]any{"content": []any{
		map[string]any{"type": "tool_result", "tool_use_id": "tool-1", "content": "processed"}}}})
	emit(c.result)
}

// question writes its evidence in the cwd and processes the answer once process-answer exists.
func question(argv []string) {
	check(os.WriteFile("native.pid", fmt.Appendf(nil, "%d", os.Getpid()), 0666))
	c := newClaude(argv, "done")
	if !c.host {
		emit(c.init)
		emit(c.result)
		exit(0)
	}
	c.initialize(readJSON())
	readJSON()
	emit(c.init)
	check(os.WriteFile("question-source.json", encode(map[string]any{
		"assistant": c.assistant, "control_request": c.control, "native_pid": os.Getpid()}), 0666))
	emit(c.assistant)
	emit(c.control)
	response := encode(readJSON())
	check(os.WriteFile("received-answer.json", response, 0666))
	check(os.WriteFile("received-answers.jsonl", response, 0666))
	waitWhile(false, "process-answer")
	c.processed()
	remaining, err := io.ReadAll(stdin)
	check(err)
	appendFile("received-answers.jsonl", remaining)
	if len(remaining) != 0 {
		fail("unexpected control input after the answer")
	}
}

// peer logs launches, inputs and answers under PEER_RECORD_FIXTURE_ROOT or the cwd.
func peer(argv []string) {
	cwd, err := syscall.Getwd()
	check(err)
	root := cwd
	if value, present := os.LookupEnv("PEER_RECORD_FIXTURE_ROOT"); present {
		root = value
	}
	check(os.MkdirAll(root, 0777))
	log := func(name string, value any) { appendFile(filepath.Join(root, name), encode(value)) }
	input := func() map[string]any {
		line, ok := readLine()
		if !ok {
			exit(0)
		}
		value, _ := decode(line).(map[string]any)
		log("fixture-inputs.jsonl", value)
		return value
	}
	c := newClaude(argv, "Synthetic fixture completed")
	log("fixture-launches.jsonl", map[string]any{"argv": argv, "pid": os.Getpid(), "cwd": cwd, "session_id": c.session})
	if c.host {
		c.initialize(input())
		input()
	}
	emit(c.init)
	if !c.host || slices.Contains(argv, "--resume") {
		emit(c.result)
		exit(0)
	}
	emit(c.assistant)
	emit(c.control)
	log("fixture-answers.jsonl", input())
	waitWhile(true, filepath.Join(root, "hold-answer"))
	c.processed()
	io.Copy(io.Discard, stdin)
}

// uuid5 is Python's uuid.uuid5(uuid.NAMESPACE_URL, name).
func uuid5(name string) string {
	namespace := []byte{0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8}
	sum := sha1.Sum(append(namespace, name...))
	sum[6] = sum[6]&0x0f | 0x50
	sum[8] = sum[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", sum[0:4], sum[4:6], sum[6:8], sum[8:10], sum[10:16])
}

// admission checks the durable reservation exists before it acts as Codex or Claude.
func admission(root string, argv []string) {
	goal, backend := argv[len(argv)-1], filepath.Base(argv[0])
	resumed := slices.Contains(argv, "resume")
	if backend == "claude" {
		resumed = slices.Contains(argv, "--resume")
	}
	if backend == "codex" {
		check(os.Chdir(arg(argv, "--cd", "")))
	}
	cwd, err := syscall.Getwd()
	check(err)
	session := uuid5(cwd + goal)
	if resumed && backend == "claude" {
		session = arg(argv, "--resume", "")
	} else if resumed {
		session = argv[len(argv)-2]
	}
	turn := ""
	if backend == "codex" {
		turn = filepath.Base(filepath.Dir(arg(argv, "--output-last-message", "")))
	}
	paths, err := filepath.Glob(filepath.Join(root, "admissions", "*.json"))
	check(err)
	var record map[string]any
	for _, path := range paths {
		data, err := os.ReadFile(path)
		check(err)
		candidate, _ := decode(data).(map[string]any)
		request, _ := candidate["request"].(map[string]any)
		if request["assignment"] == goal && (backend != "codex" || candidate["turn_id"] == turn) {
			record = candidate
			break
		}
	}
	if strings.HasPrefix(goal, "admit:") {
		if record == nil {
			fail("native command executed without a durable reservation")
		}
		binding, _ := record["binding"].(map[string]any)
		real, err := filepath.EvalSymlinks(cwd)
		check(err)
		var expected any
		if resumed {
			expected = session
		}
		if binding["cwd"] != real || binding["session_id"] != expected {
			fail("durable reservation does not bind this cwd and session")
		}
	}
	switch goal {
	case "admit:journal":
		check(os.Remove(filepath.Join(root, "execution-events.json")))
		check(os.Mkdir(filepath.Join(root, "execution-events.json"), 0777))
	case "admit:acceptance":
		check(os.Mkdir(filepath.Join(root, record["record_ref"].(string)+".tmp"), 0777))
	}
	evidence := map[string]any{"goal": goal, "backend": backend, "resumed": resumed, "session_id": session,
		"argv": argv[1:], "pid": os.Getpid(), "record": record, "executable": os.Getenv("ATLAS_RUNTIME_EXECUTABLE")}
	appendFile(filepath.Join(root, "native-starts.jsonl"), encode(evidence))
	if backend == "claude" {
		emit(map[string]any{"type": "system", "subtype": "init", "session_id": session, "model": arg(argv, "--model", "claude-sonnet-4-6")})
	} else {
		emit(map[string]any{"type": "thread.started", "thread_id": session})
	}
	waitWhile(true, filepath.Join(root, "hold"))
	if goal == "plain:fail" {
		exit(1)
	}
	if backend == "claude" {
		emit(map[string]any{"type": "result", "subtype": "success", "is_error": false, "session_id": session, "result": "done"})
		return
	}
	check(os.WriteFile(arg(argv, "--output-last-message", ""), []byte("done"), 0666))
	emit(map[string]any{"type": "item.completed", "item": map[string]any{"type": "agent_message", "text": "done"}})
	emit(map[string]any{"type": "turn.completed"})
}

// detach replaces itself with argv in a new session, as `atlas-runtime service start`
// starts the Runtime (Setsid): its PID is then the group a test can SIGKILL whole, while a
// native turn's own process group survives it.
func detach(argv []string) {
	path, err := exec.LookPath(argv[0])
	check(err)
	// A process that already leads its group (as an Erlang port's child does) cannot
	// Setsid, and is already the group to kill.
	if _, err = syscall.Setsid(); err != nil && syscall.Getpgrp() != os.Getpid() {
		check(err)
	}
	check(syscall.Exec(path, argv, os.Environ()))
}

// work acts as Codex or Claude for the work core's tests. Each launch is logged to
// ROOT/work-launches.jsonl (goal, mode, backend, model, resumed, session, pid, ppid (the
// host helper), cwd, argv, at), and each end the fixture sees to ROOT/work-ends.jsonl
// (goal, pid, how, at), so a test can prove from the logs alone that a work never started,
// started once, or started only after another ended. The
// goal's first word then decides the turn: "complete" (or anything else) answers
// "done: GOAL", "hang" runs until it is signalled, "stubborn" also ignores SIGINT (only a
// kill ends it), "linger" leaves a child in its process group that ignores SIGINT and
// SIGTERM (its PID in CWD/linger.pid) and exits 0 itself on SIGINT or SIGTERM, so only a
// kill of the group ends the turn, "wait NAME" completes once ROOT/NAME no longer exists, "fail" exits 1
// without a result, and for Claude "model_change" reports a second top-level model (then
// runs until it is signalled), "subagent_model" reports another model only in a subagent
// record (then completes), and "resume" runs until it is signalled unless it was launched
// as a resume, which completes with "resumed: SESSION". A goal whose first word is "write",
// "delete", "chmod" or "symlink" is a list of edits separated by ";", made in the turn's
// folder before it completes: "write PATH TEXT" (parents created, TEXT plus a newline, 0644),
// "delete PATH", "chmod PATH MODE" (octal) and "symlink PATH TARGET"; a last item "fail" or
// "hang" then ends the turn as those goals do.
func work(root string, argv []string) {
	goal, backend := argv[len(argv)-1], filepath.Base(argv[0])
	resumed := slices.Contains(argv, "resume")
	if backend == "claude" {
		resumed = slices.Contains(argv, "--resume")
	}
	if backend == "codex" {
		check(os.Chdir(arg(argv, "--cd", "")))
	}
	cwd, err := syscall.Getwd()
	check(err)
	session := uuid5(fmt.Sprintf("%s:%s:%d", cwd, goal, os.Getpid()))
	if resumed && backend == "claude" {
		session = arg(argv, "--resume", "")
	} else if resumed {
		session = argv[len(argv)-2]
	}
	words := strings.Fields(goal)
	mode := ""
	if len(words) > 0 {
		mode = words[0]
	}
	model := arg(argv, "--model", arg(argv, "-m", ""))
	at := func() string { return time.Now().UTC().Format(time.RFC3339Nano) }
	appendFile(filepath.Join(root, "work-launches.jsonl"), encode(map[string]any{
		"goal": goal, "mode": mode, "backend": backend, "model": model,
		"resumed": resumed, "session_id": session, "pid": os.Getpid(), "ppid": os.Getppid(), "cwd": cwd,
		"argv": argv[1:], "at": at()}))
	ended := func(how string) {
		appendFile(filepath.Join(root, "work-ends.jsonl"), encode(map[string]any{
			"goal": goal, "pid": os.Getpid(), "how": how, "at": at()}))
	}
	if backend == "claude" {
		if model == "" {
			model = "claude-sonnet-4-6"
		}
		emit(map[string]any{"type": "system", "subtype": "init", "session_id": session, "model": model})
	} else {
		emit(map[string]any{"type": "thread.started", "thread_id": session})
	}
	assistant := func(model string, parent any) {
		emit(map[string]any{"type": "assistant", "session_id": session, "parent_tool_use_id": parent,
			"message": map[string]any{"model": model, "content": []any{
				map[string]any{"type": "text", "text": "working with " + model}}}})
	}
	// Runs until SIGINT or SIGTERM, logs that end, then dies of the signal as before; a
	// SIGKILL is never seen.
	untilSignalled := func() {
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
		received := (<-signals).(syscall.Signal)
		ended("signal " + received.String())
		signal.Reset(received)
		check(syscall.Kill(os.Getpid(), received))
		for {
			time.Sleep(time.Hour)
		}
	}
	if mode == "resume" && !resumed {
		mode = "hang"
	}
	if mode == "write" || mode == "delete" || mode == "chmod" || mode == "symlink" {
		mode = edit(goal)
	}
	switch mode {
	case "stubborn":
		signal.Ignore(syscall.SIGINT, syscall.SIGTERM)
		for {
			time.Sleep(time.Hour)
		}
	case "hang":
		untilSignalled()
	case "linger":
		// The child inherits the ignored signals and stays in the leader's group (no
		// setsid/setpgid), holding none of its pipes; it runs until SIGKILL.
		signal.Ignore(syscall.SIGINT, syscall.SIGTERM)
		child := exec.Command("/bin/sh", "-c", "trap '' INT TERM; exec /bin/sleep 3600")
		check(child.Start())
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
		pidFile := filepath.Join(cwd, "linger.pid")
		check(os.WriteFile(pidFile+".tmp", fmt.Appendf(nil, "%d\n", child.Process.Pid), 0666))
		check(os.Rename(pidFile+".tmp", pidFile))
		received := (<-signals).(syscall.Signal)
		ended("signal " + received.String())
		exit(0)
	case "wait":
		if len(words) > 1 {
			waitWhile(true, filepath.Join(root, words[1]))
		}
	case "fail":
		ended("fail")
		exit(1)
	case "model_change":
		if backend == "claude" {
			assistant(model, nil)
			assistant(model+"-changed", nil)
			untilSignalled()
		}
	case "subagent_model":
		if backend == "claude" {
			assistant(model, nil)
			assistant(model+"-subagent", "toolu_fixture_subagent")
		}
	}
	answer := "done: " + goal
	if mode == "resume" {
		answer = "resumed: " + session
	}
	if backend == "claude" {
		emit(map[string]any{"type": "result", "subtype": "success", "is_error": false, "session_id": session, "result": answer})
	} else {
		check(os.WriteFile(arg(argv, "--output-last-message", ""), []byte(answer), 0666))
		emit(map[string]any{"type": "item.completed", "item": map[string]any{"type": "agent_message", "text": answer}})
		emit(map[string]any{"type": "turn.completed"})
	}
	ended("result")
}

// edit makes a goal's edits in the current folder and returns how the turn then ends.
func edit(goal string) string {
	end := "complete"
	for _, item := range strings.Split(goal, ";") {
		words := strings.Fields(item)
		if len(words) == 0 {
			continue
		}
		switch {
		case words[0] == "write" && len(words) >= 2:
			check(os.MkdirAll(filepath.Dir(words[1]), 0755))
			check(os.WriteFile(words[1], []byte(strings.Join(words[2:], " ")+"\n"), 0644))
		case words[0] == "delete" && len(words) == 2:
			check(os.Remove(words[1]))
		case words[0] == "chmod" && len(words) == 3:
			mode, err := strconv.ParseUint(words[2], 8, 32)
			check(err)
			check(os.Chmod(words[1], os.FileMode(mode)))
		case words[0] == "symlink" && len(words) == 3:
			check(os.MkdirAll(filepath.Dir(words[1]), 0755))
			check(os.Symlink(words[2], words[1]))
		case words[0] == "fail" || words[0] == "hang":
			end = words[0]
		default:
			fail("unknown edit: " + item)
		}
	}
	return end
}

// protocol captures one bounded request line and answers with a synthetic SDK projection.
// Output is flushed only at exit, like the buffered stdout of the original fixture.
func protocol(args []string) {
	allowed := []string{"echo", "duplicate", "correlated", "uncorrelated", "batch", "wrong_uuid",
		"wrong_session", "subagent", "control", "malformed", "oversized", "eof", "partial"}
	if len(args) != 2 || !slices.Contains(allowed, args[0]) {
		exit(2)
	}
	mode, capture := args[0], args[1]
	var line []byte
	for len(line) < 32769 {
		char, err := stdin.ReadByte()
		if err != nil {
			break
		}
		if line = append(line, char); char == '\n' {
			break
		}
	}
	if !bytes.HasSuffix(line, []byte("\n")) || len(line) > 32768 {
		exit(2)
	}
	request, ok := decode(line).(map[string]any)
	if !ok {
		fail("request must be a JSON object")
	}
	output, err := os.OpenFile(capture, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0666)
	check(err)
	_, err = output.Write(line)
	check(err)
	check(output.Close())
	other := "ffffffff-ffff-4fff-8fff-ffffffffffff"
	echo := maps.Clone(request)
	echo["isReplay"] = true
	switch mode {
	case "eof":
		exit(1)
	case "malformed":
		stdout.WriteString("{\"type\":\n")
		exit(1)
	case "oversized":
		stdout.WriteString(strings.Repeat("x", 65537))
		exit(1)
	case "wrong_uuid":
		echo["uuid"] = other
	case "wrong_session":
		echo["session_id"] = other
	case "partial":
		stdout.Write(encode(echo)[:20])
		exit(1)
	case "control":
		stdout.Write(encode(map[string]any{"type": "control_request", "request_id": "synthetic",
			"request": map[string]any{"subtype": "can_use_tool", "tool_name": "Bash"}}))
		exit(0)
	case "correlated", "uncorrelated", "batch", "subagent":
		event := map[string]any{"type": "result", "subtype": "success", "session_id": request["session_id"]}
		if mode != "uncorrelated" {
			event["user_message_uuid"] = request["uuid"]
			event["user_message_uuids"] = []any{request["uuid"]}
		}
		if mode == "batch" {
			event["user_message_uuid"] = other
			event["user_message_uuids"] = []any{request["uuid"], other}
		}
		if mode == "subagent" {
			event["type"], event["parent_tool_use_id"] = "assistant", "synthetic-parent"
		}
		stdout.Write(encode(event))
		exit(0)
	}
	stdout.Write(encode(echo))
	if mode == "duplicate" {
		stdout.Write(encode(echo))
	}
}

// sandbox stands in for `codex sandbox -P PROFILE -C DIR ARGS... -- ARGV` the way
// host/host/prepare_test.go does: it logs its own path and argv to ROOT/check-sandbox.jsonl
// and execs ARGV in DIR with its environment unchanged. It enforces nothing.
func sandbox(root string, argv []string) {
	dir, rest := "", []string(nil)
	for i := 2; i < len(argv); i++ {
		if argv[i] == "-C" && i+1 < len(argv) {
			dir = argv[i+1]
		}
		if argv[i] == "--" {
			rest = argv[i+1:]
			break
		}
	}
	appendFile(filepath.Join(root, "check-sandbox.jsonl"), encode(map[string]any{
		"codex": argv[0], "argv": argv[1:], "tmpdir": os.Getenv("TMPDIR"),
		"runtime_home": os.Getenv("ATLAS_RUNTIME_HOME")}))
	if dir == "" || len(rest) == 0 {
		fail("sandbox requires -C DIR and -- ARGV")
	}
	check(os.Chdir(dir))
	program := rest[0]
	if !strings.Contains(program, "/") {
		found, err := exec.LookPath(program)
		check(err)
		program = found
	}
	check(syscall.Exec(program, rest, os.Environ()))
}

// hostCheck stands in for P6's `atlas-runtime host check` (I-H3, with the coordinator's
// amendment of 2026-11-17), which this tree does not have yet:
//
//	--cwd D (--scope JSON | --sandbox read-only) --scratch S --timeout SEC --grace SEC --tail BYTES -- ARGV
//
// ROOT is the Runtime home the core names in ATLAS_RUNTIME_HOME. It logs its argv to
// ROOT/check-launches.jsonl, refuses (one `refused` line, no `started`)
// a codex that LookPath does not find as an absolute path (sandbox_unavailable), a command[0]
// that leaves D (leaves_folder) and an unknown name (not_found); otherwise it recreates S
// (0700), runs `<codex> sandbox -P <profile> -C D <args> -- ARGV` in its own process group with
// TMPDIR in S, stops the group on timeout, on a stdin stop line and at stdin EOF (SIGINT, then
// SIGKILL after the grace), and reports `ended` once the group is gone and S removed.
//
// ROOT/check-fault selects a deviation of the amendment: `setup_error` (exit 1, an error on
// stderr, no stdout event: (b)), `die_after_started` (exit 1 right after `started`, no
// `ended`: (c)) or `group_kept` (`group_gone: false`, S kept: (a)).
func hostCheck(root string, argv []string) {
	appendFile(filepath.Join(root, "check-launches.jsonl"), encode(map[string]any{
		"argv": argv, "pid": os.Getpid(), "path": os.Getenv("PATH"),
		"runtime_home": os.Getenv("ATLAS_RUNTIME_HOME")}))
	// Every end is logged too, so a test can wait for each helper it started to be done.
	checkRoot = root
	options := map[string]string{}
	var command []string
	for i := 0; i < len(argv); i++ {
		if argv[i] == "--" {
			command = argv[i+1:]
			break
		}
		if !strings.HasPrefix(argv[i], "--") || i+1 >= len(argv) {
			setupError("unexpected argument " + argv[i])
		}
		options[argv[i][2:]] = argv[i+1]
		i++
	}
	fault := ""
	if data, err := os.ReadFile(filepath.Join(root, "check-fault")); err == nil {
		fault = strings.TrimSpace(string(data))
	}
	dir, scratch := options["cwd"], options["scratch"]
	timeout, err1 := strconv.Atoi(options["timeout"])
	grace, err2 := strconv.Atoi(options["grace"])
	tail, err3 := strconv.Atoi(options["tail"])
	if fault == "setup_error" || dir == "" || scratch == "" || len(command) == 0 ||
		err1 != nil || err2 != nil || err3 != nil ||
		(options["scope"] == "") == (options["sandbox"] != "read-only") {
		setupError("usage: host check --cwd D (--scope JSON | --sandbox read-only) ...")
	}
	codex, err := exec.LookPath("codex")
	if err != nil || !filepath.IsAbs(codex) {
		refuse("sandbox_unavailable")
	}
	if why := program(dir, command[0]); why != "" {
		refuse(why)
	}
	check(os.RemoveAll(scratch))
	check(os.Mkdir(scratch, 0o700))
	profile, args := "atlas_read_only", []string{"-c", `default_permissions="atlas_read_only"`}
	if options["scope"] != "" {
		profile = "atlas_folder"
		args = []string{"-c", `default_permissions="atlas_folder"`,
			"-c", `permissions={scope=` + options["scope"] + `,unix_sockets="` + scratch + `"}`}
	}
	full := append(append([]string{"sandbox", "-P", profile, "-C", dir}, args...), "--")
	child := exec.Command(codex, append(full, command...)...)
	child.Dir = dir
	child.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + os.Getenv("HOME"),
		"TMPDIR=" + scratch, "XDG_CACHE_HOME=" + scratch}
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	reader, writer, err := os.Pipe()
	check(err)
	child.Stdout, child.Stderr = writer, writer
	started := time.Now()
	check(child.Start())
	writer.Close()
	pgid := child.Process.Pid
	emit(map[string]any{"event": "started", "pgid": pgid})
	if fault == "die_after_started" {
		checkEnded("died")
		stdout.Flush()
		os.Exit(1)
	}
	type tailed struct {
		data     []byte
		complete bool
	}
	output := make(chan tailed, 1)
	go func() {
		var kept []byte
		total, buffer := 0, make([]byte, 32*1024)
		for {
			n, err := reader.Read(buffer)
			total += n
			kept = append(kept, buffer[:n]...)
			if len(kept) > tail {
				kept = kept[len(kept)-tail:]
			}
			if err != nil {
				break
			}
		}
		for len(kept) > 0 && !utf8.RuneStart(kept[0]) {
			kept = kept[1:]
		}
		output <- tailed{kept, total == len(kept)}
	}()
	stops := make(chan string, 4)
	go func() {
		for {
			line, ok := readLine()
			if !ok {
				stops <- "eof"
				return
			}
			var stop map[string]string
			if json.Unmarshal(line, &stop) == nil && (stop["stop"] == "signal" || stop["stop"] == "kill") {
				stops <- stop["stop"]
			}
		}
	}()
	done := make(chan error, 1)
	go func() { done <- child.Wait() }()
	signalled, timedOut, stopped := "", false, false
	send := func(name string) {
		number := syscall.SIGINT
		if name == "SIGKILL" {
			number = syscall.SIGKILL
		}
		signalled = name
		syscall.Kill(-pgid, number)
	}
	limit := time.After(time.Duration(timeout) * time.Second)
	var force <-chan time.Time
	var waited error
loop:
	for {
		select {
		case waited = <-done:
			break loop
		case <-limit:
			timedOut = true
			send("SIGINT")
			force = time.After(time.Duration(grace) * time.Second)
		case how := <-stops:
			stopped = true
			if how == "kill" {
				send("SIGKILL")
			} else {
				send("SIGINT")
				force = time.After(time.Duration(grace) * time.Second)
			}
		case <-force:
			send("SIGKILL")
		}
	}
	gone := false
	for i := 0; i < 50 && !gone; i++ {
		if syscall.Kill(-pgid, 0) == syscall.ESRCH {
			gone = true
		} else {
			syscall.Kill(-pgid, syscall.SIGKILL)
			time.Sleep(20 * time.Millisecond)
		}
	}
	got := <-output
	var exitStatus any
	if status, ok := child.ProcessState.Sys().(syscall.WaitStatus); ok && status.Exited() {
		exitStatus = status.ExitStatus()
	} else if waited == nil {
		exitStatus = 0
	}
	var signalName any
	if signalled != "" {
		signalName = signalled
	}
	if fault == "group_kept" {
		gone = false
	}
	removed := false
	if gone {
		removed = os.RemoveAll(scratch) == nil
	}
	emit(map[string]any{"event": "ended", "exit_status": exitStatus, "signal": signalName,
		"timed_out": timedOut, "stopped": stopped,
		"duration_ms": time.Since(started).Milliseconds(),
		"output":      map[string]any{"tail": string(got.data), "complete": got.complete},
		"group_gone":  gone, "scratch_removed": removed})
	checkEnded("ended")
	exit(0)
}

var checkRoot string

func checkEnded(how string) {
	if checkRoot != "" {
		appendFile(filepath.Join(checkRoot, "check-ends.jsonl"), encode(map[string]any{
			"pid": os.Getpid(), "how": how}))
	}
}

// program: "" when command[0] may run, else the refusal (leaves_folder, not_found).
func program(dir, name string) string {
	if !strings.Contains(name, "/") {
		if _, err := exec.LookPath(name); err != nil {
			return "not_found"
		}
		return ""
	}
	if filepath.IsAbs(name) || slices.Contains(strings.Split(name, "/"), "..") {
		return "leaves_folder"
	}
	folder, err := filepath.EvalSymlinks(dir)
	check(err)
	target, err := filepath.EvalSymlinks(filepath.Join(folder, name))
	if err != nil {
		return "not_found"
	}
	if target != folder && !strings.HasPrefix(target, folder+string(filepath.Separator)) {
		return "leaves_folder"
	}
	return ""
}

func refuse(why string) {
	emit(map[string]any{"event": "refused", "why": why})
	checkEnded("refused")
	exit(0)
}

func setupError(message string) {
	checkEnded("setup_error")
	stdout.Flush()
	fmt.Fprintln(os.Stderr, string(encode(map[string]any{"error": message})))
	os.Exit(1)
}
