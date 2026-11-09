package host

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/eyra/atlas/tools/runtime/workspace"
)

// Deterministic host and owned-process fixtures, not live-provider or model-consumption proof.

const (
	questionSession = "15113671-40b9-4677-8b2b-c6c1180db993"
	questionModel   = "fixture-model"
	questionText    = `{"question":"Which value?","header":"Value","multiSelect":false,` +
		`"options":[{"label":"11","description":"First"},{"label":"23","description":"Second"}]}`
)

var questionTools = []string{"Read", "Glob", "Grep", "AskUserQuestion"}

func decoded(t *testing.T, text string) map[string]any {
	t.Helper()
	record, err := jsonRecord([]byte(text), recordLimit)
	if err != nil {
		t.Fatalf("fixture record %s: %v", text, err)
	}
	return record
}

func assistantText(session, tool string) string {
	return `{"type":"assistant","session_id":"` + session + `","parent_tool_use_id":null,"message":{"model":"` +
		questionModel + `","content":[{"type":"tool_use","id":"` + tool + `","name":"AskUserQuestion",` +
		`"caller":{"type":"direct"},"input":{"questions":[` + questionText + `]}}]}}`
}

func requestText(tool, identifier string) string {
	return `{"type":"control_request","request_id":"` + identifier + `","request":{"subtype":"can_use_tool",` +
		`"tool_name":"AskUserQuestion","tool_use_id":"` + tool + `","requires_user_interaction":true,` +
		`"input":{"questions":[` + questionText + `]}}}`
}

func processedText(session, tool string) string {
	return `{"type":"user","session_id":"` + session + `","parent_tool_use_id":null,"message":{"role":"user",` +
		`"content":[{"type":"tool_result","tool_use_id":"` + tool + `","content":"fixture processed"}]}}`
}

type questionPeer struct {
	host          *questionHost
	sent, emitted []map[string]any
	closed        bool
}

// newQuestionPeer is an initialized question host whose native writes and records are captured.
func newQuestionPeer(t *testing.T, resumeModel string, initialize bool) *questionPeer {
	t.Helper()
	peer := &questionPeer{}
	peer.host = &questionHost{session: questionSession, goal: "one assignment", tools: questionTools,
		resumeModel: resumeModel, nativePID: 7319, initializeID: "initialize-fixture",
		send:  func(record map[string]any) error { peer.sent = append(peer.sent, record); return nil },
		close: func() { peer.closed = true },
		emit:  func(record map[string]any) error { peer.emitted = append(peer.emitted, record); return nil }}
	if err := peer.host.start(); err != nil {
		t.Fatal(err)
	}
	peer.mustEvent(t, `{"type":"control_response","response":{"subtype":"success","request_id":"initialize-fixture","response":{}}}`)
	if initialize {
		peer.mustEvent(t, `{"type":"system","subtype":"init","session_id":"`+questionSession+`","model":"`+questionModel+`","tools":["Read","Glob","Grep","AskUserQuestion"]}`)
	}
	return peer
}

func (peer *questionPeer) mustEvent(t *testing.T, text string) {
	t.Helper()
	if err := peer.host.event(decoded(t, text)); err != nil {
		t.Fatalf("%s refused: %v", text, err)
	}
}

func (peer *questionPeer) refuse(t *testing.T, record map[string]any, message string) {
	t.Helper()
	if err := peer.host.event(record); err == nil || !strings.Contains(err.Error(), message) {
		t.Fatalf("%v: wanted refusal containing %q, got %v", record, message, err)
	}
}

func (peer *questionPeer) pending(t *testing.T) string {
	t.Helper()
	peer.mustEvent(t, assistantText(questionSession, "tool-1"))
	peer.mustEvent(t, requestText("tool-1", "request-1"))
	return peer.host.pending.id
}

func (peer *questionPeer) answer(t *testing.T, identifier string, answers any) {
	t.Helper()
	if answers == nil {
		answers = map[string]any{"Which value?": "436849"}
	}
	if err := peer.host.answer(map[string]any{"command": "answer", "question_id": identifier, "answers": answers}); err != nil {
		t.Fatal(err)
	}
}

func (peer *questionPeer) last() map[string]any {
	return peer.emitted[len(peer.emitted)-1]
}

func (peer *questionPeer) assignments() int {
	count := 0
	for _, record := range peer.sent {
		if record["type"] == "user" {
			count++
		}
	}
	return count
}

func emittedTypes(records []map[string]any) []string {
	var kinds []string
	for _, record := range records {
		kinds = append(kinds, record["type"].(string))
	}
	return kinds
}

func TestQuestionDeliveryIsNotProcessingAndDuplicateNeverResends(t *testing.T) {
	peer := newQuestionPeer(t, "", true)
	if peer.sent[0]["type"] != "control_request" || !strings.HasPrefix(encode(t, peer.sent[0]), `{"request":{"subtype":"initialize"}`) ||
		encode(t, peer.sent[1]) != `{"message":{"content":"one assignment","role":"user"},"parent_tool_use_id":null,"session_id":"`+questionSession+`","type":"user"}` {
		t.Fatalf("initialize then assignment expected: %v", peer.sent)
	}
	identifier := peer.pending(t)
	peer.answer(t, identifier, nil)
	want := `{"response":{"request_id":"request-1","response":{"behavior":"allow","updatedInput":{"answers":{"Which value?":"436849"},"questions":[` +
		encode(t, decoded(t, questionText)) + `]}},"subtype":"success"},"type":"control_response"}`
	if got := encode(t, peer.sent[len(peer.sent)-1]); got != want {
		t.Fatalf("delivered %s", got)
	}
	if peer.host.pending != nil || peer.last()["type"] != "runtime.answer_delivered" || peer.last()["question_id"] != identifier {
		t.Fatalf("delivery state %v %v", peer.host.pending, peer.last())
	}
	count := len(peer.sent)
	peer.answer(t, identifier, nil)
	if len(peer.sent) != count || encode(t, peer.last()) != `{"error":"Answer does not match the pending native question","question_id":"`+identifier+`","type":"runtime.answer_rejected"}` {
		t.Fatalf("duplicate resent or not rejected: %v", peer.last())
	}
	peer.mustEvent(t, processedText(questionSession, "tool-1"))
	if encode(t, peer.last()) != `{"question_id":"`+identifier+`","type":"runtime.answer_processed"}` {
		t.Fatalf("processed %v", peer.last())
	}
	peer.mustEvent(t, `{"type":"result","session_id":"`+questionSession+`","result":"fixture done"}`)
	if !peer.closed {
		t.Fatal("terminal result must close native input")
	}
	peer.answer(t, identifier, nil)
	if peer.last()["type"] != "runtime.answer_rejected" || peer.assignments() != 1 {
		t.Fatalf("late answer %v; assignments %d", peer.last(), peer.assignments())
	}
	peer.refuse(t, decoded(t, `{"type":"fixture"}`), "Native event after terminal result")
}

