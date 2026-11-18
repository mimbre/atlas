package workspace

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/eyra/atlas/platform/atlas_runtime/host/internal/s6fixture"
	"github.com/eyra/atlas/platform/atlas_runtime/host/internal/s6fixture/fakegit"
)

// S6 A4 parity (plan s6-plan.md): the managed-repository request and preparation plan.
//
// test/fixtures/s6/repository/request.json: legacy workspaceRequest == expect. The Elixir side
// (test/sandbox/repository_parity_test.exs) decides the same rows with
// AtlasRuntime.Sandbox.Repository.request on the `workspace facts repository` facts.
//
// test/fixtures/s6/repository/plan.json, per row:
//   - legacy workspace.Prepare, with the fake git, gives expect.log (the git argv log),
//     expect.outcome and expect.marker;
//   - RunPlan executing expect.plan (the plan the Elixir side builds) on a fresh copy of the
//     same tree gives the same log, outcome and marker;
//   - a row whose expect.plan is {"error": text} is refused before any git, with that text.
//
// ATLAS_S6_WRITE=1 rewrites expect (request rows) and expect.log/outcome/marker (plan rows)
// from the legacy Go code. expect.plan is written by the author and never regenerated (B2).

func s6RepositoryTable(t *testing.T, name string) (string, *s6fixture.Table) {
	t.Helper()
	path := filepath.Join(s6fixture.Dir(t), "repository", name)
	return path, s6fixture.MustLoad(t, path)
}

func s6Canonical(t *testing.T, value any) string {
	t.Helper()
	text, err := s6fixture.Canonical(value)
	if err != nil {
		t.Fatal(err)
	}
	return text
}

// s6Copy deep-copies decoded JSON, so a call that mutates its input does not reach the row.
func s6Copy(t *testing.T, value any) any {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var copied any
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.UseNumber()
	if err := decoder.Decode(&copied); err != nil {
		t.Fatal(err)
	}
	return copied
}

// s6GitEnv keeps git off the user's and the system's config (as workspace_test.go does): the
// same environment the Elixir side gives the facts kind.
func s6GitEnv(t *testing.T, places s6fixture.Places) {
	t.Helper()
	t.Setenv("HOME", places["user"])
	t.Setenv("XDG_CONFIG_HOME", places["user"]+"/config")
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	t.Setenv("CODEX_HOME", places["user"]+"/.codex")
}

func s6Write(t *testing.T, path string, table *s6fixture.Table) {
	t.Helper()
	if err := s6fixture.WriteJSON(path, table); err != nil {
		t.Fatal(err)
	}
}

func TestS6RepositoryRequestParity(t *testing.T) {
	path, table := s6RepositoryTable(t, "request.json")
	for index := range table.Rows {
		row := &table.Rows[index]
		t.Run(row.ID, func(t *testing.T) {
			_, places := s6fixture.BuildRow(t, *row)
			s6GitEnv(t, places)
			input, _ := places.SubstituteValue(row.Input).(map[string]any)
			home, _ := input["home"].(string)
			url, _ := input["url"].(string)
			branch, _ := input["branch"].(string)
			result := map[string]any{}
			request, err := workspaceRequest(home, url, branch)
			if err != nil {
				result["error"] = err.Error()
			} else {
				result["request"] = request
			}
			got := places.AbstractValue(s6Copy(t, result))
			if s6fixture.Writing() {
				row.Expect = got
				return
			}
			if s6Canonical(t, got) != s6Canonical(t, row.Expect) {
				t.Fatalf("legacy workspaceRequest differs from expect\n got: %s\nwant: %s", s6Canonical(t, got), s6Canonical(t, row.Expect))
			}
		})
	}
	if s6fixture.Writing() {
		s6Write(t, path, table)
	}
}

// s6PlanRun is what one preparation did: the git calls, the outcome and the marker afterwards.
type s6PlanRun struct {
	Log     []any
	Outcome map[string]any
	Marker  any
}

