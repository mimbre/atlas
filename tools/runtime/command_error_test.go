package main

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"testing"

	"github.com/eyra/atlas/tools/runtime/snapshot"
)

// The outer error supplies context while retaining the typed refusal underneath.
// This injects the error at the serialization boundary, without packet validation.
type contextualRefusal struct{ cause error }

func (e contextualRefusal) Error() string { return "findings command refused" }
func (e contextualRefusal) Unwrap() error { return e.cause }

// Also invoked by the BEAM consumer regression as a real subprocess. It uses the
// production CLI serializer, but does not claim to exercise packet ingestion.
func TestCommandErrorProcess(t *testing.T) {
	code := os.Getenv("ATLAS_TEST_COMMAND_ERROR")
	if code == "" {
		return
	}
	var err error = errors.New("unclassified command failure")
	if code != "unknown" {
		err = contextualRefusal{&snapshot.FindingsRefusal{Code: code}}
	}
	writeCommandError(os.Stdout, err)
	os.Exit(1)
}

func TestCommandErrorSerialization(t *testing.T) {
	for _, code := range []string{"findings_missing", "findings_invalid", "packet_modified", "unknown"} {
		t.Run(code, func(t *testing.T) {
			cmd := exec.Command(os.Args[0], "-test.run=^TestCommandErrorProcess$")
			cmd.Env = append(os.Environ(), "ATLAS_TEST_COMMAND_ERROR="+code)
			output, err := cmd.CombinedOutput()
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 1 {
				t.Fatalf("exit: %v, output: %s", err, output)
			}
			var reply map[string]any
			if err := json.Unmarshal(output, &reply); err != nil || reply["error"] == nil {
				t.Fatalf("invalid command error: %s (%v)", output, err)
			}
			if code == "unknown" {
				if _, ok := reply["code"]; ok {
					t.Fatalf("invented refusal code: %s", output)
				}
			} else if reply["code"] != code {
				t.Fatalf("lost typed refusal %s: %s", code, output)
			}
		})
	}
}
