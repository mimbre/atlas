package host

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf16"
	"unicode/utf8"
)

// questionHost owns one native Claude query whose AskUserQuestion permission requests
// Runtime answers. Only the host loop goroutine calls it, so its state needs no lock.
// Fixture tests do not establish provider behavior.
type questionHost struct {
	session, goal string
	tools         []string
	resumeModel   string // empty for a fresh start
	nativePID     int
	send          func(map[string]any) error
	close         func()
	emit          func(map[string]any) error

	initializeID                 string
	initialized, finished        bool
	model, lastTool              string // empty until confirmed
	candidate, pending, inflight *question
}

type question struct {
	tool        string
	input       map[string]any
	request, id string
}

// uuid4 returns 16 random bytes with the RFC 4122 version 4 and variant bits.
func uuid4() []byte {
	value := make([]byte, 16)
	rand.Read(value)
	value[6] = value[6]&0x0f | 0x40
	value[8] = value[8]&0x3f | 0x80
	return value
}

func uuidString(value []byte) string {
	return fmt.Sprintf("%x-%x-%x-%x-%x", value[0:4], value[4:6], value[6:8], value[8:10], value[10:])
}

func (host *questionHost) start() error {
	return host.send(map[string]any{"type": "control_request", "request_id": host.initializeID,
		"request": map[string]any{"subtype": "initialize"}})
}

// questionInput validates one AskUserQuestion input and returns its questions.
func questionInput(value any) ([]any, error) {
	fields, ok := value.(map[string]any)
	if !ok || !hasKeys(fields, "questions") || canonicalSize(value) > 32768 {
		return nil, errors.New("Invalid native question input")
	}
	questions, ok := fields["questions"].([]any)
	if !ok || len(questions) < 1 || len(questions) > 4 {
		return nil, errors.New("Invalid native question count")
	}
	seen := map[string]bool{}
	for _, item := range questions {
		entry, ok := item.(map[string]any)
		if !ok || !hasKeys(entry, "question", "header", "options", "multiSelect") {
			return nil, errors.New("Invalid native question fields")
		}
		text, isText := entry["question"].(string)
		_, isHeader := entry["header"].(string)
		_, isFlag := entry["multiSelect"].(bool)
		if !isText || pythonBlank(text) || len(text) > 4096 || seen[text] || !isHeader || !isFlag {
			return nil, errors.New("Invalid native question")
		}
		seen[text] = true
		options, ok := entry["options"].([]any)
		if !ok || len(options) < 2 || len(options) > 4 {
			return nil, errors.New("Invalid native question options")
		}
		for _, item := range options {
			option, ok := item.(map[string]any)
			label, isLabel := option["label"].(string)
			_, isDescription := option["description"].(string)
			if !ok || !hasKeys(option, "label", "description") || !isLabel || !isDescription || pythonBlank(label) {
				return nil, errors.New("Invalid native question option")
			}
		}
	}
	return questions, nil
}

func (host *questionHost) reject(record map[string]any, message string, deny bool) error {
	identifier, ok := record["request_id"].(string)
	if !ok || identifier == "" || pythonLength(identifier) > 256 {
		return nil
	}
	response := map[string]any{"subtype": "error", "request_id": identifier, "error": message}
	if deny {
		response = map[string]any{"subtype": "success", "request_id": identifier,
			"response": map[string]any{"behavior": "deny", "message": message}}
	}
	return host.send(map[string]any{"type": "control_response", "response": response})
}

