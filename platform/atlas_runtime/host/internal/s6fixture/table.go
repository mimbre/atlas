package s6fixture

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

// Table is one shared parity table, test/fixtures/s6/<decision>/<name>.json (B2).
type Table struct {
	Version int   `json:"version"`
	Rows    []Row `json:"rows"`
}

// Row is one table row. FS, Input and Expect hold placeholders ({tmp}, {home}, {user},
// {temporary}); Expect is written once from Go and never from Elixir (B2).
type Row struct {
	ID            string            `json:"id"`
	FS            []any             `json:"fs,omitempty"`
	Env           map[string]string `json:"env,omitempty"`
	Input         any               `json:"input,omitempty"`
	Expect        any               `json:"expect,omitempty"`
	Elixir        string            `json:"elixir,omitempty"`
	Change        string            `json:"change,omitempty"`
	DetailHasPath bool              `json:"detail_has_path,omitempty"`
	Note          string            `json:"note,omitempty"`
}

// RowID is the id pattern: it survives t.Run and ExUnit test names unchanged.
var RowID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*$`)

// LoadTable reads a table strictly: version 1, only the documented row fields, and unique
// ids matching RowID. Numbers stay json.Number.
func LoadTable(path string) (*Table, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	decoder.UseNumber()
	var table Table
	if err := decoder.Decode(&table); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if decoder.More() {
		return nil, fmt.Errorf("%s: trailing data", path)
	}
	if table.Version != 1 {
		return nil, fmt.Errorf("%s: version must be 1", path)
	}
	seen := map[string]bool{}
	for i, row := range table.Rows {
		if !RowID.MatchString(row.ID) {
			return nil, fmt.Errorf("%s: rows[%d]: invalid id: %q", path, i, row.ID)
		}
		if seen[row.ID] {
			return nil, fmt.Errorf("%s: rows[%d]: duplicate id: %s", path, i, row.ID)
		}
		seen[row.ID] = true
	}
	return &table, nil
}

// ReadJSON decodes a JSON file into generic values, numbers as json.Number.
func ReadJSON(path string) (any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return value, nil
}

// WriteJSON writes value as the checked-in form: two-space indent, no HTML escaping, sorted
// object keys (generic maps) and a final newline.
func WriteJSON(path string, value any) error {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		return err
	}
	return os.WriteFile(path, buffer.Bytes(), 0o644)
}

// Canonical is value's compact JSON with sorted keys, for comparing a result with an expect.
func Canonical(value any) (string, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var generic any
	if err := decoder.Decode(&generic); err != nil {
		return "", err
	}
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(generic); err != nil {
		return "", err
	}
	return string(bytes.TrimRight(buffer.Bytes(), "\n")), nil
}

// Writing reports whether this run regenerates expect values (ATLAS_S6_WRITE=1, B2).
func Writing() bool { return os.Getenv("ATLAS_S6_WRITE") == "1" }

// Dir is test/fixtures/s6, found from the Go module root (the nearest go.mod upwards).
func Dir(t testing.TB) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return filepath.Join(filepath.Dir(dir), "test", "fixtures", "s6")
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("s6fixture: no go.mod above the test's directory")
		}
		dir = parent
	}
}

// MustLoad loads a table or fails the test.
func MustLoad(t testing.TB, path string) *Table {
	t.Helper()
	table, err := LoadTable(path)
	if err != nil {
		t.Fatal(err)
	}
	return table
}

// NewRoot is a fresh canonical (symlink-free) root for one row: os.TempDir()/s6-<12 hex>, the
// shape of the Elixir new_root!. Its length does not depend on the test name (t.TempDir's
// does), so a socket entry fits or not alike on both sides. Its cleanup first makes every
// directory writable again, so a row with a restrictive directory mode is removed too.
func NewRoot(t testing.TB) string {
	t.Helper()
	suffix := make([]byte, 6)
	if _, err := rand.Read(suffix); err != nil {
		t.Fatal(err)
	}
	created := filepath.Join(os.TempDir(), "s6-"+hex.EncodeToString(suffix))
	if err := os.Mkdir(created, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = filepath.WalkDir(created, func(path string, entry fs.DirEntry, err error) error {
			if err == nil && entry.IsDir() {
				_ = os.Chmod(path, 0o700)
			}
			if errors.Is(err, fs.ErrPermission) {
				_ = os.Chmod(path, 0o700)
			}
			return nil
		})
		if err := os.RemoveAll(created); err != nil {
			t.Errorf("s6fixture: removing %s: %v", created, err)
		}
	})
	root, err := filepath.EvalSymlinks(created)
	if err != nil {
		t.Fatal(err)
	}
	return root
}

// BuildRow builds row.FS under a NewRoot and returns the root and its DefaultPlaces.
func BuildRow(t testing.TB, row Row) (string, Places) {
	t.Helper()
	root := NewRoot(t)
	places := DefaultPlaces(root)
	if err := Build(root, places, row.FS); err != nil {
		t.Fatalf("row %s: %v", row.ID, err)
	}
	return root, places
}
