package workspace

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// The repository preparation plan (S6 A4, plan s6-plan.md §12 item 4). The core decides it
// (AtlasRuntime.Sandbox.Repository.plan): what to clone or fetch, which base, which
// preconditions refuse and with which text. RunPlan only executes it: it runs git inside the
// given sandbox prefix, writes and reads the marker, and picks when_created or when_existing
// from the lock's created fact alone. Shadow: nothing calls RunPlan in production yet (C4).

// RepositoryPlan is the plan document, decoded strictly by DecodeRepositoryPlan.
type RepositoryPlan struct {
	Version      int        `json:"version"`
	URL          string     `json:"url"`
	Branch       string     `json:"branch"`
	GitConfig    []string   `json:"git_config"`
	GitEnv       []string   `json:"git_env"`
	WhenCreated  []PlanStep `json:"when_created"`
	WhenExisting []PlanStep `json:"when_existing"`
	Continuation bool       `json:"continuation"`
}

// PlanStep is one step. Args is the exact git argument list (after `git` and the git_config
// options); Error is the exact refusal text of an expect_* or resolve_base step.
type PlanStep struct {
	Step       string         `json:"step"`
	Args       []string       `json:"args,omitempty"`
	Path       string         `json:"path,omitempty"`
	Identity   map[string]any `json:"identity,omitempty"`
	URL        string         `json:"url,omitempty"`
	Branch     string         `json:"branch,omitempty"`
	Pattern    string         `json:"pattern,omitempty"`
	Error      string         `json:"error,omitempty"`
	ExtraError string         `json:"extra_error,omitempty"`
}

// PlanResult is what a successful run reports: the base it resolved, if a step resolved one.
type PlanResult struct {
	BaseSHA  string
	Resolved bool
}

// The fields each step kind requires; any other field is refused.
var planStepFields = map[string][]string{
	"clone":                 {"args"},
	"expect_scope":          {},
	"write_marker":          {"path", "identity"},
	"expect_marker":         {"path", "identity", "error", "extra_error"},
	"expect_origin":         {"args", "url", "error"},
	"expect_current_branch": {"args", "branch", "error"},
	"expect_clean":          {"args", "error"},
	"expect_no_ref":         {"args", "error"},
	"fetch":                 {"args"},
	"resolve_base":          {"args", "pattern", "error"},
	"checkout_new":          {"args"},
}

func invalidPlan(format string, args ...any) error {
	return fmt.Errorf("Invalid repository plan: "+format, args...)
}

// DecodeRepositoryPlan reads one plan document: version 1, no unknown or missing fields, known
// steps with exactly their fields, a marker path inside the repository, and a compilable pattern.
func DecodeRepositoryPlan(data []byte) (*RepositoryPlan, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	decoder.UseNumber()
	var plan RepositoryPlan
	if err := decoder.Decode(&plan); err != nil {
		return nil, invalidPlan("%v", err)
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, invalidPlan("trailing data")
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, invalidPlan("%v", err)
	}
	for _, field := range []string{"version", "url", "branch", "git_config", "git_env", "when_created", "when_existing", "continuation"} {
		if _, present := raw[field]; !present {
			return nil, invalidPlan("missing field %s", field)
		}
	}
	if plan.Version != 1 {
		return nil, invalidPlan("version must be 1")
	}
	for _, entry := range plan.GitEnv {
		if name, _, found := strings.Cut(entry, "="); !found || name == "" {
			return nil, invalidPlan("git_env entry is not NAME=VALUE: %q", entry)
		}
	}
	var steps struct {
		WhenCreated  []map[string]json.RawMessage `json:"when_created"`
		WhenExisting []map[string]json.RawMessage `json:"when_existing"`
	}
	if err := json.Unmarshal(data, &steps); err != nil {
		return nil, invalidPlan("%v", err)
	}
	for _, part := range []struct {
		list    string
		raws    []map[string]json.RawMessage
		decoded []PlanStep
	}{{"when_created", steps.WhenCreated, plan.WhenCreated}, {"when_existing", steps.WhenExisting, plan.WhenExisting}} {
		list, raws, decoded := part.list, part.raws, part.decoded
		resolved := false
		for index, step := range decoded {
			fields, known := planStepFields[step.Step]
			if !known {
				return nil, invalidPlan("%s[%d]: unknown step %q", list, index, step.Step)
			}
			for field := range raws[index] {
				if field != "step" && !planContains(fields, field) {
					return nil, invalidPlan("%s[%d]: field %s is not allowed for %s", list, index, field, step.Step)
				}
			}
			for _, field := range fields {
				if _, present := raws[index][field]; !present {
					return nil, invalidPlan("%s[%d]: %s requires %s", list, index, step.Step, field)
				}
			}
			if planContains(fields, "args") && len(step.Args) == 0 {
				return nil, invalidPlan("%s[%d]: %s requires args", list, index, step.Step)
			}
			if planContains(fields, "path") && !markerPath(step.Path) {
				return nil, invalidPlan("%s[%d]: path must be relative inside the repository", list, index)
			}
			switch step.Step {
			case "resolve_base":
				if _, err := regexp.Compile(step.Pattern); err != nil {
					return nil, invalidPlan("%s[%d]: %v", list, index, err)
				}
				resolved = true
			case "checkout_new":
				if !resolved {
					return nil, invalidPlan("%s[%d]: checkout_new before resolve_base", list, index)
				}
			}
		}
	}
	return &plan, nil
}