// event checks one native record before the provider protocol sees it.
func (host *questionHost) event(record map[string]any) error {
	kind := record["type"]
	if host.finished {
		return errors.New("Native event after terminal result")
	}
	if session, present := record["session_id"]; present && session != host.session {
		return errors.New("Native question session changed")
	}
	if record["parent_tool_use_id"] != nil {
		return errors.New("Subagent question transport is not supported")
	}
	switch {
	case kind == "control_response":
		response, isObject := record["response"].(map[string]any)
		result, isResult := response["response"].(map[string]any)
		mode, present := result["current_permission_mode"]
		if !present {
			mode = "default"
		}
		if host.initialized || !isObject || response["request_id"] != host.initializeID ||
			response["subtype"] != "success" || !isResult || (mode != "default" && mode != "manual") {
			return errors.New("Unexpected native initialization response")
		}
		host.initialized = true
		return host.send(map[string]any{"type": "user", "session_id": host.session, "parent_tool_use_id": nil,
			"message": map[string]any{"role": "user", "content": host.goal}})
	case kind == "system" && record["subtype"] == "init":
		actual, isString := record["model"].(string)
		tools, isList := record["tools"].([]any)
		mode, present := record["permissionMode"]
		if !present {
			mode = "default"
		}
		if !host.initialized || record["session_id"] != host.session ||
			!isString || actual == "" || actual == "<synthetic>" ||
			(host.resumeModel != "" && actual != host.resumeModel) ||
			(host.model != "" && actual != host.model) ||
			(mode != "default" && mode != "manual") || !isList || !sameTools(tools, host.tools) {
			return errors.New("Native question initialization identity changed")
		}
		host.model = actual
	case kind == "assistant":
		message, isObject := record["message"].(map[string]any)
		if host.model == "" || record["session_id"] != host.session ||
			!isObject || !assistantModelMatches(host.model, message["model"]) {
			return errors.New("Native question assistant identity changed")
		}
		content, ok := message["content"].([]any)
		if !ok {
			return errors.New("Invalid native assistant content")
		}
		for _, item := range content {
			block, ok := item.(map[string]any)
			if !ok {
				return errors.New("Invalid native assistant block")
			}
			if block["type"] == "tool_use" && block["name"] == "AskUserQuestion" {
				tool, isString := block["id"].(string)
				caller, present := block["caller"]
				if host.candidate != nil || host.pending != nil || host.inflight != nil ||
					!isString || tool == "" || pythonLength(tool) > 256 || tool == host.lastTool ||
					(present && !pythonEqual(map[string]any{"type": "direct"}, caller)) {
					return errors.New("Ambiguous native question tool use")
				}
				if _, err := questionInput(block["input"]); err != nil {
					return err
				}
				host.candidate = &question{tool: tool, input: block["input"].(map[string]any)}
			}
		}
	case kind == "control_request":
		request, isObject := record["request"].(map[string]any)
		if !isObject || request["subtype"] != "can_use_tool" {
			if err := host.reject(record, "Runtime does not permit native control changes", false); err != nil {
				return err
			}
			return errors.New("Unsupported native control request")
		}
		identifier, isIdentifier := record["request_id"].(string)
		name, isName := request["tool_name"].(string)
		tool, isTool := request["tool_use_id"].(string)
		_, isInput := request["input"].(map[string]any)
		if !isIdentifier || identifier == "" || pythonLength(identifier) > 256 ||
			!isName || name == "" || !isTool || tool == "" || !isInput {
			if err := host.reject(record, "Runtime refused a malformed native request", true); err != nil {
				return err
			}
			return errors.New("Malformed native permission request")
		}
		if name != "AskUserQuestion" {
			return host.reject(record, "Runtime does not approve non-question tools", true)
		}
		questions, err := host.correlate(request)
		if err != nil {
			if rejectErr := host.reject(record, "Runtime refused an invalid native question", true); rejectErr != nil {
				return rejectErr
			}
			return err
		}
		host.pending = &question{tool: host.candidate.tool, input: host.candidate.input,
			request: identifier, id: "question-" + hex.EncodeToString(uuid4())}
		host.candidate = nil
		return host.emit(map[string]any{"type": "runtime.question", "question": map[string]any{
			"id": host.pending.id, "questions": questions,
			"correlation": map[string]any{"session_id": host.session, "model": host.model,
				"tool_use_id": host.pending.tool, "request_id": host.pending.request,
				"native_pid": host.nativePID}}})
	case kind == "user":
		message, isObject := record["message"].(map[string]any)
		content, isList := message["content"].([]any)
		if !isObject || !isList {
			return errors.New("Invalid native tool result")
		}
		for _, item := range content {
			block, ok := item.(map[string]any)
			if !ok {
				return errors.New("Invalid native tool result block")
			}
			if block["type"] == "tool_result" && host.inflight != nil && block["tool_use_id"] == host.inflight.tool {
				failed, present := block["is_error"]
				if record["session_id"] != host.session || (present && failed != false) {
					return errors.New("Native question processing failed")
				}
				if err := host.emit(map[string]any{"type": "runtime.answer_processed", "question_id": host.inflight.id}); err != nil {
					return err
				}
				host.lastTool = host.inflight.tool
				host.inflight = nil
			}
		}
	case kind == "control_cancel_request":
		return errors.New("Native cancelled its pending control request")
	case kind == "result":
		host.close()
		host.finished = true
		if host.model == "" || record["session_id"] != host.session ||
			host.candidate != nil || host.pending != nil || host.inflight != nil {
			return errors.New("Native result ended without processing its question")
		}
	default:
		if name, ok := kind.(string); ok && strings.HasPrefix(name, "control_") {
			return errors.New("Unsupported native control message")
		}
	}
	return nil
}

