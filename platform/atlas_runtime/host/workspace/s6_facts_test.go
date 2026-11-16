package workspace

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Test kinds, registered as a facts_<kind>.go file would register a real one.
func init() {
	Register("s6-test-echo", func(args []string, stdin io.Reader) (any, error) {
		input, err := io.ReadAll(stdin)
		if err != nil {
			return nil, err
		}
		return map[string]any{"args": args, "stdin": string(input)}, nil
	})
	Register("s6-test-refuse", func([]string, io.Reader) (any, error) {
		return nil, errors.New("s6 test kind refused")
	})
}

// TestS6FactsDispatcher covers `workspace facts` through workspace.Run, the entry point the
// command uses (host/main.go), with the process's real stdin.
func TestS6FactsDispatcher(t *testing.T) {
	run := func(t *testing.T, stdin string, args ...string) (string, error) {
		t.Helper()
		path := filepath.Join(t.TempDir(), "stdin")
		if err := os.WriteFile(path, []byte(stdin), 0o600); err != nil {
			t.Fatal(err)
		}
		file, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		defer file.Close()
		previous := os.Stdin
		os.Stdin = file
		defer func() { os.Stdin = previous }()
		var output bytes.Buffer
		err = Run(args, &output)
		return output.String(), err
	}

	t.Run("unknown_kind", func(t *testing.T) {
		output, err := run(t, "", "facts", "nope")
		if err == nil || err.Error() != "unknown facts kind: nope" || output != "" {
			t.Fatalf("got %q, %v", output, err)
		}
	})
	t.Run("missing_kind", func(t *testing.T) {
		output, err := run(t, "", "facts")
		if err == nil || err.Error() != "use workspace facts KIND [ARGUMENT]..." || output != "" {
			t.Fatalf("got %q, %v", output, err)
		}
	})
	t.Run("usage_names_facts", func(t *testing.T) {
		_, err := run(t, "")
		if err == nil || !strings.HasSuffix(err.Error(), "|request|facts") {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("stdin_and_args_reach_the_kind", func(t *testing.T) {
		input := `{"names":["code.json","a&b<c>"]}` + "\n"
		output, err := run(t, input, "facts", "s6-test-echo", "/one path", "two")
		want := `{"args":["/one path","two"],"stdin":"{\"names\":[\"code.json\",\"a&b<c>\"]}\n"}` + "\n"
		if err != nil || output != want {
			t.Fatalf("got %q, %v\nwant %q", output, err, want)
		}
	})
	t.Run("empty_stdin_reaches_the_kind_as_empty", func(t *testing.T) {
		output, err := run(t, "", "facts", "s6-test-echo")
		if err != nil || output != `{"args":[],"stdin":""}`+"\n" {
			t.Fatalf("got %q, %v", output, err)
		}
	})
	t.Run("kind_refusal_passes_through_without_output", func(t *testing.T) {
		output, err := run(t, "", "facts", "s6-test-refuse")
		if err == nil || err.Error() != "s6 test kind refused" || output != "" {
			t.Fatalf("got %q, %v", output, err)
		}
	})
	t.Run("register_refuses_a_second_registration", func(t *testing.T) {
		defer func() {
			if recovered := recover(); recovered != "workspace facts: kind registered twice: s6-test-echo" {
				t.Fatalf("got %v", recovered)
			}
		}()
		Register("s6-test-echo", func([]string, io.Reader) (any, error) { return nil, nil })
	})
	t.Run("register_refuses_an_empty_kind", func(t *testing.T) {
		defer func() {
			if recovered := recover(); recovered != "workspace facts: Register needs a kind and a function" {
				t.Fatalf("got %v", recovered)
			}
		}()
		Register("", nil)
	})
}
