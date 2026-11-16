package s6fixture

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// TestS6FixtureSelfTest builds every _self row, lists it and compares the listing (or the
// refusal) with _self/expect.json, which the Elixir self-test compares with too. Run with
// ATLAS_S6_WRITE=1 to regenerate expect.json from Go (B2); Elixir never writes it.
func TestS6FixtureSelfTest(t *testing.T) {
	dir := filepath.Join(Dir(t), "_self")
	table := MustLoad(t, filepath.Join(dir, "rows.json"))
	expectPath := filepath.Join(dir, "expect.json")
	results := map[string]any{}
	var want map[string]any
	if !Writing() {
		value, err := ReadJSON(expectPath)
		if err != nil {
			t.Fatal(err)
		}
		document, _ := value.(map[string]any)
		want, _ = document["rows"].(map[string]any)
		if document["version"] == nil || want == nil {
			t.Fatalf("%s: want {\"version\": 1, \"rows\": {id: result}}", expectPath)
		}
		ids := []string{}
		for _, row := range table.Rows {
			ids = append(ids, row.ID)
		}
		expected := []string{}
		for id := range want {
			expected = append(expected, id)
		}
		sort.Strings(ids)
		sort.Strings(expected)
		if strings.Join(ids, ",") != strings.Join(expected, ",") {
			t.Fatalf("expect.json ids %v differ from rows.json ids %v", expected, ids)
		}
	}
	for _, row := range table.Rows {
		t.Run(row.ID, func(t *testing.T) {
			root := NewRoot(t)
			places := DefaultPlaces(root)
			result, err := Result(root, places, row.FS)
			if err != nil {
				t.Fatalf("unexpected I/O error: %v", err)
			}
			if row.Input != nil {
				result["input"] = places.AbstractValue(places.SubstituteValue(row.Input))
			}
			if strings.Contains(mustCanonical(t, result), root) {
				t.Fatalf("result leaks the concrete root %s: %s", root, mustCanonical(t, result))
			}
			results[row.ID] = result
			if Writing() {
				return
			}
			got, expected := mustCanonical(t, result), mustCanonical(t, want[row.ID])
			if got != expected {
				t.Fatalf("listing differs from expect.json\n got: %s\nwant: %s", got, expected)
			}
		})
	}
	if Writing() {
		if err := WriteJSON(expectPath, map[string]any{"version": 1, "rows": results}); err != nil {
			t.Fatal(err)
		}
		t.Logf("wrote %s", expectPath)
	}
}

// TestFixtureRootIgnoresTestName checks that NewRoot's length does not depend on the test
// name, as the Elixir root's does not, so a socket entry fits alike on both sides (Y1). It is
// not a TestS6 function: H6 counts only the parity and self-test functions.
func TestFixtureRootIgnoresTestName(t *testing.T) {
	lengths := map[string]int{}
	for _, name := range []string{"a", strings.Repeat("long_row_id_", 8)} {
		t.Run(name, func(t *testing.T) {
			root := NewRoot(t)
			if !strings.HasPrefix(filepath.Base(root), "s6-") || len(filepath.Base(root)) != len("s6-")+12 {
				t.Fatalf("root %s is not <temp>/s6-<12 hex>", root)
			}
			lengths[name] = len(root)
		})
	}
	if len(lengths) != 2 || lengths["a"] != lengths[strings.Repeat("long_row_id_", 8)] {
		t.Fatalf("root length depends on the test name: %v", lengths)
	}
}

// TestGitAcceptsFixtureStub checks that git itself accepts the git stub as a repository root.
// It is not a TestS6 function: H6 counts only the parity and self-test functions.
func TestGitAcceptsFixtureStub(t *testing.T) {
	git, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git not on PATH")
	}
	root := NewRoot(t)
	if err := Build(root, DefaultPlaces(root), []any{map[string]any{"path": "repo", "type": "git"}}); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(git, "-C", filepath.Join(root, "repo"), "rev-parse", "--show-toplevel", "--git-dir", "--git-common-dir")
	command.Env = []string{"HOME=" + root, "GIT_CONFIG_NOSYSTEM=1", "PATH=" + os.Getenv("PATH")}
	output, err := command.CombinedOutput()
	want := filepath.Join(root, "repo") + "\n.git\n.git\n"
	if err != nil || string(output) != want {
		t.Fatalf("git does not accept the stub: %v\n%s", err, output)
	}
}

func mustCanonical(t *testing.T, value any) string {
	t.Helper()
	text, err := Canonical(value)
	if err != nil {
		t.Fatal(err)
	}
	return text
}
