package workspace

// S6 package A6: the prepare-step tables test/fixtures/s6/prepare/plan.json and ready.json.
//
// TestS6PrepareParity runs every plan row through the legacy decision, the exported
// snapshot.PlanNPMCI / PlanNPMRun, on the row's materialized folder, and asserts its record (or
// exact refusal) against expect; AtlasRuntime.Sandbox.Preparation.begin_record/3 must produce
// the same (test/sandbox/preparation_parity_test.exs). It also runs the facts kind `prepare` on
// every row: the facts never refuse, whatever the decision is.
//
// TestS6PrepareReadiness runs every readiness row through snapshot.LoadPreparation and
// (*Preparation).Ready / NotReady; Preparation.load/3, ready?/1 and not_ready_text/2 must agree.
//
// With ATLAS_S6_WRITE=1 the expect values are rewritten from the legacy decision (B2).

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eyra/atlas/platform/atlas_runtime/host/internal/s6fixture"
	"github.com/eyra/atlas/platform/atlas_runtime/host/snapshot"
)

func TestS6PrepareParity(t *testing.T) {
	runPrepareTable(t, "plan.json", preparePlanRow)
}

func TestS6PrepareReadiness(t *testing.T) {
	runPrepareTable(t, "ready.json", prepareReadinessRow)
}

func runPrepareTable(t *testing.T, name string, run func(*testing.T, s6fixture.Row) any) {
	path := filepath.Join(s6fixture.Dir(t), "prepare", name)
	table := s6fixture.MustLoad(t, path)
	if len(table.Rows) == 0 {
		t.Fatalf("%s has no rows", path)
	}
	for index := range table.Rows {
		row := &table.Rows[index]
		t.Run(row.ID, func(t *testing.T) {
			if row.Elixir != "" && !strings.HasPrefix(row.Elixir, "skip:") {
				t.Fatalf("elixir field %q is not skip:<reason>", row.Elixir)
			}
			got := run(t, *row)
			if s6fixture.Writing() {
				row.Expect = got
				return
			}
			if a, b := prepareCanonical(t, got), prepareCanonical(t, row.Expect); a != b {
				t.Errorf("\ngot  %s\nwant %s", a, b)
			}
		})
	}
	if s6fixture.Writing() {
		if err := s6fixture.WriteJSON(path, table); err != nil {
			t.Fatal(err)
		}
	}
}

func prepareCanonical(t *testing.T, value any) string {
	t.Helper()
	text, err := s6fixture.Canonical(value)
	if err != nil {
		t.Fatal(err)
	}
	return text
}

// prepareRowInput is a prepare row's input after substitution: the folder, home and package path,
// the step, and what the harness writes (the materialization record, the recorded result).
type prepareRowInput struct {
	Dest         string   `json:"dest"`
	Home         string   `json:"home"`
	Path         string   `json:"path"`
	Step         string   `json:"step"`
	Script       string   `json:"script"`
	Outputs      []string `json:"outputs"`
	Materialized *struct {
		Dest       string `json:"dest"`
		SnapshotID string `json:"snapshot_id"`
	} `json:"materialized"`
	Recorded any `json:"recorded"`
	Record   any `json:"record"`
}

// setUpPrepareRow builds the row's tree, writes its materialization record and recorded
// preparation result where the helper keeps them (both are named by the hash of the folder's
// path), and returns the substituted input and the row's abstraction.
func setUpPrepareRow(t testing.TB, row s6fixture.Row) (prepareRowInput, func(any) any) {
	t.Helper()
	_, places := s6fixture.BuildRow(t, row)
	var input prepareRowInput
	body, err := json.Marshal(places.SubstituteValue(row.Input))
	if err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	decoder.UseNumber()
	if err = decoder.Decode(&input); err != nil {
		t.Fatalf("row %s input: %v", row.ID, err)
	}
	for _, dir := range []string{places["home"], places["user"]} {
		if err = os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	write := func(path string, value any) {
		data, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		if err = os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if m := input.Materialized; m != nil {
		write(filepath.Join(input.Home, "materializations", hexSum(m.Dest)+".json"),
			map[string]string{"destination": m.Dest, "snapshot_id": m.SnapshotID})
	}
	if input.Recorded != nil {
		// As the helper leaves it: the result beside its private diagnostics directory.
		write(snapshot.PreparationResult(input.Home, input.Dest), input.Recorded)
		if err = os.Mkdir(snapshot.PreparationDiagnostics(input.Home, input.Dest), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	token, digest := "{sha256:"+places.Abstract(input.Dest)+"}", hexSum(input.Dest)
	abstract := func(value any) any {
		return mapPrepareStrings(places.AbstractValue(value), func(s string) string { return strings.ReplaceAll(s, digest, token) })
	}
	return input, abstract
}

func hexSum(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func mapPrepareStrings(value any, f func(string) string) any {
	switch v := value.(type) {
	case string:
		return f(v)
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = mapPrepareStrings(item, f)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(v))
		for key, item := range v {
			out[key] = mapPrepareStrings(item, f)
		}
		return out
	}
	return value
}

// genericRecord is a Preparation as its JSON, with a fresh started_at replaced by "{now}".
func genericRecord(t testing.TB, p *snapshot.Preparation) any {
	t.Helper()
	if _, err := time.Parse(time.RFC3339, p.StartedAt); err != nil {
		t.Fatalf("started_at %q is not RFC 3339", p.StartedAt)
	}
	p.StartedAt = "{now}"
	return genericJSON(t, p)
}

func genericJSON(t testing.TB, value any) any {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var generic any
	if err = decoder.Decode(&generic); err != nil {
		t.Fatal(err)
	}
	return generic
}

func preparePlanRow(t *testing.T, row s6fixture.Row) any {
	input, abstract := setUpPrepareRow(t, row)

	// The facts never refuse a well-formed request, whatever the decision will be (B4).
	stdin, err := json.Marshal(map[string]any{"outputs": nonNil(input.Outputs), "tools": []string{}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = prepareFacts([]string{input.Dest, input.Home, input.Path}, bytes.NewReader(stdin)); err != nil {
		t.Errorf("facts kind prepare refused: %v", err)
	}

	var plan *snapshot.Preparation
	switch input.Step {
	case "npm-ci":
		plan, err = snapshot.PlanNPMCI(input.Home, input.Dest, input.Path)
	case "npm-run":
		plan, err = snapshot.PlanNPMRun(input.Home, input.Dest, input.Path, input.Script, input.Outputs)
	default:
		t.Fatalf("unknown step %q", input.Step)
	}
	if err != nil {
		return abstract(map[string]any{"error": err.Error()})
	}
	return abstract(map[string]any{"record": genericRecord(t, plan)})
}

func nonNil(list []string) []string {
	if list == nil {
		return []string{}
	}
	return list
}

func prepareReadinessRow(t *testing.T, row s6fixture.Row) any {
	input, abstract := setUpPrepareRow(t, row)
	path := snapshot.PreparationResult(input.Home, input.Dest)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(input.Record)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	p, err := snapshot.LoadPreparation(input.Home, input.Dest)
	switch {
	case err != nil:
		return abstract(map[string]any{"error": err.Error()})
	case p == nil:
		t.Fatal("a written result loaded as never prepared")
	case p.Ready():
		return abstract(map[string]any{"ready": true})
	}
	return abstract(map[string]any{"ready": false, "not_ready": p.NotReady(input.Home).Error()})
}
