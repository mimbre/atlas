package host

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/eyra/atlas/platform/atlas_runtime/host/internal/s6fixture"
)

// S6 package A5 (plan s6-plan.md): question approval. Each row of
// test/fixtures/s6/questions/*.json (transcripts.json, and limits.json for the size bounds) is a transcript replayed through the legacy
// questionHost (claude_questions.go). Its expect is the ordered actions per step (native
// writes, runtime records, closing native input), the refusal that ends the query, and the
// state after the last step. test/sandbox/question_approval_parity_test.exs replays the same
// rows through AtlasRuntime.Interactions.QuestionApproval and asserts the same expect.
//
// The setup (initialize request, initialization response, first user message and the init
// identity) is transport and A3's identity rule, so it runs before capture starts.
// Question ids are random in Go: the n-th generated id is reported as input.ids[n], and
// input.ids[n] in a later answer command stands for that generated id.
//
// ATLAS_S6_WRITE=1 rewrites every row's expect from Go (B2); Elixir never writes it.

var s6QuestionID = regexp.MustCompile(`\Aquestion-[0-9a-f]{32}\z`)

type s6QuestionInput struct {
	Session   string           `json:"session"`
	Model     string           `json:"model"`
	NativePID json.Number      `json:"native_pid"`
	IDs       []string         `json:"ids"`
	Steps     []map[string]any `json:"steps"`
}

func TestS6QuestionsParity(t *testing.T) {
	paths, err := filepath.Glob(filepath.Join(s6fixture.Dir(t), "questions", "*.json"))
	if err != nil || len(paths) == 0 {
		t.Fatalf("no question tables: %v", err)
	}
	seen := map[string]string{}
	for _, path := range paths {
		table := s6fixture.MustLoad(t, path)
		if len(table.Rows) == 0 {
			t.Fatalf("%s: no rows", path)
		}
		for index := range table.Rows {
			row := &table.Rows[index]
			if other, dup := seen[row.ID]; dup {
				t.Fatalf("row %s is in both %s and %s", row.ID, other, path)
			}
			seen[row.ID] = path
			t.Run(row.ID, func(t *testing.T) {
				if row.Elixir != "" && !strings.HasPrefix(row.Elixir, "skip:") {
					t.Fatalf("elixir field %q", row.Elixir)
				}
				got := s6ReplayQuestions(t, row)
				if s6fixture.Writing() {
					row.Expect = got
					return
				}
				gotText, wantText := s6Canonical(t, got), s6Canonical(t, row.Expect)
				if gotText != wantText {
					t.Fatalf("legacy questionHost differs from expect\n got: %s\nwant: %s", gotText, wantText)
				}
			})
		}
		if s6fixture.Writing() {
			if err := s6fixture.WriteJSON(path, table); err != nil {
				t.Fatal(err)
			}
			t.Logf("wrote %s", path)
		}
	}
}

