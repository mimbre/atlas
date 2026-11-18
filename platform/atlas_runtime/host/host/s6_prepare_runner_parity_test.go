package host

// S6 package A6: the preparation runner's table test/fixtures/s6/prepare/runner.json.
//
// TestS6PrepareRunnerParity runs every row through the legacy runner, prepare (prepare.go:67-208),
// on the row's materialized folder with stand-in tools, and asserts against expect:
//   - a refusal's exact text;
//   - a repeat (the "prepared once" rule, prepare.go:95-105): the recorded outcome it reports;
//   - a run: the record as begun (read by the stand-in npm while it runs), the codex and npm it
//     runs, the directory, npm's argv (npmArguments / runArguments), the environment
//     (preparationKept and the scratch, read from the private request.json), the scratch's
//     directories and files (seen by the stand-in), the writable outputs, and the A2g setup spec
//     row whose network rule the step's codex sandbox command has.
//
// AtlasRuntime.Sandbox.Preparation.plan/3 must decide the same (test/sandbox/
// preparation_parity_test.exs). The codex permission arguments themselves are A2g's
// (setupArguments, TestS6RenderParity); here the recorded command is only checked to carry
// setupArguments of the expected writable outputs. With ATLAS_S6_WRITE=1 the expect values
// are rewritten from the legacy runner (B2).

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/eyra/atlas/platform/atlas_runtime/host/internal/s6fixture"
	"github.com/eyra/atlas/platform/atlas_runtime/host/snapshot"
	"github.com/eyra/atlas/platform/atlas_runtime/host/workspace"
)

// prepareSetupRows are the A2g setup rows (spec/codex_sandbox.json) each step's plan names.
var prepareSetupRows = map[string]string{"npm-ci": "setup.npm-ci-network", "npm-run": "setup.npm-run-no-network"}