func TestSequentialQuestionsKeepExactSourceCorrelation(t *testing.T) {
	peer := newQuestionPeer(t, "", true)
	identifierPattern := regexp.MustCompile(`\Aquestion-[0-9a-f]{32}\z`)
	var previous map[string]any
	for _, index := range []string{"1", "2"} {
		tool, identifier := "tool-"+index, "request-"+index
		peer.mustEvent(t, assistantText(questionSession, tool))
		peer.mustEvent(t, requestText(tool, identifier))
		question := peer.last()["question"].(map[string]any)
		if !identifierPattern.MatchString(question["id"].(string)) ||
			encode(t, question["questions"]) != "["+encode(t, decoded(t, questionText))+"]" ||
			encode(t, question["correlation"]) != encode(t, map[string]any{"session_id": questionSession, "model": questionModel,
				"tool_use_id": tool, "request_id": identifier, "native_pid": 7319}) {
			t.Fatalf("question %v", question)
		}
		if previous != nil {
			if question["id"] == previous["id"] {
				t.Fatal("question ids must differ")
			}
			count := len(peer.sent)
			peer.answer(t, previous["id"].(string), nil)
			if len(peer.sent) != count || peer.host.pending.id != question["id"] {
				t.Fatal("an answer to the previous question must not reach native")
			}
		}
		peer.answer(t, question["id"].(string), nil)
		if response := peer.sent[len(peer.sent)-1]["response"].(map[string]any); response["request_id"] != identifier {
			t.Fatalf("answer for the wrong request %v", response)
		}
		peer.mustEvent(t, processedText(questionSession, tool))
		previous = question
	}
	// The processed tool use cannot ask again.
	peer.refuse(t, decoded(t, assistantText(questionSession, "tool-2")), "Ambiguous native question tool use")
}

func TestWrongAnswersLeaveExactPendingQuestion(t *testing.T) {
	peer := newQuestionPeer(t, "", true)
	identifier := peer.pending(t)
	for _, answers := range []any{
		map[string]any{}, map[string]any{"other": "yes"}, map[string]any{"Which value?": nil},
		map[string]any{"Which value?": json.Number("1")}, map[string]any{"Which value?": ""},
		map[string]any{"Which value?": " \t\x1c"}, map[string]any{"Which value?": strings.Repeat("é", 2049)},
		map[string]any{"Which value?": "yes", "updatedPermissions": []any{}}, []any{"yes"},
	} {
		count := len(peer.sent)
		peer.answer(t, identifier, answers)
		if len(peer.sent) != count || peer.host.pending == nil || peer.host.pending.id != identifier ||
			peer.last()["type"] != "runtime.answer_rejected" {
			t.Fatalf("%v: wrong answer changed the pending question", answers)
		}
	}
	peer.answer(t, "question-wrong", nil)
	if peer.host.pending.id != identifier || peer.last()["question_id"] != "question-wrong" {
		t.Fatal("unknown question id must be rejected")
	}
	peer.answer(t, identifier, map[string]any{"Which value?": strings.Repeat("é", 2048)})
	if peer.host.pending != nil {
		t.Fatal("4096-byte answer must be delivered")
	}
}

func TestMalformedAnswerCommandsFailClosed(t *testing.T) {
	peer := newQuestionPeer(t, "", true)
	identifier := peer.pending(t)
	for _, command := range []map[string]any{
		{"command": "set_permission_mode"},
		{"command": "answer", "question_id": identifier, "answers": map[string]any{}, "updatedPermissions": []any{}},
		{"command": "other", "question_id": identifier, "answers": map[string]any{}},
		{"command": "answer", "question_id": "", "answers": map[string]any{}},
		{"command": "answer", "question_id": strings.Repeat("é", 257), "answers": map[string]any{}},
	} {
		if err := peer.host.answer(command); err == nil || err.Error() != "Malformed Runtime answer command" {
			t.Fatalf("%v: %v", command, err)
		}
	}
	if peer.host.pending.id != identifier || len(peer.emitted) != 1 {
		t.Fatal("malformed commands must not touch the pending question")
	}
}

