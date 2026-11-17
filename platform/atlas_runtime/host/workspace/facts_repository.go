package workspace

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
)

// Facts kind `repository HOME BRANCH` (S6 A4, B4): the raw facts the managed-repository request
// decision (AtlasRuntime.Sandbox.Repository.request) needs, as workspaceRequest gathers them:
//   - home: HOME made absolute (pathlib-style, against the canonical working directory);
//   - branch: stdout and exit code of `git check-ref-format --branch BRANCH`;
//   - resolved: for each name in stdin {"paths": [...]}, a path relative to the absolute home,
//     its resolution ({"resolved": path}) or the error text ({"error": text}).
// The core chooses the paths (repositories/<owner>/<name>); this kind decides nothing.

func init() {
	Register("repository", repositoryFacts)
}

func repositoryFacts(args []string, stdin io.Reader) (any, error) {
	if len(args) != 2 {
		return nil, errors.New("workspace facts repository requires home and branch")
	}
	var input struct {
		Paths []string `json:"paths"`
	}
	data, err := io.ReadAll(stdin)
	if err != nil {
		return nil, err
	}
	if len(bytes.TrimSpace(data)) > 0 {
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&input); err != nil {
			return nil, errors.New("workspace facts repository: stdin must be {\"paths\": [...]}")
		}
	}
	home, branch := args[0], args[1]
	stdout, _, code, err := workspaceRun([]string{"git", "check-ref-format", "--branch", branch}, nil)
	if err != nil {
		return nil, err
	}
	absolute, err := workspaceAbsolute(home)
	if err != nil {
		return nil, err
	}
	resolved := map[string]any{}
	for _, path := range input.Paths {
		if value, err := workspaceResolve(workspacePath(absolute + "/" + path)); err != nil {
			resolved[path] = map[string]any{"error": err.Error()}
		} else {
			resolved[path] = map[string]any{"resolved": value}
		}
	}
	return map[string]any{
		"home":     absolute,
		"branch":   map[string]any{"stdout": stdout, "code": code},
		"resolved": resolved,
	}, nil
}