// correlate requires the permission request to repeat the assistant's pending tool use exactly.
func (host *questionHost) correlate(request map[string]any) ([]any, error) {
	uncorrelated := errors.New("Uncorrelated native question request")
	for key := range request {
		if !slices.Contains([]string{"subtype", "tool_name", "display_name", "input", "tool_use_id", "requires_user_interaction"}, key) {
			return nil, uncorrelated
		}
	}
	if request["requires_user_interaction"] != true || host.model == "" ||
		host.pending != nil || host.inflight != nil || host.candidate == nil ||
		request["tool_use_id"] != host.candidate.tool || !pythonEqual(host.candidate.input, request["input"]) {
		return nil, uncorrelated
	}
	return questionInput(request["input"])
}

// answer delivers one Runtime answer command; a mismatch is rejected without a native write.
func (host *questionHost) answer(command map[string]any) error {
	identifier, isIdentifier := command["question_id"].(string)
	if !hasKeys(command, "command", "question_id", "answers") || command["command"] != "answer" ||
		!isIdentifier || identifier == "" || pythonLength(identifier) > 256 {
		return errors.New("Malformed Runtime answer command")
	}
	answers, isObject := command["answers"].(map[string]any)
	if host.finished || host.pending == nil || identifier != host.pending.id || !isObject || !host.matches(answers) {
		return host.emit(map[string]any{"type": "runtime.answer_rejected", "question_id": identifier,
			"error": "Answer does not match the pending native question"})
	}
	pending := host.pending
	updated := maps.Clone(pending.input)
	updated["answers"] = answers
	if err := host.send(map[string]any{"type": "control_response", "response": map[string]any{
		"subtype": "success", "request_id": pending.request,
		"response": map[string]any{"behavior": "allow", "updatedInput": updated}}}); err != nil {
		return err
	}
	host.inflight, host.pending = pending, nil
	return host.emit(map[string]any{"type": "runtime.answer_delivered", "question_id": identifier})
}

// matches requires exactly one bounded nonblank answer per pending question text.
func (host *questionHost) matches(answers map[string]any) bool {
	questions := host.pending.input["questions"].([]any)
	if len(answers) != len(questions) {
		return false
	}
	for _, item := range questions {
		if _, present := answers[item.(map[string]any)["question"].(string)]; !present {
			return false
		}
	}
	for _, value := range answers {
		if text, ok := value.(string); !ok || pythonBlank(text) || len(text) > 4096 {
			return false
		}
	}
	return canonicalSize(answers) <= 16384
}

func (host *questionHost) cancel() {
	host.candidate, host.pending, host.inflight = nil, nil, nil
	host.finished = true
	host.close()
}

// assistantModelMatches accepts the configured model, or its base ID when native init
// retained the context-window option; assistant records use the base model ID.
func assistantModelMatches(configured string, actual any) bool {
	name, ok := actual.(string)
	return ok && name != "" && (name == configured || configured == name+"[1m]")
}

func hasKeys(fields map[string]any, keys ...string) bool {
	for _, key := range keys {
		if _, present := fields[key]; !present {
			return false
		}
	}
	return len(fields) == len(keys)
}

func sameTools(tools []any, expected []string) bool {
	for _, tool := range tools {
		if name, ok := tool.(string); !ok || !slices.Contains(expected, name) {
			return false
		}
	}
	for _, name := range expected {
		if !slices.Contains(tools, any(name)) {
			return false
		}
	}
	return true
}

// pythonLength is Python's len of a str: code points, not bytes.
func pythonLength(text string) int {
	return utf8.RuneCountInString(text)
}

// pythonBlank is `not text.strip()`; Python also strips the \x1c-\x1f separators.
func pythonBlank(text string) bool {
	return strings.TrimFunc(text, func(char rune) bool {
		return unicode.IsSpace(char) || (char >= 0x1c && char <= 0x1f)
	}) == ""
}

