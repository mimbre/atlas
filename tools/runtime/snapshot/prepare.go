package snapshot

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"
)

// NPMRegistry is the only package source an npm-ci preparation downloads from.
const NPMRegistry = "registry.npmjs.org"

// Preparation is the result of a folder's explicit preparation, which a worker's sandbox may read:
// only what status, diff, submit and the folder scope need. The command, environment, logs and
// error text stay in the private diagnostics beside it, which no worker profile grants.
//
// Version 1 is an npm-ci of Path. Version 2 is an npm-run of Script in Path, which writes only its
// declared Outputs, recorded with the succeeded version 1 npm-ci it follows as Previous.
type Preparation struct {
	Version     int          `json:"version"`
	Destination string       `json:"destination"`
	SnapshotID  string       `json:"snapshot_id"`
	Kind        string       `json:"kind"`
	Path        string       `json:"path"`
	Script      string       `json:"script,omitempty"`
	Outputs     []string     `json:"outputs"`
	State       string       `json:"state"`
	Reason      string       `json:"reason,omitempty"`
	ExitCode    *int         `json:"exit_code,omitempty"`
	StartedAt   string       `json:"started_at"`
	EndedAt     string       `json:"ended_at,omitempty"`
	Previous    *Preparation `json:"previous,omitempty"`
	// excluded are the outputs status, diff and submit skip, set by check: every npm-ci output and
	// each npm-run output that holds no tracked path.
	excluded []string
}

// Ready reports whether workers may start in the prepared folder.
func (p *Preparation) Ready() bool { return p.State == "succeeded" }

// Step returns the recorded step of kind: p itself, or the npm-ci an npm-run follows.
func (p *Preparation) Step(kind string) *Preparation {
	if p.Kind == kind {
		return p
	}
	if p.Previous != nil && p.Previous.Kind == kind {
		return p.Previous
	}
	return nil
}

// Describe names the step p, as refusals and results report it.
func (p *Preparation) Describe() string {
	if p.Script != "" {
		return fmt.Sprintf("%s preparation of %s (script %s)", p.Kind, p.Path, p.Script)
	}
	return fmt.Sprintf("%s preparation of %s", p.Kind, p.Path)
}

// Diagnostics holds the private request, process, logs and outcome of the step p.
func (p *Preparation) Diagnostics(home string) string {
	if p.Kind == "npm-run" {
		return filepath.Join(PreparationDiagnostics(home, p.Destination), "npm-run")
	}
	return PreparationDiagnostics(home, p.Destination)
}

// NotReady is the refusal of a worker, or of a repeated preparation, in a folder whose
// preparation did not succeed. Nothing is removed; a fresh materialization is the recovery.
func (p *Preparation) NotReady(home string) error {
	outcome := "failed (" + p.Reason + ")"
	if p.State == "running" {
		outcome = "has no recorded outcome: it is still running or was interrupted"
	}
	return fmt.Errorf("Materialized folder %s is not ready: its %s %s. The folder and the diagnostics in %s are kept; "+
		"materialize the snapshot into a fresh folder and prepare that one", p.Destination, p.Describe(), outcome, p.Diagnostics(home))
}

// preparationDir holds the preparation of dest: its result and its private diagnostics.
func preparationDir(home, dest string) string {
	return filepath.Join(home, "preparations", fmt.Sprintf("%x", sha256.Sum256([]byte(dest))))
}

// PreparationResult is where the preparation of dest records its worker-readable result.
func PreparationResult(home, dest string) string {
	return filepath.Join(preparationDir(home, dest), "result.json")
}

// PreparationDiagnostics holds the request, process, logs and outcome of the preparation of dest.
// Only the trusted CLI reads them.
func PreparationDiagnostics(home, dest string) string {
	return filepath.Join(preparationDir(home, dest), "private")
}

// npmOutputs are the paths an npm-ci preparation of path writes; they are derived, never declared freely.
func npmOutputs(path string) []string { return []string{path + "/node_modules"} }