func TestAnswerObjectSizeLimitIncludesQuestionKeys(t *testing.T) {
	peer := newQuestionPeer(t, "", true)
	var questions []any
	answers := map[string]any{}
	for index := range 4 {
		question := decoded(t, questionText)
		question["question"] = strconv.Itoa(index) + strings.Repeat("q", 4095)
		questions = append(questions, question)
		answers[question["question"].(string)] = "answer"
	}
	assistant := decoded(t, assistantText(questionSession, "tool-1"))
	assistant["message"].(map[string]any)["content"].([]any)[0].(map[string]any)["input"] = map[string]any{"questions": questions}
	request := decoded(t, requestText("tool-1", "request-1"))
	request["request"].(map[string]any)["input"] = map[string]any{"questions": slices.Clone(questions)}
	if err := peer.host.event(assistant); err != nil {
		t.Fatal(err)
	}
	if err := peer.host.event(request); err != nil {
		t.Fatal(err)
	}
	peer.answer(t, peer.host.pending.id, answers)
	if peer.last()["type"] != "runtime.answer_rejected" {
		t.Fatalf("answers over 16 KiB must be rejected: %v", peer.last())
	}
}

func TestWrongNativeIdentityAndPermissionSuggestionsFailClosed(t *testing.T) {
	peer := newQuestionPeer(t, "", true)
	peer.mustEvent(t, assistantText(questionSession, "tool-1"))
	wrongInput := decoded(t, requestText("tool-1", "request-1"))
	wrongInput["request"].(map[string]any)["input"].(map[string]any)["questions"].([]any)[0].(map[string]any)["question"] = "Changed?"
	suggestions := decoded(t, requestText("tool-1", "request-1"))
	suggestions["request"].(map[string]any)["permission_suggestions"] = []any{map[string]any{"type": "setMode", "mode": "bypassPermissions"}}
	wrongSession := decoded(t, requestText("tool-1", "request-1"))
	wrongSession["session_id"] = "foreign"
	subagent := decoded(t, requestText("tool-1", "request-1"))
	subagent["parent_tool_use_id"] = "subagent"
	numericFlag := decoded(t, requestText("tool-1", "request-1"))
	numericFlag["request"].(map[string]any)["input"].(map[string]any)["questions"].([]any)[0].(map[string]any)["multiSelect"] = json.Number("0")
	for _, test := range []struct {
		record  map[string]any
		message string
	}{
		{decoded(t, requestText("wrong-tool", "request-1")), "Uncorrelated native question request"},
		{wrongInput, "Uncorrelated native question request"},
		{suggestions, "Uncorrelated native question request"},
		{wrongSession, "Native question session changed"},
		{subagent, "Subagent question transport is not supported"},
		// Python's False == 0 correlates, then the input itself is refused.
		{numericFlag, "Invalid native question"},
	} {
		count := len(peer.sent)
		peer.refuse(t, test.record, test.message)
		if peer.host.pending != nil {
			t.Fatal("refused request became pending")
		}
		if test.message != "Native question session changed" && test.message != "Subagent question transport is not supported" &&
			encode(t, peer.sent[len(peer.sent)-1]) != `{"response":{"request_id":"request-1","response":{"behavior":"deny","message":"Runtime refused an invalid native question"},"subtype":"success"},"type":"control_response"}` {
			t.Fatalf("refusal not denied to native: %v", peer.sent[count:])
		}
	}
	drift := decoded(t, assistantText(questionSession, "tool-2"))
	drift["message"].(map[string]any)["model"] = "different-model"
	peer.refuse(t, drift, "Native question assistant identity changed")
}

func TestQuestionInitializationIsCorrelatedAndSingleAssignment(t *testing.T) {
	peer := newQuestionPeer(t, "", true)
	for _, response := range []string{`{"subtype":"success","request_id":"foreign"}`, `{"subtype":"error","request_id":"initialize-fixture"}`,
		`{"subtype":"success","request_id":"initialize-fixture","response":{}}`} {
		peer.refuse(t, decoded(t, `{"type":"control_response","response":`+response+`}`), "Unexpected native initialization response")
	}
	if peer.assignments() != 1 {
		t.Fatalf("assignment resent: %v", peer.sent)
	}
	for _, init := range []string{`"tools":["Read","Glob","Grep","AskUserQuestion","Write"]`,
		`"tools":["Read","Glob","Grep","AskUserQuestion"],"permissionMode":"bypassPermissions"`,
		`"tools":["Read","Glob","Grep",1]`} {
		peer.refuse(t, decoded(t, `{"type":"system","subtype":"init","session_id":"`+questionSession+`","model":"`+questionModel+`",`+init+`}`),
			"Native question initialization identity changed")
	}
	fresh := newQuestionPeer(t, "", false)
	fresh.host.initialized = false
	fresh.refuse(t, decoded(t, `{"type":"control_response","response":{"subtype":"success","request_id":"initialize-fixture","response":{"current_permission_mode":"bypassPermissions"}}}`),
		"Unexpected native initialization response")
	uninitialized := newQuestionPeer(t, "", false)
	uninitialized.host.initialized = false
	uninitialized.refuse(t, decoded(t, `{"type":"system","subtype":"init","session_id":"`+questionSession+`","model":"`+questionModel+`","tools":["Read","Glob","Grep","AskUserQuestion"]}`),
		"Native question initialization identity changed")
}

func TestResumeModelMustMatchNativeInit(t *testing.T) {
	peer := newQuestionPeer(t, "saved-model", false)
	peer.refuse(t, decoded(t, `{"type":"system","subtype":"init","session_id":"`+questionSession+`","model":"`+questionModel+`","tools":["Read","Glob","Grep","AskUserQuestion"]}`),
		"Native question initialization identity changed")
}