func TestS6PrepareRunnerParity(t *testing.T) {
	path := filepath.Join(s6fixture.Dir(t), "prepare", "runner.json")
	table := s6fixture.MustLoad(t, path)
	if len(table.Rows) == 0 {
		t.Fatalf("%s has no rows", path)
	}
	setup := prepareSetupRendered(t)
	for index := range table.Rows {
		row := &table.Rows[index]
		t.Run(row.ID, func(t *testing.T) {
			got := prepareRunnerRow(t, *row, setup)
			if s6fixture.Writing() {
				row.Expect = got
				return
			}
			if a, b := mustCanonical(t, got), mustCanonical(t, row.Expect); a != b {
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

// prepareSetupRendered is each named setup row's rendered `codex sandbox` command.
func prepareSetupRendered(t *testing.T) map[string][]string {
	t.Helper()
	table := s6fixture.MustLoad(t, filepath.Join(s6fixture.Dir(t), "spec", "codex_sandbox.json"))
	rendered := map[string][]string{}
	for step, id := range prepareSetupRows {
		index := slices.IndexFunc(table.Rows, func(row s6fixture.Row) bool { return row.ID == id })
		if index < 0 {
			t.Fatalf("A2g setup row %s is missing", id)
		}
		row := table.Rows[index]
		input, _ := row.Input.(map[string]any)
		expect, _ := row.Expect.(map[string]any)
		command, _ := expect["rendered"].(map[string]any)["codex_sandbox"].([]any)
		if input["kind"] != "setup" || input["step"] != step || len(command) == 0 {
			t.Fatalf("A2g row %s is not a rendered %s setup row", id, step)
		}
		for _, arg := range command {
			rendered[step] = append(rendered[step], arg.(string))
		}
	}
	return rendered
}

type prepareRunnerInput struct {
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
}

func prepareRunnerRow(t *testing.T, row s6fixture.Row, setup map[string][]string) any {
	root, places := s6fixture.BuildRow(t, row)
	for _, dir := range []string{places["home"], places["user"], filepath.Join(root, "bin"), filepath.Join(root, "log")} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	var input prepareRunnerInput
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
	digest := sha256.Sum256([]byte(input.Dest))
	writeJSON := func(path string, value any) {
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
		writeJSON(filepath.Join(input.Home, "materializations", hex.EncodeToString(digest[:])+".json"),
			map[string]string{"destination": m.Dest, "snapshot_id": m.SnapshotID})
	}
	if input.Recorded != nil {
		// As the helper leaves it: the result beside its private diagnostics directory.
		writeJSON(snapshot.PreparationResult(input.Home, input.Dest), input.Recorded)
		if err = os.Mkdir(snapshot.PreparationDiagnostics(input.Home, input.Dest), 0o700); err != nil {
			t.Fatal(err)
		}
	}

	// The caller's environment: the defaults, then the row's (an empty value unsets).
	environment := map[string]string{"HOME": "{user}", "PATH": "{tmp}/bin"}
	for name, value := range row.Env {
		environment[name] = value
	}
	for _, name := range preparationKept {
		if _, set := environment[name]; !set {
			environment[name] = ""
		}
	}
	for name, value := range environment {
		t.Setenv(name, places.Substitute(value))
		if value == "" {
			os.Unsetenv(name)
		}
	}
	limitCodexConfigWalk(t, root)

	// Stand-ins: codex runs the command after `--` unconfined; npm records the result as begun
	// and the scratch's entries it sees, outside the folder.
	log := filepath.Join(root, "log")
	scratchPrefix := filepath.Join(input.Home, "scratch") + "/prepare-"
	stand := map[string]string{
		"codex": "#!/bin/sh\nwhile [ \"$#\" -gt 0 ] && [ \"$1\" != \"--\" ]; do shift; done\nshift\nexec \"$@\"\n",
		"npm": "#!/bin/sh\n/bin/cp '" + snapshot.PreparationResult(input.Home, input.Dest) + "' '" + log + "/begun.json'\n" +
			"/usr/bin/env | while IFS= read -r line; do value=${line#*=}; case \"$value\" in '" + scratchPrefix + "'*)\n" +
			"  if [ -d \"$value\" ]; then echo \"dir $value\"; elif [ -f \"$value\" ]; then echo \"file $value\"; fi;; esac; done > '" + log + "/scratch.txt'\n",
	}
	for name, script := range stand {
		path := filepath.Join(root, "bin", name)
		if info, err := os.Lstat(path); err == nil && info.Mode().IsRegular() && info.Mode()&0o111 != 0 {
			if err = os.WriteFile(path, []byte(script), 0o755); err != nil {
				t.Fatal(err)
			}
		}
	}

	token := "{sha256:" + places.Abstract(input.Dest) + "}"
	abstract := func(value any, scratch string) any {
		return walkStrings(places.AbstractValue(walkStrings(generic(t, value), func(s string) string {
			if scratch != "" {
				s = strings.ReplaceAll(s, scratch, "$SCRATCH")
			}
			return s
		})), func(s string) string { return strings.ReplaceAll(s, hex.EncodeToString(digest[:]), token) })
	}

	result, err := prepare(input.Home, input.Dest, input.Path, input.Script, input.Outputs)
	// A step that ran has its request in its private diagnostics; a repeat or a refusal has none.
	kind := "npm-ci"
	diagnostics := snapshot.PreparationDiagnostics(input.Home, input.Dest)
	if input.Step == "npm-run" {
		kind, diagnostics = "npm-run", filepath.Join(diagnostics, "npm-run")
	}
	if input.Step != kind {
		t.Fatalf("unknown step %q", input.Step)
	}
	_, requestErr := os.Lstat(filepath.Join(diagnostics, "request.json"))
	begun, readErr := os.ReadFile(filepath.Join(log, "begun.json"))
	if errors.Is(requestErr, os.ErrNotExist) {
		if readErr == nil {
			t.Fatal("npm ran without a recorded request")
		}
		var failure *PreparationFailure
		switch {
		case err == nil:
			return abstract(map[string]any{"repeat": map[string]any{"result": generic(t, result), "error": nil}}, "")
		case errors.As(err, &failure):
			return abstract(map[string]any{"repeat": map[string]any{"result": generic(t, failure.Result()), "error": err.Error()}}, "")
		}
		return abstract(map[string]any{"error": err.Error()}, "")
	} else if readErr != nil {
		t.Fatalf("a recorded run without npm having run: %v", readErr)
	}
	if err != nil || result["ready"] != true {
		t.Fatalf("the run with stand-ins did not succeed: %v %v", result, err)
	}

	// The run's command and environment, as the private request.json records them.
	var begunRecord snapshot.Preparation
	if err = json.Unmarshal(begun, &begunRecord); err != nil {
		t.Fatal(err)
	}
	var request struct {
		Command     []string `json:"command"`
		Environment []string `json:"environment"`
	}
	data, err := os.ReadFile(filepath.Join(begunRecord.Diagnostics(input.Home), "request.json"))
	if err == nil {
		err = json.Unmarshal(data, &request)
	}
	if err != nil {
		t.Fatal(err)
	}
	command := request.Command
	separator := slices.Index(command, "--")
	if len(command) < 7 || separator < 6 || !slices.Equal(command[1:5], []string{"sandbox", "-P", setupProfile, "-C"}) {
		t.Fatalf("not a codex sandbox command: %q", command)
	}
	scratch := ""
	for _, variable := range request.Environment {
		if value, ok := strings.CutPrefix(variable, "TMPDIR="); ok {
			scratch = filepath.Dir(value)
		}
	}
	if !strings.HasPrefix(scratch, scratchPrefix) {
		t.Fatalf("no preparation scratch in %q", request.Environment)
	}
	if _, err = os.Lstat(scratch); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the scratch %s outlived the run", scratch)
	}

	// What the stand-in npm saw in the scratch, in the environment's order.
	kinds := map[string]string{}
	seen, err := os.Open(filepath.Join(log, "scratch.txt"))
	if err != nil {
		t.Fatal(err)
	}
	defer seen.Close()
	for scanner := bufio.NewScanner(seen); scanner.Scan(); {
		kind, path, _ := strings.Cut(scanner.Text(), " ")
		kinds[path] = kind
	}
	scratchEntries := map[string][]any{"dirs": {}, "files": {}}
	for _, variable := range request.Environment {
		_, value, _ := strings.Cut(variable, "=")
		if name, ok := strings.CutPrefix(value, scratch+"/"); ok {
			switch kinds[value] {
			case "dir":
				scratchEntries["dirs"] = append(scratchEntries["dirs"], name)
			case "file":
				scratchEntries["files"] = append(scratchEntries["files"], name)
			default:
				t.Fatalf("scratch entry %s was not there while npm ran", value)
			}
		}
	}

	// The writable outputs as prepare.go:148-151 joins them; the recorded command carries their
	// setupArguments, and the A2g setup row of the step has the command's network rule.
	writable := []string{}
	for _, output := range begunRecord.Outputs {
		writable = append(writable, filepath.Join(begunRecord.Destination, output))
	}
	scope, err := workspace.FolderScopeBeforePreparation(input.Dest, input.Home)
	if err != nil {
		t.Fatal(err)
	}
	user, err := filepath.EvalSymlinks(places["user"])
	if err != nil {
		t.Fatal(err)
	}
	arguments, err := setupArguments(scope, writable, scratch, user, begunRecord.Kind == "npm-ci")
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(command[6:separator], arguments) {
		t.Errorf("the recorded command does not carry setupArguments of %q:\n%q\n%q", writable, command[6:separator], arguments)
	}
	if a, b := networkRule(command), networkRule(setup[begunRecord.Kind]); a == "" || a != b {
		t.Errorf("setup row %s has network %q, the run %q", prepareSetupRows[begunRecord.Kind], b, a)
	}

	if _, err = time.Parse(time.RFC3339, begunRecord.StartedAt); err != nil || begunRecord.State != "running" {
		t.Fatalf("the begun record is not a running one: %s", begun)
	}
	begunRecord.StartedAt = "{now}"
	return abstract(map[string]any{"run": map[string]any{
		"record":    generic(t, &begunRecord),
		"codex":     command[0],
		"dir":       command[5],
		"argv":      command[separator+1:],
		"env":       request.Environment,
		"scratch":   scratchEntries,
		"writable":  writable,
		"setup_row": prepareSetupRows[begunRecord.Kind],
	}}, scratch)
}

// networkRule is the network part of a codex sandbox command's permission profile.
func networkRule(command []string) string {
	for _, arg := range command {
		if strings.HasPrefix(arg, "permissions=") {
			if index := strings.LastIndex(arg, "},network="); index >= 0 {
				return arg[index:]
			}
		}
	}
	return ""
}