// pythonEqual is Python's == between a validated value (strings, booleans, lists and
// objects, never numbers) and decoded native JSON, where true == 1 and false == 0.
func pythonEqual(validated, other any) bool {
	switch validated := validated.(type) {
	case map[string]any:
		object, ok := other.(map[string]any)
		if !ok || len(object) != len(validated) {
			return false
		}
		for key, value := range validated {
			if item, present := object[key]; !present || !pythonEqual(value, item) {
				return false
			}
		}
		return true
	case []any:
		list, ok := other.([]any)
		if !ok || len(list) != len(validated) {
			return false
		}
		for index, value := range validated {
			if !pythonEqual(value, list[index]) {
				return false
			}
		}
		return true
	case bool:
		if number, ok := other.(json.Number); ok {
			value, err := number.Float64()
			return err == nil && value == map[bool]float64{false: 0, true: 1}[validated]
		}
	}
	return validated == other
}

// canonicalSize is the byte length of json.dumps(value, ensure_ascii=False, separators=(',', ':')).
func canonicalSize(value any) int {
	var data bytes.Buffer
	pythonJSON(&data, value, false)
	return data.Len()
}

// pythonJSON writes value like Python's json.dumps: compact UTF-8 for size checks, or
// with ascii its default ensure_ascii and ", "/": " separators. Sorted keys keep the size.
// shortcut: numbers are written as received, unlike Python's float reformatting; question
// and answer values are validated strings, so only rejected inputs could differ.
func pythonJSON(data *bytes.Buffer, value any, ascii bool) {
	comma, colon := ",", ":"
	if ascii {
		comma, colon = ", ", ": "
	}
	switch value := value.(type) {
	case nil:
		data.WriteString("null")
	case bool:
		data.WriteString(strconv.FormatBool(value))
	case json.Number:
		data.WriteString(string(value))
	case string:
		pythonString(data, value, ascii)
	case []any:
		data.WriteByte('[')
		for index, item := range value {
			if index > 0 {
				data.WriteString(comma)
			}
			pythonJSON(data, item, ascii)
		}
		data.WriteByte(']')
	case map[string]any:
		data.WriteByte('{')
		for index, key := range slices.Sorted(maps.Keys(value)) {
			if index > 0 {
				data.WriteString(comma)
			}
			pythonString(data, key, ascii)
			data.WriteString(colon)
			pythonJSON(data, value[key], ascii)
		}
		data.WriteByte('}')
	default:
		panic(fmt.Sprintf("unsupported JSON value %T", value))
	}
}

func pythonString(data *bytes.Buffer, text string, ascii bool) {
	data.WriteByte('"')
	for _, char := range text {
		switch {
		case char == '"':
			data.WriteString(`\"`)
		case char == '\\':
			data.WriteString(`\\`)
		case char == '\n':
			data.WriteString(`\n`)
		case char == '\r':
			data.WriteString(`\r`)
		case char == '\t':
			data.WriteString(`\t`)
		case char == '\b':
			data.WriteString(`\b`)
		case char == '\f':
			data.WriteString(`\f`)
		case char < 0x20 || (ascii && char == 0x7f):
			fmt.Fprintf(data, `\u%04x`, char)
		case ascii && char > 0xffff:
			high, low := utf16.EncodeRune(char)
			fmt.Fprintf(data, `\u%04x\u%04x`, high, low)
		case ascii && char > 0x7f:
			fmt.Fprintf(data, `\u%04x`, char)
		default:
			data.WriteRune(char)
		}
	}
	data.WriteByte('"')
}

// writeNative writes one native input record to the nonblocking stdin pipe within 3 s.
func writeNative(stdin *os.File, record map[string]any) error {
	var data bytes.Buffer
	pythonJSON(&data, record, true)
	data.WriteByte('\n')
	if data.Len() > recordLimit {
		return errors.New("Native input exceeds 1 MiB")
	}
	if err := stdin.SetWriteDeadline(time.Now().Add(3 * time.Second)); err != nil {
		return errors.New("Native input transport closed")
	}
	if _, err := stdin.Write(data.Bytes()); errors.Is(err, os.ErrDeadlineExceeded) {
		return errors.New("Native input transport stalled")
	} else if err != nil {
		return errors.New("Native input transport closed")
	}
	return nil
}
