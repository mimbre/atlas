package host

// S6 package A3: the shared resume tables (test/fixtures/s6/resume) asserted against today's Go
// decisions. Elixir asserts the same rows against AtlasRuntime.Sandbox.Resume
// (test/sandbox/resume_parity_test.exs). Expect values are written from here only (B2):
// ATLAS_S6_WRITE=1 go test ./host -run '^TestS6Resume'.

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/eyra/atlas/platform/atlas_runtime/host/internal/s6fixture"
)

// s6ResumeSentinel is the first failure run reaches after every pre-launch check passed
// (deniedRuntimeHome, host.go:116), before it creates, opens or starts anything.
const s6ResumeSentinel = "ATLAS_RUNTIME_HOME must be an absolute path"

func s6ResumeTable(t *testing.T, name string) (string, *s6fixture.Table) {
	t.Helper()
	path := filepath.Join(s6fixture.Dir(t), "resume", name)
	return path, s6fixture.MustLoad(t, path)
}

func s6ResumeFinish(t *testing.T, path string, table *s6fixture.Table) {
	t.Helper()
	if s6fixture.Writing() && !t.Failed() {
		if err := s6fixture.WriteJSON(path, table); err != nil {
			t.Fatal(err)
		}
	}
}

// s6ResumeAssert compares a legacy result with the row's expect, or records it when writing.
// A change row (B2 `change`) keeps its new result in expect and the legacy one in expect.legacy.
func s6ResumeAssert(t *testing.T, row *s6fixture.Row, got any) {
	t.Helper()
	if s6fixture.Writing() {
		if row.Change == "" {
			row.Expect = got
			return
		}
		expect, _ := row.Expect.(map[string]any)
		if expect == nil {
			expect = map[string]any{}
		}
		expect["legacy"] = got
		row.Expect = expect
		return
	}
	want := row.Expect
	if row.Change != "" {
		expect, _ := row.Expect.(map[string]any)
		want = expect["legacy"]
		rest := map[string]any{}
		for key, value := range expect {
			if key != "legacy" {
				rest[key] = value
			}
		}
		if len(rest) == 0 || s6Canonical(t, rest) == s6Canonical(t, want) {
			t.Fatalf("change row %s must hold a new expect that differs from expect.legacy", row.ID)
		}
	}
	if want == nil {
		t.Fatalf("row %s has no expect; write it with ATLAS_S6_WRITE=1", row.ID)
	}
	if got, want := s6Canonical(t, got), s6Canonical(t, want); got != want {
		t.Fatalf("legacy Go decision\n got %s\nwant %s", got, want)
	}
}

// s6ResumeLegacyOnly marks a row Elixir skips (B9 and helper-kept rules) after Go asserted it.
func s6ResumeLegacyOnly(t *testing.T, row *s6fixture.Row) {
	if row.Elixir != "" && !s6fixture.Writing() {
		t.Skip("legacy-only: " + row.Elixir)
	}
}

func s6Canonical(t *testing.T, value any) string {
	t.Helper()
	text, err := s6fixture.Canonical(value)
	if err != nil {
		t.Fatal(err)
	}
	return text
}

func s6String(t *testing.T, fields map[string]any, key string) string {
	t.Helper()
	text, ok := fields[key].(string)
	if !ok {
		t.Fatalf("input %s must be a string", key)
	}
	return text
}

func s6Argument(t *testing.T, value any) string {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}

// TestS6ResumeValidateParity: claudeValidate (claude.go:31-55) and the argument checks of
// run (host.go:76-101), through run itself, with the argv native.ex builds.
func TestS6ResumeValidateParity(t *testing.T) {
	path, table := s6ResumeTable(t, "validate.json")
	for index := range table.Rows {
		row := &table.Rows[index]
		t.Run(row.ID, func(t *testing.T) {
			root, places := s6fixture.BuildRow(t, *row)
			input, _ := places.SubstituteValue(row.Input).(map[string]any)
			if fields, _ := input["scope"].(map[string]any); fields != nil {
				if _, present := fields["home"]; present && fields["home"] != "" {
					t.Fatal("a scope home would bypass the sentinel; this table has none")
				}
			}
			// run unsets it again (host.go:643); t.Setenv restores the caller's value.
			t.Setenv("ATLAS_RUNTIME_HOME", "s6-relative-sentinel")
			err := run([]string{filepath.Join(root, "absent", "native"), s6String(t, input, "workspace"),
				filepath.Join(root, "absent-turn"), "s6 fixture goal", s6String(t, input, "sandbox"),
				s6String(t, input, "session"), s6Argument(t, input["scope"]), s6Argument(t, input["repository"]),
				s6String(t, input, "backend"), s6Argument(t, input["model"]), s6Argument(t, input["context"]),
				s6Argument(t, input["questions"])})
			var got any
			switch {
			case err == nil:
				t.Fatal("run launched past its checks")
			case err.Error() == s6ResumeSentinel:
				got = map[string]any{"ok": true}
			default:
				got = map[string]any{"error": err.Error()}
			}
			s6ResumeAssert(t, row, places.AbstractValue(got))
			s6ResumeLegacyOnly(t, row)
		})
	}
	s6ResumeFinish(t, path, table)
}