func TestContextModifierKeepsExactInitAndAcceptsOnlySameAssistantModel(t *testing.T) {
	configured := "claude-opus-5-5[1m]"
	for _, resumeModel := range []string{"", configured} {
		peer := newQuestionPeer(t, resumeModel, false)
		init := `{"type":"system","subtype":"init","session_id":"` + questionSession + `","model":"%s","tools":["Read","Glob","Grep","AskUserQuestion"]}`
		peer.mustEvent(t, fmt.Sprintf(init, configured))
		peer.refuse(t, decoded(t, fmt.Sprintf(init, "claude-opus-5-5")), "Native question initialization identity changed")
		for _, changed := range []string{"claude-opus-5", "claude-sonnet-5-5", "claude-opus-5-5[2m]", configured + "[1m]"} {
			event := decoded(t, assistantText(questionSession, "tool-1"))
			event["message"].(map[string]any)["model"] = changed
			peer.refuse(t, event, "Native question assistant identity changed")
		}
		event := decoded(t, assistantText(questionSession, "tool-1"))
		event["message"].(map[string]any)["model"] = "claude-opus-5-5"
		if err := peer.host.event(event); err != nil {
			t.Fatal(err)
		}
		peer.mustEvent(t, requestText("tool-1", "request-1"))
		identifier := peer.host.pending.id
		peer.answer(t, identifier, nil)
		peer.mustEvent(t, processedText(questionSession, "tool-1"))
		if peer.host.model != configured || encode(t, peer.last()) != `{"question_id":"`+identifier+`","type":"runtime.answer_processed"}` {
			t.Fatalf("model %q record %v", peer.host.model, peer.last())
		}
	}
}

func TestNonQuestionToolsAreDeniedAndModeUpdatesRefused(t *testing.T) {
	peer := newQuestionPeer(t, "", true)
	for _, tool := range []string{"Bash", "Read", "Write", "Edit"} {
		event := decoded(t, requestText("tool-1", "request-1"))
		event["request"].(map[string]any)["tool_name"] = tool
		if err := peer.host.event(event); err != nil {
			t.Fatal(err)
		}
		if encode(t, peer.sent[len(peer.sent)-1]) != `{"response":{"request_id":"request-1","response":{"behavior":"deny","message":"Runtime does not approve non-question tools"},"subtype":"success"},"type":"control_response"}` {
			t.Fatalf("%s not denied: %v", tool, peer.sent[len(peer.sent)-1])
		}
	}
	for _, subtype := range []string{"set_permission_mode", "mcp_set_servers", "unknown"} {
		peer.refuse(t, decoded(t, `{"type":"control_request","request_id":"mode","request":{"subtype":"`+subtype+`","mode":"bypassPermissions"}}`),
			"Unsupported native control request")
		if encode(t, peer.sent[len(peer.sent)-1]) != `{"response":{"error":"Runtime does not permit native control changes","request_id":"mode","subtype":"error"},"type":"control_response"}` {
			t.Fatalf("%s not refused to native: %v", subtype, peer.sent[len(peer.sent)-1])
		}
	}
	count := len(peer.sent)
	peer.refuse(t, decoded(t, `{"type":"control_request","request_id":"bad","request":{"subtype":"can_use_tool","tool_name":"Bash"}}`),
		"Malformed native permission request")
	peer.refuse(t, decoded(t, `{"type":"control_request","request":{"subtype":"can_use_tool"}}`), "Malformed native permission request")
	if len(peer.sent) != count+1 || peer.sent[count]["response"].(map[string]any)["request_id"] != "bad" {
		t.Fatalf("malformed requests: %v", peer.sent[count:])
	}
	peer.refuse(t, decoded(t, `{"type":"control_cancel_request","request_id":"x"}`), "Native cancelled its pending control request")
	peer.refuse(t, decoded(t, `{"type":"control_other"}`), "Unsupported native control message")
}

func TestBoundedNativeQuestionsRejectDuplicatesAndInvalidOptions(t *testing.T) {
	question := func(field string, value any) any {
		entry := decoded(t, questionText)
		entry[field] = value
		return entry
	}
	options := decoded(t, questionText)["options"].([]any)
	for _, test := range []struct {
		value   any
		message string
	}{
		{"text", "Invalid native question input"},
		{map[string]any{"questions": []any{}, "answers": map[string]any{}}, "Invalid native question input"},
		{map[string]any{"questions": []any{question("header", strings.Repeat("x", 32768))}}, "Invalid native question input"},
		{map[string]any{"questions": []any{}}, "Invalid native question count"},
		{map[string]any{"questions": slices.Repeat([]any{decoded(t, questionText)}, 5)}, "Invalid native question count"},
		{map[string]any{"questions": []any{"text"}}, "Invalid native question fields"},
		{map[string]any{"questions": []any{decoded(t, questionText), decoded(t, questionText)}}, "Invalid native question"},
		{map[string]any{"questions": []any{question("question", strings.Repeat("é", 2049))}}, "Invalid native question"},
		{map[string]any{"questions": []any{question("question", "\u3000\x1f")}}, "Invalid native question"},
		{map[string]any{"questions": []any{question("multiSelect", json.Number("1"))}}, "Invalid native question"},
		{map[string]any{"questions": []any{question("options", options[:1])}}, "Invalid native question options"},
		{map[string]any{"questions": []any{question("options", []any{options[0], map[string]any{"label": " ", "description": "x"}})}}, "Invalid native question option"},
		{map[string]any{"questions": []any{question("options", []any{options[0], map[string]any{"label": "x", "description": nil}})}}, "Invalid native question option"},
	} {
		if _, err := questionInput(test.value); err == nil || err.Error() != test.message {
			t.Errorf("%.100v: wanted %q, got %v", test.value, test.message, err)
		}
	}
	if _, err := questionInput(map[string]any{"questions": []any{question("question", strings.Repeat("é", 2048))}}); err != nil {
		t.Fatalf("4096-byte question refused: %v", err)
	}
}

func TestCancelClearsStateAndRejectsLateAnswer(t *testing.T) {
	peer := newQuestionPeer(t, "", true)
	identifier := peer.pending(t)
	peer.host.cancel()
	peer.answer(t, identifier, nil)
	if !peer.closed || peer.host.pending != nil || peer.host.inflight != nil || peer.last()["type"] != "runtime.answer_rejected" {
		t.Fatalf("cancel left state: %v", peer.last())
	}
}