func s6ReplayQuestions(t *testing.T, row *s6fixture.Row) any {
	t.Helper()
	var input s6QuestionInput
	data, err := json.Marshal(row.Input)
	if err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(&input); err != nil {
		t.Fatalf("row input: %v", err)
	}
	pid, err := strconv.Atoi(input.NativePID.String())
	if err != nil {
		t.Fatalf("native_pid: %v", err)
	}

	var actions []any
	capture := false
	host := &questionHost{session: input.Session, goal: "one assignment", tools: questionTools,
		nativePID: pid, initializeID: "initialize-fixture",
		send: func(record map[string]any) error {
			if capture {
				actions = append(actions, map[string]any{"send": record})
			}
			return nil
		},
		close: func() {
			if capture {
				actions = append(actions, map[string]any{"close": true})
			}
		},
		emit: func(record map[string]any) error {
			if capture {
				actions = append(actions, map[string]any{"emit": record})
			}
			return nil
		}}
	if err = host.start(); err != nil {
		t.Fatal(err)
	}
	for _, setup := range []string{
		`{"type":"control_response","response":{"subtype":"success","request_id":"initialize-fixture","response":{}}}`,
		`{"type":"system","subtype":"init","session_id":` + strconv.Quote(input.Session) + `,"model":` +
			strconv.Quote(input.Model) + `,"tools":["Read","Glob","Grep","AskUserQuestion"]}`,
	} {
		if err = host.event(decoded(t, setup)); err != nil {
			t.Fatalf("setup %s: %v", setup, err)
		}
	}
	capture = true

	// generated[i] is the i-th question id Go generated; it is reported as input.IDs[i].
	var generated []string
	toFixture := func(value any) any {
		return s6MapStrings(value, func(text string) string {
			for i, real := range generated {
				if text == real {
					return input.IDs[i]
				}
			}
			return text
		})
	}
	toReal := func(value any) any {
		return s6MapStrings(value, func(text string) string {
			for i, real := range generated {
				if text == input.IDs[i] {
					return real
				}
			}
			return text
		})
	}

	steps := []any{}
	failed := false
	for number, step := range input.Steps {
		if failed {
			t.Fatalf("step %d follows the refusal that ends the query", number)
		}
		if len(step) != 1 {
			t.Fatalf("step %d: want exactly one of native, answer, cancel", number)
		}
		actions = nil
		var err error
		switch {
		case step["native"] != nil:
			record, ok := step["native"].(map[string]any)
			if !ok {
				t.Fatalf("step %d: native is not an object", number)
			}
			err = host.event(record)
		case step["answer"] != nil:
			command, ok := toReal(step["answer"]).(map[string]any)
			if !ok {
				t.Fatalf("step %d: answer is not an object", number)
			}
			err = host.answer(command)
		case step["cancel"] == true:
			host.cancel()
		default:
			t.Fatalf("step %d: unknown step %v", number, step)
		}
		for _, action := range actions {
			if emitted, ok := action.(map[string]any)["emit"].(map[string]any); ok && emitted["type"] == "runtime.question" {
				id, _ := emitted["question"].(map[string]any)["id"].(string)
				if !s6QuestionID.MatchString(id) {
					t.Fatalf("step %d: question id %q", number, id)
				}
				for _, previous := range generated {
					if previous == id {
						t.Fatalf("step %d: question id %s repeated", number, id)
					}
				}
				if len(generated) == len(input.IDs) {
					t.Fatalf("step %d: more questions than input.ids", number)
				}
				generated = append(generated, id)
			}
		}
		result := map[string]any{"actions": toFixture(s6Generic(t, actions))}
		if err != nil {
			result["error"] = err.Error()
			failed = true
		}
		steps = append(steps, result)
	}
	expect := map[string]any{"steps": steps}
	if !failed {
		id := func(question *question) any {
			if question == nil {
				return nil
			}
			return toFixture(question.id)
		}
		candidate := any(nil)
		if host.candidate != nil {
			candidate = host.candidate.tool
		}
		expect["state"] = map[string]any{"candidate": candidate, "pending": id(host.pending),
			"inflight": id(host.inflight), "last_tool": host.lastTool, "finished": host.finished}
	}
	return s6Generic(t, expect)
}

// s6Generic is value as decoded JSON (numbers json.Number), so it compares and writes like
// a loaded row.
func s6Generic(t *testing.T, value any) any {
	t.Helper()
	text := s6Canonical(t, value)
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	var generic any
	if err := decoder.Decode(&generic); err != nil {
		t.Fatal(err)
	}
	if generic == nil {
		return []any{}
	}
	return generic
}

func s6MapStrings(value any, f func(string) string) any {
	switch value := value.(type) {
	case string:
		return f(value)
	case []any:
		out := make([]any, len(value))
		for i, item := range value {
			out[i] = s6MapStrings(item, f)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(value))
		for key, item := range value {
			out[f(key)] = s6MapStrings(item, f)
		}
		return out
	default:
		return value
	}
}
