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
	"slices"
	"strings"
	"time"
)

// NPMRegistry is the only package source an npm-ci preparation downloads from.
const NPMRegistry = "registry.npmjs.org"

// Preparation is the result of a folder's one explicit preparation, which a worker's sandbox may
// read: only what status, diff, submit and the folder scope need. The command, environment, logs
// and error text stay in the private diagnostics beside it, which no worker profile grants.
type Preparation struct {
	Version     int      `json:"version"`
	Destination string   `json:"destination"`
	SnapshotID  string   `json:"snapshot_id"`
	Kind        string   `json:"kind"`
	Path        string   `json:"path"`
	Outputs     []string `json:"outputs"`
	State       string   `json:"state"`
	Reason      string   `json:"reason,omitempty"`
	ExitCode    *int     `json:"exit_code,omitempty"`
	StartedAt   string   `json:"started_at"`
	EndedAt     string   `json:"ended_at,omitempty"`
}

// Ready reports whether workers may start in the prepared folder.
func (p *Preparation) Ready() bool { return p.State == "succeeded" }

// NotReady is the refusal of a worker, or of a repeated preparation, in a folder whose
// preparation did not succeed. Nothing is removed; a fresh materialization is the recovery.
func (p *Preparation) NotReady(home string) error {
	outcome := "failed (" + p.Reason + ")"
	if p.State == "running" {
		outcome = "has no recorded outcome: it is still running or was interrupted"
	}
	return fmt.Errorf("Materialized folder %s is not ready: its %s preparation of %s %s. The folder and the diagnostics in %s are kept; "+
		"materialize the snapshot into a fresh folder and prepare that one", p.Destination, p.Kind, p.Path, outcome, PreparationDiagnostics(home, p.Destination))
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
	if decoder.Decode(&p) != nil || p.Version != 1 || p.Destination != dest || !snapshotID.MatchString(p.SnapshotID) || p.Kind != "npm-ci" ||
		!safe(p.Path) || !slices.Equal(p.Outputs, npmOutputs(p.Path)) || !slices.Contains([]string{"running", "succeeded", "failed"}, p.State) {
		return nil, fmt.Errorf("invalid preparation result %s for %s", path, dest)
	}
	return &p, nil
}

// check binds a loaded preparation to the folder's snapshot: its package lies in a repository and
// none of its outputs holds a tracked path, so excluding them never hides a tracked change.
func (p *Preparation) check(id string, m *manifest, entries map[string]*entry) error {
	if p.SnapshotID != id {
		return fmt.Errorf("the preparation result of %s names snapshot %s, not %s", p.Destination, p.SnapshotID, id)
	}
	if owner(m.Repositories, p.Path) == nil {
		return fmt.Errorf("the preparation result of %s names %s, which is in no repository", p.Destination, p.Path)
	}
	for _, output := range p.Outputs {
		for path := range entries {
			if within(output, path) {
				return fmt.Errorf("the preparation result of %s would exclude tracked %s", p.Destination, path)
			}
		}
	}
	return nil
}

// excluded reports whether rel is a declared preparation output. Only a real directory there is
// skipped: a symlink or file in its place is an ordinary change, and nothing is followed.
func (f *folder) excluded(rel string, d fs.DirEntry) bool {
	return f.preparation != nil && d.IsDir() && slices.Contains(f.preparation.Outputs, rel)
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
	// Every folder from the destination to the package is a real directory, so npm and the
	// sandbox see the paths checked here.
	segments := strings.Split(path, "/")
	for i := range segments {
		rel := strings.Join(segments[:i+1], "/")
		if info, err := os.Lstat(filepath.Join(f.dest, rel)); err != nil || !info.IsDir() || f.entries[rel] != nil {
			return nil, fmt.Errorf("%s is not a directory in %s", rel, f.dest)
		}
	}
	for _, name := range []string{"package.json", "package-lock.json"} {
		if e := f.entries[path+"/"+name]; e == nil || e.Kind != "file" {
			return nil, fmt.Errorf("%s/%s is not a tracked file; an npm-ci preparation installs a tracked package-lock.json", path, name)
		}
	}
	// npm reads the .npmrc of its project; this preparation uses only empty npm configuration.
	for i := len(segments); i >= 0; i-- {
		rel := strings.Join(append(slices.Clone(segments[:i]), ".npmrc"), "/")
		_, err := os.Lstat(filepath.Join(f.dest, rel))
		if f.entries[rel] != nil || err == nil {
			return nil, fmt.Errorf("project %s is not supported: an npm-ci preparation installs only from the public npm registry with empty npm configuration", rel)
		}
	}
	for _, output := range npmOutputs(path) {
		for tracked := range f.entries {
			if within(output, tracked) {
				return nil, fmt.Errorf("%s is tracked in the snapshot; a preparation never excludes tracked files", tracked)
			}
		}
	}
	changes, err := f.changes(nil, false)
	if err != nil {
		return nil, err
	}
	if len(changes) > 0 {
		return nil, fmt.Errorf("%s has %d change(s) since it was materialized, first %s %s; a preparation installs exactly the snapshot's lockfile into a freshly materialized folder, "+
			"so materialize the snapshot into a new folder. Nothing was discarded. A changed package-lock.json must first be part of a snapshot", f.dest, len(changes), changes[0].Change, changes[0].Path)
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

// FinishPreparation replaces the running result of p with its outcome.
func FinishPreparation(home string, p *Preparation) error {
	body, err := json.Marshal(p)
	if err != nil {
		return err
	}
	return replace(PreparationResult(home, p.Destination), append(body, '\n'), 0600)
}