func s6Marker(t *testing.T, root string) any {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, ".git/atlas-runtime-repository.json"))
	if errors.Is(err, fs.ErrNotExist) || errors.Is(err, os.ErrInvalid) {
		return nil
	}
	var pathError *fs.PathError
	if errors.As(err, &pathError) && strings.Contains(err.Error(), "is a directory") {
		return map[string]any{"directory": true}
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// s6PlanLegacy runs workspace.Prepare on a fresh build of the row.
func s6PlanLegacy(t *testing.T, binary string, row s6fixture.Row) (s6PlanRun, s6fixture.Places) {
	t.Helper()
	root, places := s6fixture.BuildRow(t, row)
	limitCodexConfigWalk(t, root)
	s6GitEnv(t, places)
	input, _ := places.SubstituteValue(s6Copy(t, row.Input)).(map[string]any)
	scope, _ := input["scope"].(map[string]any)
	repository, _ := input["repository"].(map[string]any)
	created, _ := input["created"].(bool)
	repoRoot, _ := scope["root"].(string)
	fake := fakegit.Install(t, binary, root, input["git"])
	original := s6Copy(t, repository).(map[string]any)
	run := s6PlanRun{Outcome: map[string]any{}}
	prepared, err := Prepare(scope, repository, created, fake.Prefix(repoRoot))
	switch _, continuation := original["base_sha"]; {
	case err != nil:
		run.Outcome["error"] = err.Error()
	case continuation:
		if !reflect.DeepEqual(prepared, original) {
			t.Fatalf("legacy continuation changed the repository record: %v", prepared)
		}
		run.Outcome["continued"] = true
	default:
		rest := map[string]any{}
		for key, value := range prepared {
			if key != "base_sha" {
				rest[key] = value
			}
		}
		if !reflect.DeepEqual(rest, original) {
			t.Fatalf("legacy preparation changed more than base_sha: %v", prepared)
		}
		run.Outcome["base_sha"] = prepared["base_sha"]
	}
	run.Log = fake.Calls(t)
	if repoRoot != "" && filepath.IsAbs(repoRoot) {
		run.Marker = s6Marker(t, repoRoot)
	}
	return run, places
}

// s6PlanExecutor runs RunPlan on expect.plan, on another fresh build of the row.
func s6PlanExecutor(t *testing.T, binary string, row s6fixture.Row, plan any) (s6PlanRun, s6fixture.Places) {
	t.Helper()
	root, places := s6fixture.BuildRow(t, row)
	limitCodexConfigWalk(t, root)
	s6GitEnv(t, places)
	input, _ := places.SubstituteValue(s6Copy(t, row.Input)).(map[string]any)
	scope, _ := input["scope"].(map[string]any)
	created, _ := input["created"].(bool)
	repoRoot, _ := scope["root"].(string)
	data, err := json.Marshal(places.SubstituteValue(plan))
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeRepositoryPlan(data)
	if err != nil {
		t.Fatalf("expect.plan does not decode: %v", err)
	}
	fake := fakegit.Install(t, binary, root, input["git"])
	run := s6PlanRun{Outcome: map[string]any{}}
	result, err := RunPlan(decoded, repoRoot, created, fake.Prefix(repoRoot))
	switch {
	case err != nil:
		run.Outcome["error"] = err.Error()
	case result.Resolved:
		run.Outcome["base_sha"] = result.BaseSHA
	default:
		run.Outcome["continued"] = true
	}
	run.Log = fake.Calls(t)
	run.Marker = s6Marker(t, repoRoot)
	return run, places
}

func (run s6PlanRun) abstract(t *testing.T, places s6fixture.Places) map[string]any {
	t.Helper()
	return places.AbstractValue(s6Copy(t, map[string]any{"log": run.Log, "outcome": run.Outcome, "marker": run.Marker})).(map[string]any)
}

func TestS6RepositoryPlanParity(t *testing.T) {
	path, table := s6RepositoryTable(t, "plan.json")
	binary := fakegit.Build(t)
	for index := range table.Rows {
		row := &table.Rows[index]
		t.Run(row.ID, func(t *testing.T) {
			expect, _ := row.Expect.(map[string]any)
			plan, hasPlan := expect["plan"].(map[string]any)
			if !hasPlan {
				t.Fatal("row has no expect.plan (written by the author)")
			}
			legacyRun, legacyPlaces := s6PlanLegacy(t, binary, *row)
			legacy := legacyRun.abstract(t, legacyPlaces)
			if s6fixture.Writing() {
				written := map[string]any{"plan": plan}
				for key, value := range legacy {
					written[key] = value
				}
				row.Expect = written
				expect = written
			}
			want := map[string]any{"log": expect["log"], "outcome": expect["outcome"], "marker": expect["marker"]}
			if s6Canonical(t, legacy) != s6Canonical(t, want) {
				t.Fatalf("legacy Prepare differs from expect\n got: %s\nwant: %s", s6Canonical(t, legacy), s6Canonical(t, want))
			}
			if refusal, refused := plan["error"]; refused {
				// The plan decision refuses before any git runs, with the text Prepare gives.
				if len(plan) != 1 || len(legacyRun.Log) != 0 || s6Canonical(t, map[string]any{"error": refusal}) != s6Canonical(t, expect["outcome"]) {
					t.Fatalf("expect.plan refusal %v disagrees with the legacy outcome %v and log %v", refusal, expect["outcome"], legacyRun.Log)
				}
				return
			}
			executorRun, executorPlaces := s6PlanExecutor(t, binary, *row, plan)
			executor := executorRun.abstract(t, executorPlaces)
			if s6Canonical(t, executor) != s6Canonical(t, want) {
				t.Fatalf("RunPlan(expect.plan) differs from expect\n got: %s\nwant: %s", s6Canonical(t, executor), s6Canonical(t, want))
			}
		})
	}
	if s6fixture.Writing() {
		s6Write(t, path, table)
	}
}

// TestS6RepositoryPlanDecoding: the executor runs only a well-formed plan. Go-only rows: the
// plan document is the helper's input format, not a shared decision.
func TestS6RepositoryPlanDecoding(t *testing.T) {
	_, table := s6RepositoryTable(t, "plan.json")
	var valid map[string]any
	for _, row := range table.Rows {
		if row.ID == "fresh_clone" {
			valid = row.Expect.(map[string]any)["plan"].(map[string]any)
		}
	}
	if valid == nil {
		t.Fatal("plan.json has no fresh_clone row")
	}
	mutate := func(change func(plan map[string]any)) []byte {
		plan := s6Copy(t, valid).(map[string]any)
		change(plan)
		data, err := json.Marshal(plan)
		if err != nil {
			t.Fatal(err)
		}
		return data
	}
	step := func(plan map[string]any, list string, index int) map[string]any {
		return plan[list].([]any)[index].(map[string]any)
	}
	for _, test := range []struct {
		name, want string
		data       []byte
	}{
		{"valid", "", mutate(func(map[string]any) {})},
		{"version_2", "Invalid repository plan: version must be 1", mutate(func(p map[string]any) { p["version"] = 2 })},
		{"unknown_field", `Invalid repository plan: json: unknown field "shell"`, mutate(func(p map[string]any) { p["shell"] = true })},
		{"missing_git_env", "Invalid repository plan: missing field git_env", mutate(func(p map[string]any) { delete(p, "git_env") })},
		{"bad_git_env", `Invalid repository plan: git_env entry is not NAME=VALUE: "GIT_TERMINAL_PROMPT"`, mutate(func(p map[string]any) { p["git_env"] = []any{"GIT_TERMINAL_PROMPT"} })},
		{"unknown_step", `Invalid repository plan: when_created[0]: unknown step "reset_hard"`, mutate(func(p map[string]any) { step(p, "when_created", 0)["step"] = "reset_hard" })},
		{"field_not_allowed", "Invalid repository plan: when_created[1]: field args is not allowed for expect_scope", mutate(func(p map[string]any) { step(p, "when_created", 1)["args"] = []any{"x"} })},
		{"missing_error", "Invalid repository plan: when_existing[0]: expect_marker requires error", mutate(func(p map[string]any) { delete(step(p, "when_existing", 0), "error") })},
		{"empty_args", "Invalid repository plan: when_created[0]: clone requires args", mutate(func(p map[string]any) { step(p, "when_created", 0)["args"] = []any{} })},
		{"marker_escapes", "Invalid repository plan: when_created[2]: path must be relative inside the repository", mutate(func(p map[string]any) { step(p, "when_created", 2)["path"] = "../marker.json" })},
		{"marker_absolute", "Invalid repository plan: when_existing[0]: path must be relative inside the repository", mutate(func(p map[string]any) { step(p, "when_existing", 0)["path"] = "/tmp/marker.json" })},
		{"bad_pattern", "Invalid repository plan: when_created[7]: error parsing regexp: missing closing ): `(`", mutate(func(p map[string]any) { step(p, "when_created", 7)["pattern"] = "(" })},
		{"checkout_before_base", "Invalid repository plan: when_created[3]: checkout_new before resolve_base", mutate(func(p map[string]any) {
			list := p["when_created"].([]any)
			p["when_created"] = append(append([]any{}, list[:3]...), list[8])
		})},
		{"trailing_data", "Invalid repository plan: trailing data", append(mutate(func(map[string]any) {}), []byte(" {}")...)},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := DecodeRepositoryPlan(test.data)
			got := ""
			if err != nil {
				got = err.Error()
			}
			if got != test.want {
				t.Fatalf("DecodeRepositoryPlan = %q, want %q", got, test.want)
			}
		})
	}
}