func TestResultWithoutProcessingAndWrongSessionDoNotClaimProcessed(t *testing.T) {
	peer := newQuestionPeer(t, "", true)
	peer.answer(t, peer.pending(t), nil)
	peer.refuse(t, decoded(t, processedText("foreign", "tool-1")), "Native question session changed")
	failed := decoded(t, processedText(questionSession, "tool-1"))
	failed["message"].(map[string]any)["content"].([]any)[0].(map[string]any)["is_error"] = true
	peer.refuse(t, failed, "Native question processing failed")
	peer.refuse(t, decoded(t, `{"type":"result","session_id":"`+questionSession+`","result":"too early"}`), "Native result ended without processing its question")
	if !peer.closed || slices.Contains(emittedTypes(peer.emitted), "runtime.answer_processed") {
		t.Fatalf("records %v", peer.emitted)
	}
}

func TestUnrelatedParallelResultPreservesInflightQuestion(t *testing.T) {
	peer := newQuestionPeer(t, "", true)
	identifier := peer.pending(t)
	peer.answer(t, identifier, nil)
	inflight := peer.host.inflight
	unrelated := decoded(t, processedText(questionSession, "parallel-read"))
	unrelated["message"].(map[string]any)["content"].([]any)[0].(map[string]any)["is_error"] = true
	if err := peer.host.event(unrelated); err != nil {
		t.Fatal(err)
	}
	if peer.host.inflight != inflight || slices.Contains(emittedTypes(peer.emitted), "runtime.answer_processed") {
		t.Fatal("unrelated tool result changed the inflight question")
	}
	peer.refuse(t, decoded(t, processedText("foreign", "parallel-read")), "session changed")
	peer.mustEvent(t, processedText(questionSession, "tool-1"))
	if peer.host.inflight != nil || encode(t, peer.last()) != `{"question_id":"`+identifier+`","type":"runtime.answer_processed"}` {
		t.Fatalf("processed %v", peer.last())
	}
}

func TestControlRecordsAreBoundedUniqueObjects(t *testing.T) {
	for _, line := range []string{`{"x":"` + strings.Repeat("a", 32768) + `"}`, `{"command":"answer","command":"stop"}`, `[]`} {
		if _, err := jsonRecord([]byte(line), 32768); err == nil {
			t.Errorf("%.60s accepted", line)
		}
	}
}

func TestPythonJSONMatchesPythonDumps(t *testing.T) {
	value := map[string]any{"b": []any{"é\u2028\x7f\x01\n\"\\\\", true, nil, map[string]any{"a": "😀<>&"}}}
	var ascii, compact bytes.Buffer
	pythonJSON(&ascii, value, true)
	pythonJSON(&compact, value, false)
	// Reference bytes from CPython json.dumps(value) and json.dumps(value, ensure_ascii=False, separators=(',', ':')).
	if want := `{"b": ["\u00e9\u2028\u007f\u0001\n\"\\\\", true, null, {"a": "\ud83d\ude00<>&"}]}`; ascii.String() != want {
		t.Fatalf("ascii %s", ascii.String())
	}
	if want := `{"b":["é` + "\u2028\x7f" + `\u0001\n\"\\\\",true,null,{"a":"😀<>&"}]}`; compact.String() != want || canonicalSize(value) != 56 {
		t.Fatalf("compact %s", compact.String())
	}
	if !pythonBlank(" \t\x1c\x1f\u3000\u2028") || pythonBlank(" x\x1c") {
		t.Fatal("blank follows Python str.strip")
	}
}

func TestNativeInputIsBounded(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	if err = writeNative(writer, map[string]any{"goal": strings.Repeat("x", recordLimit)}); err == nil || err.Error() != "Native input exceeds 1 MiB" {
		t.Fatalf("oversized input: %v", err)
	}
	// Python's ensure_ascii escapes count against the bound.
	if err = writeNative(writer, map[string]any{"goal": strings.Repeat("é", recordLimit/6)}); err == nil || err.Error() != "Native input exceeds 1 MiB" {
		t.Fatalf("escaped input: %v", err)
	}
	reader.Close()
	if err = writeNative(writer, map[string]any{"type": "user"}); err == nil || err.Error() != "Native input transport closed" {
		t.Fatalf("closed input: %v", err)
	}
}

func TestQuestionOptInMustBeBooleanAndClaudeOnly(t *testing.T) {
	for _, test := range [][2]string{{"1", "claude"}, {`"true"`, "claude"}, {"true", "codex"}} {
		directory := t.TempDir()
		args := claudeArgs(filepath.Join(directory, "native"), directory)
		args[11], args[8] = test[0], test[1]
		if err := run(args); err == nil || err.Error() != "Questions require a boolean opt-in and the Claude backend" {
			t.Fatalf("%v: %v", test, err)
		}
		if _, err := os.Stat(filepath.Join(directory, "process.json")); err == nil {
			t.Fatal("refused opt-in launched a native process")
		}
	}
}