func markerPath(path string) bool {
	if path == "" || filepath.IsAbs(path) {
		return false
	}
	for _, part := range strings.Split(path, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

func planContains(list []string, item string) bool {
	for _, value := range list {
		if value == item {
			return true
		}
	}
	return false
}

// RunPlan executes plan for the repository at root: when_created when the lock created root,
// else when_existing. Every git call is prefix + git + (-c CONFIG)... + args, with git_env
// replacing the caller's value of each name, and runs in the working directory the prefix
// gives it (as workspace.Prepare does). A failing checked git call is refused with its stderr.
func RunPlan(plan *RepositoryPlan, root string, created bool, prefix []string) (PlanResult, error) {
	env := os.Environ()
	for _, entry := range plan.GitEnv {
		name, _, _ := strings.Cut(entry, "=")
		for index, inherited := range env {
			if strings.HasPrefix(inherited, name+"=") {
				env = append(env[:index], env[index+1:]...)
				break
			}
		}
		env = append(env, entry)
	}
	git := func(check bool, args []string) (string, int, error) {
		argv := make([]string, 0, len(prefix)+1+2*len(plan.GitConfig)+len(args))
		argv = append(argv, prefix...)
		argv = append(argv, "git")
		for _, config := range plan.GitConfig {
			argv = append(argv, "-c", config)
		}
		argv = append(argv, args...)
		stdout, stderr, code, err := workspaceRun(argv, env)
		if err == nil && check && code != 0 {
			err = fmt.Errorf("Git preparation failed: %s", strings.TrimSpace(stderr))
		}
		return stdout, code, err
	}
	steps := plan.WhenExisting
	if created {
		steps = plan.WhenCreated
	}
	result := PlanResult{}
	for _, step := range steps {
		switch step.Step {
		case "clone", "fetch":
			if _, _, err := git(true, step.Args); err != nil {
				return PlanResult{}, err
			}
		case "expect_scope":
			if _, err := Scope(root); err != nil {
				return PlanResult{}, err
			}
		case "write_marker":
			data, err := json.Marshal(step.Identity)
			if err != nil {
				return PlanResult{}, err
			}
			if err = os.WriteFile(filepath.Join(root, step.Path), append(data, '\n'), 0666); err != nil {
				return PlanResult{}, err
			}
		case "expect_marker":
			if err := expectMarker(filepath.Join(root, step.Path), step); err != nil {
				return PlanResult{}, err
			}
		case "expect_origin", "expect_current_branch":
			stdout, _, err := git(true, step.Args)
			if err != nil {
				return PlanResult{}, err
			}
			want := step.URL
			if step.Step == "expect_current_branch" {
				want = step.Branch
			}
			if strings.TrimSpace(stdout) != want {
				return PlanResult{}, errors.New(step.Error)
			}
		case "expect_clean":
			stdout, _, err := git(true, step.Args)
			if err != nil {
				return PlanResult{}, err
			}
			if stdout != "" {
				return PlanResult{}, errors.New(step.Error)
			}
		case "expect_no_ref":
			_, code, err := git(false, step.Args)
			if err != nil {
				return PlanResult{}, err
			}
			if code != 1 {
				return PlanResult{}, errors.New(step.Error)
			}
		case "resolve_base":
			stdout, _, err := git(false, step.Args)
			if err != nil {
				return PlanResult{}, err
			}
			pattern, err := regexp.Compile(step.Pattern)
			if err != nil {
				return PlanResult{}, invalidPlan("%v", err)
			}
			base := strings.TrimSpace(stdout)
			if !pattern.MatchString(base) {
				return PlanResult{}, errors.New(step.Error)
			}
			result = PlanResult{BaseSHA: base, Resolved: true}
		case "checkout_new":
			if !result.Resolved {
				return PlanResult{}, invalidPlan("checkout_new before resolve_base")
			}
			if _, _, err := git(true, append(append([]string{}, step.Args...), result.BaseSHA)); err != nil {
				return PlanResult{}, err
			}
		default:
			return PlanResult{}, invalidPlan("unknown step %q", step.Step)
		}
	}
	return result, nil
}

// expectMarker reads the marker as one JSON value and compares it with the step's identity.
func expectMarker(marker string, step PlanStep) error {
	info, err := os.Stat(marker)
	if err != nil || !info.Mode().IsRegular() {
		return errors.New(step.Error)
	}
	data, err := os.ReadFile(marker)
	if err != nil {
		return err
	}
	var saved any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err = decoder.Decode(&saved); err != nil {
		return err
	}
	var extra any
	if err = decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			err = errors.New(step.ExtraError)
		}
		return err
	}
	identity := map[string]any{}
	for key, value := range step.Identity {
		identity[key] = value
	}
	if !JSONEqual(identity, saved) {
		return errors.New(step.Error)
	}
	return nil
}
