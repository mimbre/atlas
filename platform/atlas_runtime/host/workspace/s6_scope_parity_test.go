package workspace

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/eyra/atlas/platform/atlas_runtime/host/internal/s6fixture"
)

// S6 A1: the legacy Go scope decisions (Scope, FolderScope, PacketScope) against the shared
// tables test/fixtures/s6/scope/{dedicated,folder}.json. The Elixir twin is
// test/sandbox/scope_parity_test.exs, which decides the same rows with AtlasRuntime.Sandbox.Scope
// on the facts of `workspace facts dedicated|folder`. ATLAS_S6_WRITE=1 rewrites the expect values
// from this side (B2).
//
// Row conventions shared with the Elixir test:
//   - env: the baseline below, then the row's env; the value "{unset}" unsets the variable;
//   - input.records: files whose name hashes a destination, which a static fs spec cannot name:
//     {"store": "materialization" | "preparation", "home", "dest", "content"}, written to
//     <home>/materializations/<sha256(dest)>.json or <home>/preparations/<sha256(dest)>/result.json
//     after the fs spec, content substituted, directories 0755, files 0644;
//   - results are abstracted (placeholders), and then each hex(sha256(dest)) of an input.records
//     destination becomes "{sha256:<abstracted dest>}", so record and preparation file names stay
//     stable across temporary roots;
//   - input.profile "review-packet" runs PacketScope (legacy-only, B9).

// s6ScopeEnv is the baseline environment of every scope row, on both sides.
func s6ScopeEnv(places s6fixture.Places) map[string]string {
	return map[string]string{
		"HOME":                places.Substitute("{user}"),
		"XDG_CONFIG_HOME":     places.Substitute("{user}/config"),
		"CODEX_HOME":          places.Substitute("{user}/.codex"),
		"GIT_CONFIG_NOSYSTEM": "1",
		"GIT_CONFIG_GLOBAL":   os.DevNull,
	}
}

func s6ScopeSetEnv(t *testing.T, places s6fixture.Places, row s6fixture.Row) {
	t.Helper()
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if strings.HasPrefix(name, "GIT_") {
			t.Setenv(name, "")
			os.Unsetenv(name)
		}
	}
	set := func(name, value string) {
		t.Setenv(name, value)
		if value == "{unset}" {
			os.Unsetenv(name)
		}
	}
	for name, value := range s6ScopeEnv(places) {
		set(name, value)
	}
	for name, value := range row.Env {
		set(name, places.Substitute(value))
	}
}

