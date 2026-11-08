// Synthetic native CLI fixtures for Runtime ExUnit tests; never launches a provider or model.
// test_helper.exs builds this file; tests exec it from small sh wrappers:
//
//	fake-native question|peer ARGV0 ARGS...   Claude stream-json question fixtures
//	fake-native admission ROOT ARGV0 ARGS...  Codex/Claude admission fixture (backend from ARGV0)
//	fake-native protocol MODE CAPTURE         Claude SDK protocol projection fixture
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
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"
)

var (
	stdin  = bufio.NewReader(os.Stdin)
	stdout = bufio.NewWriter(os.Stdout)
)

func main() {
	if len(os.Args) < 2 {
		fail("usage: fake-native question|peer|admission|protocol ...")
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
	if backend == "claude" {
		emit(map[string]any{"type": "result", "subtype": "success", "is_error": false, "session_id": session, "result": "done"})
		return
	}
	check(os.WriteFile(arg(argv, "--output-last-message", ""), []byte("done"), 0666))
	emit(map[string]any{"type": "item.completed", "item": map[string]any{"type": "agent_message", "text": "done"}})
	emit(map[string]any{"type": "turn.completed"})
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