// questionFixture is the actual subprocess protocol peer; assertions describe fixtures, never provider proof.
func questionFixture(mode string) {
	args := os.Args
	value := func(flag string) string {
		index := slices.Index(args, flag)
		if index < 0 || index+1 >= len(args) {
			return ""
		}
		return args[index+1]
	}
	check := func(ok bool, what string) {
		if !ok {
			fmt.Fprintln(os.Stderr, "question fixture: "+what)
			os.Exit(3)
		}
	}
	tools := strings.Split(value("--tools"), ",")
	check(value("--permission-mode") == "manual" && value("--permission-prompts") == "host" &&
		value("--permission-prompt-tool") == "stdio" && value("--input-format") == "stream-json", "question flags")
	check(slices.Contains(args, "--restricted") && slices.Contains(args, "--safe-mode") &&
		slices.Contains(args, "--strict-mcp-config") && !slices.Contains(args, "--"), "restriction flags")
	check(slices.Contains(tools, "AskUserQuestion") && !slices.Contains(strings.Split(value("--allowedTools"), ","), "AskUserQuestion"), "tools")
	session := value("--session-id")
	check(canonicalUUID.MatchString(session), "fresh session id")
	emit := func(text string) { fmt.Println(text) }
	input := bufio.NewReader(os.Stdin)
	next := func() map[string]any {
		line, err := input.ReadBytes('\n')
		check(err == nil, "native input ended")
		var record map[string]any
		check(json.Unmarshal(line, &record) == nil, "native input record")
		return record
	}
	initial := next()
	check(regexp.MustCompile(`\Ainitialize-[0-9a-f]{32}\z`).MatchString(fmt.Sprint(initial["request_id"])) &&
		fmt.Sprint(initial["request"]) == "map[subtype:initialize]", "initialize")
	// The descendant ignores SIGINT; the host must reap the complete owned process group.
	// Waiting for its trap keeps an early stop from racing the descendant's own exit.
	descendant := exec.Command("/bin/sh", "-c", "trap '' INT; echo ready; exec sleep 30")
	ready, err := descendant.StdoutPipe()
	check(err == nil && descendant.Start() == nil, "descendant")
	_, err = bufio.NewReader(ready).ReadString('\n')
	check(err == nil, "descendant trap")
	check(os.WriteFile(os.Getenv("ATLAS_QUESTION_CHILD"), []byte(strconv.Itoa(descendant.Process.Pid)), 0600) == nil, "child pid")
	emit(`{"type":"control_response","response":{"subtype":"success","request_id":"` + initial["request_id"].(string) + `","response":{}}}`)
	if mode == "stall" {
		// Never read the large assignment, so the host's native input write stalls.
		time.Sleep(30 * time.Second)
		return
	}
	assignment := next()
	check(fmt.Sprint(assignment) == "map[message:map[content:fixture assignment role:user] parent_tool_use_id:<nil> session_id:"+session+" type:user]", "assignment")
	emit(`{"type":"system","subtype":"init","session_id":"` + session + `","model":"` + questionModel + `","tools":` + string(must(json.Marshal(tools))) + `}`)
	source, control := assistantText(session, "tool-1"), requestText("tool-1", "request-1")
	check(os.WriteFile(os.Getenv("ATLAS_QUESTION_SOURCE"), []byte(`{"assistant":`+source+`,"control_request":`+control+
		`,"native_pid":`+strconv.Itoa(os.Getpid())+`}`), 0600) == nil, "question source")
	emit(source)
	emit(control)
	switch mode {
	case "output-loss":
		os.Stdout.Close()
		time.Sleep(30 * time.Second)
		return
	case "malformed-output":
		emit("{broken")
		time.Sleep(30 * time.Second)
		return
	case "oversized-output":
		emit(`{"payload":"` + strings.Repeat("x", recordLimit) + `"}`)
		time.Sleep(30 * time.Second)
		return
	case "native-cancel":
		emit(`{"type":"control_cancel_request","request_id":"request-1"}`)
		time.Sleep(30 * time.Second)
		return
	case "input-loss":
		os.Stdin.Close()
		emit(`{"type":"fixture.input_closed"}`)
		time.Sleep(30 * time.Second)
		return
	}
	line, err := input.ReadBytes('\n')
	if err != nil || mode == "pending" {
		return
	}
	// Python json.dumps formatting; keys are sorted.
	check(string(line) == `{"response": {"request_id": "request-1", "response": {"behavior": "allow", "updatedInput": {"answers": {"Which value?": "436849"}, "questions": [`+
		`{"header": "Value", "multiSelect": false, "options": [{"description": "First", "label": "11"}, {"description": "Second", "label": "23"}], "question": "Which value?"}]}}, "subtype": "success"}, "type": "control_response"}`+"\n", "answer bytes")
	if mode != "early-result" {
		emit(processedText(session, "tool-1"))
	}
	emit(`{"type":"result","session_id":"` + session + `","result":"fixture completed"}`)
	// No successor assignment after this query's terminal result.
	rest, _ := io.ReadAll(input)
	check(len(rest) == 0, "input after result")
	if mode == "result-hang" {
		time.Sleep(30 * time.Second)
	}
}

func must[T any](value T, err error) T {
	if err != nil {
		panic(err)
	}
	return value
}

type questionRun struct {
	host            *hostProcess
	folder, scratch string
	repository      string
}

// launchQuestions starts the host with the test binary as fake native Claude, read-only for an
// empty profile, else in a dedicated repository or materialized folder.
func launchQuestions(t *testing.T, mode string, profile string, goal string) *questionRun {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	run := &questionRun{folder: t.TempDir(), scratch: t.TempDir()}
	t.Setenv("ATLAS_QUESTION_FIXTURE", mode)
	t.Setenv("ATLAS_QUESTION_CHILD", filepath.Join(run.scratch, "child.pid"))
	t.Setenv("ATLAS_QUESTION_SOURCE", filepath.Join(run.scratch, "question-source.json"))
	args := claudeArgs(self, run.folder)
	switch profile {
	case "dedicated-repository":
		_, repository, scope := claudeRepository(t)
		run.repository = repository
		args = claudeScopedArgs(t, self, repository, run.folder, scope)
	case "materialized-folder":
		dest, _, _, scope := claudeFolder(t)
		run.repository = dest
		args = claudeScopedArgs(t, self, dest, run.folder, scope)
	}
	args[3], args[11] = goal, "true"
	run.host = startHost(t, args)
	return run
}