// scriptName is a package.json script an npm-run preparation may name.
var scriptName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9:._-]{0,63}$`)

// validOutputs checks the declared outputs of an npm-run of path without the filesystem: sorted,
// distinct, not nested, never the installed node_modules, the package's manifests or a folder
// holding the package.
func validOutputs(path string, outputs []string) error {
	if len(outputs) == 0 {
		return errors.New("an npm-run preparation declares no --output; declare every path its script writes")
	}
	modules := npmOutputs(path)[0]
	for i, output := range outputs {
		switch {
		case !safe(output):
			return fmt.Errorf("--output %q is not a relative path inside the destination", output)
		case i > 0 && outputs[i-1] >= output:
			if outputs[i-1] == output {
				return fmt.Errorf("--output %s is declared twice", output)
			}
			return errors.New("the outputs of an npm-run preparation are not sorted")
		case within(modules, output) || within(output, modules):
			return fmt.Errorf("--output %s overlaps %s, which the npm-ci preparation installed and the script only reads", output, modules)
		case within(output, path):
			return fmt.Errorf("--output %s contains the package folder %s; declare only the paths the script writes", output, path)
		case output == path+"/package.json" || output == path+"/package-lock.json":
			return fmt.Errorf("--output %s is the package's own manifest", output)
		}
		for _, other := range outputs[:i] {
			if within(other, output) || within(output, other) {
				return fmt.Errorf("--output %s is inside --output %s; declare each path once", output, other)
			}
		}
	}
	return nil
}

// valid reports whether p is a well-formed recorded preparation of dest.
func (p *Preparation) valid(dest string) bool {
	if p.Destination != dest || !snapshotID.MatchString(p.SnapshotID) || !safe(p.Path) || !slices.Contains([]string{"running", "succeeded", "failed"}, p.State) {
		return false
	}
	switch p.Version {
	case 1:
		return p.Kind == "npm-ci" && p.Script == "" && p.Previous == nil && slices.Equal(p.Outputs, npmOutputs(p.Path))
	case 2:
		previous := p.Previous
		return p.Kind == "npm-run" && scriptName.MatchString(p.Script) && validOutputs(p.Path, p.Outputs) == nil && previous != nil &&
			previous.Version == 1 && previous.valid(dest) && previous.SnapshotID == p.SnapshotID && previous.Path == p.Path && previous.Ready()
	}
	return false
}

// tracks returns the first tracked path within output, or "".
func tracks(entries map[string]*entry, output string) string {
	first := ""
	for path := range entries {
		if within(output, path) && (first == "" || path < first) {
			first = path
		}
	}
	return first
}

// LoadPreparation returns the preparation result of the canonical folder dest, or nil for a folder
// that was never prepared. An unreadable or invalid result is an error, so exclusions and readiness
// are never silently dropped.
func LoadPreparation(home, dest string) (*Preparation, error) {
	path := PreparationResult(home, dest)
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	} else if err != nil {
		return nil, fmt.Errorf("cannot read the preparation result %s of %s: %v", path, dest, reason(err))
	}
	var p Preparation
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&p) != nil || !p.valid(dest) {
		return nil, fmt.Errorf("invalid preparation result %s for %s", path, dest)
	}
	return &p, nil
}

// check binds a loaded preparation to the folder's snapshot: its package and outputs lie in one
// repository and no npm-ci output holds a tracked path. It sets the excluded outputs: an npm-run
// output that holds a tracked path is not excluded, so its tracked files stay ordinary changes.
func (p *Preparation) check(id string, m *manifest, entries map[string]*entry) error {
	if p.SnapshotID != id {
		return fmt.Errorf("the preparation result of %s names snapshot %s, not %s", p.Destination, p.SnapshotID, id)
	}
	repository := owner(m.Repositories, p.Path)
	if repository == nil {
		return fmt.Errorf("the preparation result of %s names %s, which is in no repository", p.Destination, p.Path)
	}
	p.excluded = []string{}
	for _, step := range []*Preparation{p.Previous, p} {
		if step == nil {
			continue
		}
		for _, output := range step.Outputs {
			if owner(m.Repositories, output) != repository {
				return fmt.Errorf("the preparation result of %s names output %s outside the repository of %s", p.Destination, output, p.Path)
			}
			tracked := tracks(entries, output)
			if tracked != "" && step.Kind == "npm-ci" {
				return fmt.Errorf("the preparation result of %s would exclude tracked %s", p.Destination, tracked)
			}
			if tracked == "" {
				p.excluded = append(p.excluded, output)
			}
		}
	}
	return nil
}

// excluded reports whether rel is an excluded preparation output. Only a real directory there is
// skipped: a symlink or file in its place is an ordinary change, and nothing is followed.
func (f *folder) excluded(rel string, d fs.DirEntry) bool {
	return f.preparation != nil && d.IsDir() && slices.Contains(f.preparation.excluded, rel)
}

// packageFolder checks that every folder from the destination to the package path is a real
// directory, so npm and the sandbox see the paths checked here, and that no project .npmrc applies:
// a preparation uses only empty npm configuration.
func (f *folder) packageFolder(path string) error {
	segments := strings.Split(path, "/")
	for i := range segments {
		rel := strings.Join(segments[:i+1], "/")
		if info, err := os.Lstat(filepath.Join(f.dest, rel)); err != nil || !info.IsDir() || f.entries[rel] != nil {
			return fmt.Errorf("%s is not a directory in %s", rel, f.dest)
		}
	}
	for i := len(segments); i >= 0; i-- {
		rel := strings.Join(append(slices.Clone(segments[:i]), ".npmrc"), "/")
		_, err := os.Lstat(filepath.Join(f.dest, rel))
		if f.entries[rel] != nil || err == nil {
			return fmt.Errorf("project %s is not supported: a preparation installs only from the public npm registry with empty npm configuration", rel)
		}
	}
	return nil
}

// unchanged refuses a folder with any change since it was materialized, outside excluded outputs.
func (f *folder) unchanged(what string) error {
	changes, err := f.changes(nil, false)
	if err != nil {
		return err
	}
	if len(changes) > 0 {
		return fmt.Errorf("%s has %d change(s) since it was materialized, first %s %s; %s, "+
			"so materialize the snapshot into a new folder. Nothing was discarded", f.dest, len(changes), changes[0].Change, changes[0].Path, what)
	}
	return nil
}

// PlanNPMCI checks that the canonical folder dest, never prepared and unchanged since it was
// materialized, can install its tracked lockfile in path from the public npm registry alone, and
// returns the running result to record before anything runs.
func PlanNPMCI(home, dest, path string) (*Preparation, error) {
	f, err := openFolder(home, dest)
	if err != nil {
		return nil, err
	}
	if f.preparation != nil {
		return nil, fmt.Errorf("%s already has a %s preparation of %s", f.dest, f.preparation.Kind, f.preparation.Path)
	}
	if !safe(path) || owner(f.m.Repositories, path) == nil {
		return nil, fmt.Errorf("--npm-ci %q is not a folder inside a materialized repository; use REPO_PATH or REPO_PATH/SUBDIR", path)
	}
	if err = f.packageFolder(path); err != nil {
		return nil, err
	}
	for _, name := range []string{"package.json", "package-lock.json"} {
		if e := f.entries[path+"/"+name]; e == nil || e.Kind != "file" {
			return nil, fmt.Errorf("%s/%s is not a tracked file; an npm-ci preparation installs a tracked package-lock.json", path, name)
		}
	}
	for _, output := range npmOutputs(path) {
		if tracked := tracks(f.entries, output); tracked != "" {
			return nil, fmt.Errorf("%s is tracked in the snapshot; a preparation never excludes tracked files", tracked)
		}
	}
	if err = f.unchanged("a preparation installs exactly the snapshot's lockfile into a freshly materialized folder. A changed package-lock.json must first be part of a snapshot"); err != nil {
		return nil, err
	}
	data, err := os.ReadFile(filepath.Join(f.dest, path, "package-lock.json"))
	if err != nil {
		return nil, err
	}
	if err = registryOnly(data); err != nil {
		return nil, fmt.Errorf("%s/package-lock.json %v", path, err)
	}
	return &Preparation{Version: 1, Destination: f.dest, SnapshotID: f.id, Kind: "npm-ci", Path: path, Outputs: npmOutputs(path),
		State: "running", StartedAt: time.Now().UTC().Format(time.RFC3339)}, nil
}

// PlanNPMRun checks that the canonical folder dest, whose npm-ci of path succeeded and which is
// otherwise unchanged since it was materialized, can run the tracked script of path's package.json
// writing only outputs, and returns the running result to record before anything runs. Each
// output is a path in the package's repository; it and every folder above it that exists is real.
func PlanNPMRun(home, dest, path, script string, outputs []string) (*Preparation, error) {
	f, err := openFolder(home, dest)
	if err != nil {
		return nil, err
	}
	installed := f.preparation
	if installed != nil && installed.Kind == "npm-run" {
		return nil, fmt.Errorf("%s already has an %s", f.dest, installed.Describe())
	}
	if installed == nil || installed.Path != path || !installed.Ready() {
		return nil, fmt.Errorf("--npm-run %s requires a succeeded --npm-ci preparation of %s in %s first; the script runs offline with the installed node_modules", path, path, f.dest)
	}
	if !scriptName.MatchString(script) {
		return nil, fmt.Errorf("--script %q is not a package.json script name", script)
	}
	if err = f.packageFolder(path); err != nil {
		return nil, err
	}
	data, err := os.ReadFile(filepath.Join(f.dest, path, "package.json"))
	if err != nil {
		return nil, err
	}
	var manifest struct {
		Scripts map[string]any `json:"scripts"`
	}
	if err = json.Unmarshal(data, &manifest); err != nil {
		return nil, fmt.Errorf("%s/package.json is not valid JSON: %v", path, err)
	}
	if command, ok := manifest.Scripts[script].(string); !ok || strings.TrimSpace(command) == "" {
		return nil, fmt.Errorf("script %q is not in the tracked %s/package.json; an npm-run preparation runs only a declared script", script, path)
	}
	outputs = slices.Sorted(slices.Values(outputs))
	if err = validOutputs(path, outputs); err != nil {
		return nil, err
	}
	repository := owner(f.m.Repositories, path)
	for _, output := range outputs {
		if owner(f.m.Repositories, output) != repository {
			return nil, fmt.Errorf("--output %s is outside the repository of %s", output, path)
		}
		// The sandbox grants the output by path, so it and the folders above it must be what they seem.
		segments := strings.Split(output, "/")
		for i := range segments {
			rel := strings.Join(segments[:i+1], "/")
			info, err := os.Lstat(filepath.Join(f.dest, rel))
			if errors.Is(err, fs.ErrNotExist) {
				break
			} else if err != nil {
				return nil, err
			}
			last := i == len(segments)-1
			if e := f.entries[rel]; info.Mode()&fs.ModeSymlink != 0 || !last && !info.IsDir() || !info.IsDir() && !info.Mode().IsRegular() || e != nil && e.Kind != "file" {
				return nil, fmt.Errorf("--output %s: %s is not a real directory or, for the output itself, a tracked or new regular file", output, rel)
			}
		}
	}
	if err = f.unchanged("an npm-run preparation regenerates exactly the snapshot's files in a freshly prepared folder"); err != nil {
		return nil, err
	}
	previous := *installed
	previous.excluded = nil
	return &Preparation{Version: 2, Destination: f.dest, SnapshotID: f.id, Kind: "npm-run", Path: path, Script: script, Outputs: outputs,
		State: "running", StartedAt: time.Now().UTC().Format(time.RFC3339), Previous: &previous}, nil
}

// registryOnly refuses a lockfile that installs anything but integrity-pinned tarballs from the
// public npm registry: other hosts, Git or local sources, links, workspaces and bundled packages.
func registryOnly(data []byte) error {
	var lock struct {
		LockfileVersion int `json:"lockfileVersion"`
		Packages        map[string]struct {
			Resolved  string `json:"resolved"`
			Integrity string `json:"integrity"`
			Link      bool   `json:"link"`
			InBundle  bool   `json:"inBundle"`
		} `json:"packages"`
	}
	if err := json.Unmarshal(data, &lock); err != nil {
		return fmt.Errorf("is not valid JSON: %v", err)
	}
	if lock.LockfileVersion != 2 && lock.LockfileVersion != 3 || lock.Packages == nil {
		return errors.New("needs lockfileVersion 2 or 3 with a packages map")
	}
	names := make([]string, 0, len(lock.Packages))
	for name := range lock.Packages {
		names = append(names, name)
	}
	slices.Sort(names)
	for _, name := range names {
		pkg := lock.Packages[name]
		if name == "" {
			continue
		}
		if !strings.HasPrefix(name, "node_modules/") {
			return fmt.Errorf("installs %q outside node_modules; workspaces and local packages are not supported", name)
		}
		if pkg.Link || pkg.InBundle {
			return fmt.Errorf("installs %q as a link or bundled package, not from the registry", name)
		}
		u, err := url.Parse(pkg.Resolved)
		if err != nil || u.Scheme != "https" || u.Host != NPMRegistry || u.User != nil || u.Opaque != "" || u.RawQuery != "" || u.Fragment != "" {
			return fmt.Errorf("resolves %q to %q, not to https://%s/", name, pkg.Resolved, NPMRegistry)
		}
		integrity := strings.Fields(pkg.Integrity)
		if len(integrity) == 0 || slices.ContainsFunc(integrity, func(hash string) bool { return !strings.HasPrefix(hash, "sha512-") }) {
			return fmt.Errorf("pins %q without a sha512 integrity", name)
		}
	}
	return nil
}

// BeginPreparation records p as running, with request in its private diagnostics, before anything
// runs. The claim is one exclusive rename, so it never replaces an earlier preparation of the folder.
func BeginPreparation(home string, p *Preparation, request any) error {
	parent := filepath.Join(home, "preparations")
	if err := os.MkdirAll(parent, 0700); err != nil {
		return err
	}
	staging, err := os.MkdirTemp(parent, ".claim-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(staging)
	if err = os.Mkdir(filepath.Join(staging, "private"), 0700); err != nil {
		return err
	}
	body, err := json.Marshal(request)
	if err != nil {
		return err
	}
	if err = replace(filepath.Join(staging, "private", "request.json"), append(body, '\n'), 0600); err != nil {
		return err
	}
	if body, err = json.Marshal(p); err != nil {
		return err
	}
	if err = replace(filepath.Join(staging, "result.json"), append(body, '\n'), 0600); err != nil {
		return err
	}
	if err = renameExclusive(staging, preparationDir(home, p.Destination)); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return fmt.Errorf("%s already has a preparation record", p.Destination)
		}
		return err
	}
	return nil
}

// BeginRun records the npm-run p as running, with request in its own private diagnostics, before
// anything runs. Its diagnostics folder is created exclusively, so a folder runs at most one script.
func BeginRun(home string, p *Preparation, request any) error {
	directory := p.Diagnostics(home)
	if err := os.Mkdir(directory, 0700); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return fmt.Errorf("%s already has an npm-run preparation record", p.Destination)
		}
		return err
	}
	body, err := json.Marshal(request)
	if err != nil {
		return err
	}
	if err = replace(filepath.Join(directory, "request.json"), append(body, '\n'), 0600); err != nil {
		return err
	}
	return FinishPreparation(home, p)
}

// FinishPreparation replaces the recorded result of p with p.
func FinishPreparation(home string, p *Preparation) error {
	body, err := json.Marshal(p)
	if err != nil {
		return err
	}
	return replace(PreparationResult(home, p.Destination), append(body, '\n'), 0600)
}