type s6Protocol interface {
	event(map[string]any) error
	complete(stopped bool) error
}

// s6Parse is host.go's parse order (host.go:445-466): question checks first, except for
// runtime.repository_prepared; a control_response stops there; then the provider protocol.
func s6Parse(questions *questionHost, protocol s6Protocol, record map[string]any) error {
	if questions != nil && record["type"] != "runtime.repository_prepared" {
		if err := questions.event(record); err != nil {
			return err
		}
		if record["type"] == "control_response" {
			return nil
		}
	}
	return protocol.event(record)
}

func s6Verdict(err error) any {
	if err != nil {
		return map[string]any{"refuse": err.Error()}
	}
	return "continue"
}

// TestS6ResumeVerdictParity: claudeProtocol (claude.go:139-176), codexProtocol
// (codex.go:571-593) and the question session's identity (claude_questions.go:116-165),
// over record transcripts. Records pass through jsonRecord as the host decodes them.
func TestS6ResumeVerdictParity(t *testing.T) {
	path, table := s6ResumeTable(t, "verdict.json")
	for index := range table.Rows {
		row := &table.Rows[index]
		t.Run(row.ID, func(t *testing.T) {
			_, places := s6fixture.BuildRow(t, *row)
			input, _ := places.SubstituteValue(row.Input).(map[string]any)
			start, _ := input["start"].(map[string]any)
			records, _ := input["records"].([]any)
			stopped, isBool := input["stopped"].(bool)
			if start == nil || records == nil || !isBool {
				t.Fatal("input needs start, records and stopped")
			}
			backend, session := s6String(t, start, "backend"), s6String(t, start, "session")
			model, _ := start["model"].(string)
			var protocol s6Protocol = &claudeProtocol{session: session, model: model}
			if backend == "codex" {
				protocol = &codexProtocol{session: session}
			}
			var questions *questionHost
			if start["question_session"] != nil {
				var tools []string
				for _, tool := range start["tools"].([]any) {
					tools = append(tools, tool.(string))
				}
				resumeModel := ""
				if session != "" {
					resumeModel = model
				}
				questions = &questionHost{session: s6String(t, start, "question_session"), goal: "s6 fixture goal",
					tools: tools, resumeModel: resumeModel, nativePID: 7319, initializeID: "initialize-fixture",
					send:  func(map[string]any) error { return nil },
					close: func() {},
					emit:  func(map[string]any) error { return nil }}
				if err := questions.start(); err != nil {
					t.Fatal(err)
				}
			}
			verdicts := []any{}
			got := map[string]any{"verdicts": verdicts}
			refused := false
			for _, raw := range records {
				record, err := jsonRecord([]byte(s6Argument(t, raw)), recordLimit)
				if err != nil {
					t.Fatal(err)
				}
				err = s6Parse(questions, protocol, record)
				verdicts = append(verdicts, s6Verdict(err))
				if refused = err != nil; refused {
					break
				}
			}
			got["verdicts"] = verdicts
			if !refused {
				got["complete"] = s6Verdict(protocol.complete(stopped))
			}
			s6ResumeAssert(t, row, places.AbstractValue(got))
			s6ResumeLegacyOnly(t, row)
		})
	}
	s6ResumeFinish(t, path, table)
}

// s6UUID4Bits applies uuid4's version and variant bits (claude_questions.go:46-52).
func s6UUID4Bits(value []byte) []byte {
	value = bytes.Clone(value)
	value[6] = value[6]&0x0f | 0x40
	value[8] = value[8]&0x3f | 0x80
	return value
}

// TestS6ResumeQuestionSessionParity: the question session id a fresh question turn gets
// (host.go:149-151): uuidString(uuid4()). Elixir's generator takes the 16 random bytes as input.
func TestS6ResumeQuestionSessionParity(t *testing.T) {
	// uuid4 keeps every random bit outside version and variant: its output is a fixpoint.
	for range 256 {
		value := uuid4()
		if !bytes.Equal(s6UUID4Bits(value), value) || !canonicalUUID.MatchString(uuidString(value)) {
			t.Fatalf("uuid4 %x is not what s6UUID4Bits describes", value)
		}
	}
	path, table := s6ResumeTable(t, "question_session.json")
	for index := range table.Rows {
		row := &table.Rows[index]
		t.Run(row.ID, func(t *testing.T) {
			input, _ := row.Input.(map[string]any)
			random, err := hex.DecodeString(s6String(t, input, "random"))
			if err != nil || len(random) != 16 {
				t.Fatal("random must be 16 bytes of hex")
			}
			session := uuidString(s6UUID4Bits(random))
			if !canonicalUUID.MatchString(session) || session[14] != '4' || !bytes.ContainsRune([]byte("89ab"), rune(session[19])) {
				t.Fatalf("%s is not a version 4, RFC 4122 variant UUID", session)
			}
			s6ResumeAssert(t, row, map[string]any{"question_session": session})
		})
	}
	s6ResumeFinish(t, path, table)
}