// until reads records until the wanted host or forwarded native record type.
func (run *questionRun) until(t *testing.T, wanted string) (map[string]any, []map[string]any) {
	t.Helper()
	var seen []map[string]any
	for {
		record := run.host.record(t)
		seen = append(seen, record)
		if record["type"] == wanted {
			return record, seen
		}
		if event, ok := record["event"].(map[string]any); ok && event["type"] == wanted {
			return record, seen
		}
	}
}

func (run *questionRun) send(t *testing.T, identifier string) {
	t.Helper()
	if _, err := fmt.Fprintf(run.host.stdin, `{"command":"answer","question_id":%q,"answers":{"Which value?":"436849"}}`+"\n", identifier); err != nil {
		t.Fatal(err)
	}
}

// ended reaps the host and proves the owned group, private temp and lock are gone.
func (run *questionRun) ended(t *testing.T, success bool) []map[string]any {
	t.Helper()
	records, code := run.host.finish(t)
	if (code == 0) != success {
		t.Fatalf("host exit %d; records %v; stderr %s", code, records, run.host.stderr.String())
	}
	var evidence struct {
		PID             int     `json:"pid"`
		NativeTemporary *string `json:"native_temporary"`
	}
	data, err := os.ReadFile(filepath.Join(run.folder, "process.json"))
	if err != nil || json.Unmarshal(data, &evidence) != nil {
		t.Fatalf("process evidence %s: %v", data, err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for syscall.Kill(-evidence.PID, 0) != syscall.ESRCH {
		if time.Now().After(deadline) {
			t.Fatal("owned native process group survived")
		}
		time.Sleep(20 * time.Millisecond)
	}
	assertDead(t, readPID(t, filepath.Join(run.scratch, "child.pid")))
	if evidence.NativeTemporary != nil {
		if _, err := os.Stat(*evidence.NativeTemporary); !os.IsNotExist(err) {
			t.Fatalf("private temp survived: %v", err)
		}
	}
	if run.repository != "" {
		lock, _, err := workspace.Lock(run.repository, false)
		if err != nil {
			t.Fatalf("lock not released: %v", err)
		}
		lock.Close()
	}
	return records
}

func TestReadOnlyAndScopedQueryDeliveryProcessingAndCleanup(t *testing.T) {
	var previous map[string]any
	for _, profile := range []string{"", "dedicated-repository", "materialized-folder"} {
		t.Run(profile, func(t *testing.T) {
			run := launchQuestions(t, "success", profile, "fixture assignment")
			record, before := run.until(t, "runtime.question")
			question := record["question"].(map[string]any)
			identifier := question["id"].(string)
			if !regexp.MustCompile(`\Aquestion-[0-9a-f]{32}\z`).MatchString(identifier) {
				t.Fatalf("question id %q", identifier)
			}
			var source struct {
				Assistant      map[string]any `json:"assistant"`
				ControlRequest map[string]any `json:"control_request"`
				NativePID      float64        `json:"native_pid"`
			}
			data, _ := os.ReadFile(filepath.Join(run.scratch, "question-source.json"))
			if err := json.Unmarshal(data, &source); err != nil {
				t.Fatal(err)
			}
			message := source.Assistant["message"].(map[string]any)
			request := source.ControlRequest["request"].(map[string]any)
			correlation := question["correlation"].(map[string]any)
			if encode(t, correlation) != encode(t, map[string]any{"session_id": source.Assistant["session_id"], "model": message["model"],
				"tool_use_id": message["content"].([]any)[0].(map[string]any)["id"], "request_id": source.ControlRequest["request_id"],
				"native_pid": source.NativePID}) || correlation["tool_use_id"] != request["tool_use_id"] ||
				encode(t, question["questions"]) != encode(t, request["input"].(map[string]any)["questions"]) {
				t.Fatalf("correlation %v source %s", question, data)
			}
			if correlation["native_pid"] != before[0]["pid"] || int(source.NativePID) == run.host.command.Process.Pid {
				t.Fatal("native pid must be the owned group leader, not the host")
			}
			// The question precedes the forwarded permission request it answers.
			for _, record := range before {
				if event, _ := record["event"].(map[string]any); event["type"] == "control_request" {
					t.Fatalf("permission request forwarded before its question: %v", before)
				}
			}
			if previous != nil {
				previousCorrelation := previous["correlation"].(map[string]any)
				if identifier == previous["id"] || correlation["session_id"] == previousCorrelation["session_id"] ||
					correlation["native_pid"] == previousCorrelation["native_pid"] {
					t.Fatal("separate starts must not share question, session or process identity")
				}
			}
			previous = question
			if forwarded := run.host.record(t); forwarded["type"] != "runtime.event" || forwarded["event"].(map[string]any)["type"] != "control_request" {
				t.Fatalf("permission request not forwarded after its question: %v", forwarded)
			}
			run.send(t, identifier)
			delivered, _ := run.until(t, "runtime.answer_delivered")
			processed, _ := run.until(t, "runtime.answer_processed")
			if delivered["question_id"] != identifier || processed["question_id"] != identifier {
				t.Fatalf("delivered %v processed %v", delivered, processed)
			}
			records := run.ended(t, true)
			ended := records[len(records)-1]
			if ended["type"] != "runtime.process_ended" || ended["exit_code"] != 0.0 || ended["stopped"] != false ||
				!slices.ContainsFunc(records, func(r map[string]any) bool {
					event, _ := r["event"].(map[string]any)
					return event["result"] == "fixture completed"
				}) {
				t.Fatalf("records after processing %v", records)
			}
			for _, record := range append(before, records...) {
				if event, _ := record["event"].(map[string]any); event["type"] == "control_response" {
					t.Fatal("native control responses must not be forwarded")
				}
			}
		})
	}
}

func TestTerminalInputEOFDeadlineKillsGroupOnce(t *testing.T) {
	run := launchQuestions(t, "result-hang", "", "fixture assignment")
	record, _ := run.until(t, "runtime.question")
	run.send(t, record["question"].(map[string]any)["id"].(string))
	run.until(t, "runtime.answer_processed")
	records := run.ended(t, true)
	if ended := records[len(records)-1]; ended["type"] != "runtime.process_ended" || ended["exit_code"] != -9.0 || ended["stopped"] != false {
		t.Fatalf("records %v", records)
	}
}

func TestStopAndParentEOFCancelPendingOwnedGroup(t *testing.T) {
	for _, control := range []string{"stop\n", ""} {
		t.Run(strconv.Quote(control), func(t *testing.T) {
			run := launchQuestions(t, "pending", "", "fixture assignment")
			_, before := run.until(t, "runtime.question")
			if control == "" {
				run.host.stdin.Close()
			} else {
				// The fixture's descendant ignores SIGINT: the stop holds until an explicit kill.
				run.host.stdin.Write([]byte(control))
				run.until(t, "runtime.signal")
				run.host.stdin.Write([]byte("kill\n"))
			}
			records := run.ended(t, true)
			if ended := records[len(records)-1]; ended["stopped"] != true ||
				slices.Contains(types(append(before, records...)), "runtime.answer_delivered") {
				t.Fatalf("records %v", records)
			}
		})
	}
}

func TestMalformedUnknownAndDuplicateKeyControlCancelGroup(t *testing.T) {
	for control, message := range map[string]string{
		"{broken\n": "invalid character 'b'",
		`{"command":"set_permission_mode"}` + "\n":                                            "Malformed Runtime answer command",
		`{"command":"answer","command":"stop"}` + "\n":                                        "Duplicate JSON key",
		`{"command":"answer","question_id":"id","answers":{},"updatedPermissions":[]}` + "\n": "Malformed Runtime answer command",
		strings.Repeat("x", 40000):                                                            "Runtime control record exceeds 32 KiB",
	} {
		t.Run(fmt.Sprintf("%.40s", control), func(t *testing.T) {
			run := launchQuestions(t, "pending", "", "fixture assignment")
			run.until(t, "runtime.question")
			run.host.stdin.Write([]byte(control))
			run.ended(t, false)
			if diagnostic := run.host.stderr.String(); diagnostic != "Native runner: "+message+"\n" {
				t.Fatalf("diagnostic %q", diagnostic)
			}
		})
	}
}

func TestTransportLossCancelAndEarlyResultNeverClaimProcessing(t *testing.T) {
	for mode, message := range map[string]string{
		"output-loss":      "Native question transport ended before its result",
		"input-loss":       "Native input transport closed",
		"malformed-output": "invalid character 'b'",
		"oversized-output": "Native (protocol record exceeds its size limit|event exceeds 1 MiB)",
		"native-cancel":    "Native cancelled its pending control request",
		"early-result":     "Native result ended without processing its question",
	} {
		t.Run(mode, func(t *testing.T) {
			run := launchQuestions(t, mode, "", "fixture assignment")
			record, before := run.until(t, "runtime.question")
			identifier := record["question"].(map[string]any)["id"].(string)
			if mode == "input-loss" {
				_, seen := run.until(t, "fixture.input_closed")
				before = append(before, seen...)
			}
			if mode == "input-loss" || mode == "early-result" {
				run.send(t, identifier)
			}
			kinds := types(append(before, run.ended(t, false)...))
			if slices.Contains(kinds, "runtime.answer_processed") || (mode == "input-loss" && slices.Contains(kinds, "runtime.answer_delivered")) {
				t.Fatalf("records %v", kinds)
			}
			if diagnostic := run.host.stderr.String(); !regexp.MustCompile(`\ANative runner: ` + message + "\n\\z").MatchString(diagnostic) {
				t.Fatalf("diagnostic %q", diagnostic)
			}
		})
	}
}

func TestStalledNativeInputFailsWithinBoundAndCleansUp(t *testing.T) {
	for _, profile := range []string{"", "dedicated-repository", "materialized-folder"} {
		t.Run(profile, func(t *testing.T) {
			// The assignment is larger than any pipe buffer, and the fixture never reads it.
			run := launchQuestions(t, "stall", profile, strings.Repeat("x", 512*1024))
			started := time.Now()
			records := run.ended(t, false)
			if elapsed := time.Since(started); elapsed < 3*time.Second || elapsed > 8*time.Second {
				t.Fatalf("stall outside the 3 s bound: %v", elapsed)
			}
			if !slices.Equal(types(records), []string{"runtime.process_started"}) ||
				run.host.stderr.String() != "Native runner: Native input transport stalled\n" {
				t.Fatalf("records %v stderr %q", records, run.host.stderr.String())
			}
		})
	}
}

func TestQuestionCommandUsesHostPermissionPrompts(t *testing.T) {
	want := []string{"claude", "--print", "--output-format", "stream-json", "--verbose", "--restricted", "--safe-mode",
		"--strict-mcp-config", "--no-chrome", "--tools", "Bash,Read,Glob,Grep,AskUserQuestion", "--allowedTools", "Bash,Read,Glob,Grep",
		"--input-format", "stream-json", "--permission-mode", "manual", "--permission-prompts", "host",
		"--permission-prompt-tool", "stdio"}
	if got := claudeCommand("claude", "goal", map[string]any{}, "", "", questionSession); !slices.Equal(got, append(slices.Clone(want), "--session-id", questionSession)) {
		t.Fatalf("fresh %v", got)
	}
	if got := claudeCommand("claude", "goal", map[string]any{}, claudeSession, "m", claudeSession); !slices.Equal(got, append(slices.Clone(want), "--resume", claudeSession, "--model", "m")) {
		t.Fatalf("resume %v", got)
	}
}