func s6ScopeRecords(t *testing.T, places s6fixture.Places, input map[string]any) {
	t.Helper()
	records, _ := input["records"].([]any)
	for _, raw := range records {
		record := raw.(map[string]any)
		home, dest := record["home"].(string), record["dest"].(string)
		digest := fmt.Sprintf("%x", sha256.Sum256([]byte(dest)))
		var path string
		switch record["store"] {
		case "materialization":
			path = filepath.Join(home, "materializations", digest+".json")
		case "preparation":
			path = filepath.Join(home, "preparations", digest, "result.json")
		default:
			t.Fatalf("unknown record store %v", record["store"])
		}
		if err := s6ScopeMkdirs(filepath.Dir(path)); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(record["content"].(string)), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// s6ScopeMkdirs creates directory and its missing parents, each with mode 0755 whatever the umask.
func s6ScopeMkdirs(directory string) error {
	if _, err := os.Lstat(directory); err == nil {
		return nil
	}
	if err := s6ScopeMkdirs(filepath.Dir(directory)); err != nil {
		return err
	}
	if err := os.Mkdir(directory, 0o755); err != nil {
		return err
	}
	return os.Chmod(directory, 0o755)
}

// s6ScopeResult is a decision's result as a table value: the scope, or {"error": text}.
func s6ScopeResult(t *testing.T, places s6fixture.Places, input map[string]any, scope map[string]any, err error) any {
	t.Helper()
	var value any = scope
	if err != nil {
		value = map[string]any{"error": err.Error()}
	}
	text, cerr := s6fixture.Canonical(value)
	if cerr != nil {
		t.Fatal(cerr)
	}
	decoder := json.NewDecoder(bytes.NewReader([]byte(text)))
	decoder.UseNumber()
	var generic any
	if err := decoder.Decode(&generic); err != nil {
		t.Fatal(err)
	}
	digests := map[string]string{}
	records, _ := input["records"].([]any)
	for _, raw := range records {
		dest := raw.(map[string]any)["dest"].(string)
		digests[fmt.Sprintf("%x", sha256.Sum256([]byte(dest)))] = "{sha256:" + places.Abstract(dest) + "}"
	}
	return s6ScopeDigests(places.AbstractValue(generic), digests)
}

func s6ScopeDigests(value any, digests map[string]string) any {
	switch v := value.(type) {
	case string:
		for digest, name := range digests {
			v = strings.ReplaceAll(v, digest, name)
		}
		return v
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = s6ScopeDigests(item, digests)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(v))
		for key, item := range v {
			out[key] = s6ScopeDigests(item, digests)
		}
		return out
	}
	return value
}

func s6ScopeParity(t *testing.T, table string, decide func(input map[string]any) (map[string]any, error)) {
	path := filepath.Join(s6fixture.Dir(t), "scope", table)
	rows := s6fixture.MustLoad(t, path)
	for index := range rows.Rows {
		row := rows.Rows[index]
		t.Run(row.ID, func(t *testing.T) {
			root := s6fixture.NewRoot(t)
			places := s6fixture.DefaultPlaces(root)
			s6ScopeSetEnv(t, places, row)
			limitCodexConfigWalk(t, root)
			if err := s6fixture.Build(root, places, row.FS); err != nil {
				t.Fatalf("fs: %v", err)
			}
			input := places.SubstituteValue(row.Input).(map[string]any)
			s6ScopeRecords(t, places, input)
			scope, err := decide(input)
			got := s6ScopeResult(t, places, input, scope, err)
			text, _ := s6fixture.Canonical(got)
			if strings.Contains(text, root) {
				t.Fatalf("result leaks the concrete root %s: %s", root, text)
			}
			if s6fixture.Writing() {
				rows.Rows[index].Expect = got
				return
			}
			want, _ := s6fixture.Canonical(row.Expect)
			if text != want {
				t.Fatalf("legacy decision differs from the table\n got: %s\nwant: %s", text, want)
			}
		})
	}
	if s6fixture.Writing() {
		if err := s6fixture.WriteJSON(path, rows); err != nil {
			t.Fatal(err)
		}
		t.Logf("wrote %s", path)
	}
}

// TestS6ScopeDedicatedParity asserts every row of scope/dedicated.json on the legacy Scope.
func TestS6ScopeDedicatedParity(t *testing.T) {
	s6ScopeParity(t, "dedicated.json", func(input map[string]any) (map[string]any, error) {
		return Scope(input["path"].(string))
	})
}

// TestS6ScopeFolderParity asserts every row of scope/folder.json on the legacy FolderScope, and
// on PacketScope for the legacy-only review-packet rows (B9).
func TestS6ScopeFolderParity(t *testing.T) {
	s6ScopeParity(t, "folder.json", func(input map[string]any) (map[string]any, error) {
		dest, home := input["dest"].(string), input["home"].(string)
		if input["profile"] == "review-packet" {
			return PacketScope(dest, home)
		}
		return FolderScope(dest, home)
	})
}

// TestS6ScopeFactsArguments covers the argument checks of the two scope facts kinds.
func TestS6ScopeFactsArguments(t *testing.T) {
	for _, test := range []struct {
		name string
		args []string
		want string
	}{
		{"dedicated_without_path", []string{"dedicated"}, "workspace facts dedicated requires one path"},
		{"dedicated_with_two_paths", []string{"dedicated", "/a", "/b"}, "workspace facts dedicated requires one path"},
		{"folder_without_home", []string{"folder", "/a"}, "workspace facts folder requires destination and Runtime home"},
		{"folder_with_three_paths", []string{"folder", "/a", "/b", "/c"}, "workspace facts folder requires destination and Runtime home"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			err := RunFacts(test.args, strings.NewReader(""), &output)
			if err == nil || err.Error() != test.want || output.Len() != 0 {
				t.Fatalf("got %q, %v", output.String(), err)
			}
		})
	}
	t.Run("git_runs_only_in_an_own_git_directory", func(t *testing.T) {
		// With an empty PATH a git run would be reported as an error; a .git file pointing at
		// another repository must not make the facts kind run git there.
		root := s6fixture.NewRoot(t)
		places := s6fixture.DefaultPlaces(root)
		spec := []any{
			map[string]any{"path": "{tmp}/other", "type": "git"},
			map[string]any{"path": "{tmp}/plain/.git", "type": "file", "content": "gitdir: ../other/.git\n"},
		}
		if err := s6fixture.Build(root, places, spec); err != nil {
			t.Fatal(err)
		}
		t.Setenv("PATH", "")
		t.Setenv("CODEX_HOME", filepath.Join(root, "codex"))
		limitCodexConfigWalk(t, root)
		facts := dedicatedFacts(filepath.Join(root, "plain"))
		if facts["rev_parse"] != nil || facts["shared"] != nil || facts["metadata_link"] != nil {
			t.Fatalf("git metadata inspected outside an own .git directory: %v", facts)
		}
		own := dedicatedFacts(filepath.Join(root, "other"))
		if run, _ := own["rev_parse"].(map[string]any); run == nil || run["error"] == nil {
			t.Fatalf("own .git directory: want git run (and fail on the empty PATH), got %v", own["rev_parse"])
		}
	})
	t.Run("relative_folder_is_not_inspected", func(t *testing.T) {
		var output bytes.Buffer
		if err := RunFacts([]string{"folder", "work", "/home"}, strings.NewReader(""), &output); err != nil {
			t.Fatal(err)
		}
		want := `{"dest":"work","dest_absolute":false,"home":"/home","home_absolute":true}` + "\n"
		if output.String() != want {
			t.Fatalf("got %s, want %s", output.String(), want)
		}
	})
}
