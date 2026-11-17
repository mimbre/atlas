package workspace

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"

	"github.com/eyra/atlas/platform/atlas_runtime/host/snapshot"
)

// Facts kind `prepare DEST HOME PATH` (S6 package A6, plan B4 and R2): the raw facts the Elixir
// preparation decision (AtlasRuntime.Sandbox.Preparation) needs to plan one npm-ci or npm-run of
// the package folder PATH in the materialized folder DEST, and to judge its recorded preparation.
// It verifies, reads, decodes and lstats; it applies no preparation rule (no registry check, no
// output rule, no readiness) and refuses only malformed arguments or input. A failure to inspect
// one item is that item's `error`, because whether it matters is the decision's call.
//
// It calls only the exported snapshot.Verified, Inspect, PreparationResult and LoadPreparation,
// so package snapshot is not edited and nothing imports package host (no cycle).
//
// Input (stdin JSON, optional; empty stdin is {}):
//
//	{"outputs": ["<npm-run output, as declared>", ...],   // each gets an lstat chain
//	 "tools":   ["<command looked up on PATH>", ...]}     // the decision names them
//
// Output: dest, home, path as given, and
//
//	folder      snapshot.Verified: {root, snapshot_id, repositories, baseline} or {error}
//	preparation the recorded result of the root: {result, absent} | {result, raw} | {result, error}
//	tracked     the baseline's entries {path, kind} on, below or above PATH, its .npmrc candidates
//	            and the outputs, sorted by path (decoded from the verified manifest)
//	chain       lstat of every prefix of PATH: {rel, type[, error]}
//	npmrc       every .npmrc from PATH up to the root, deepest first: {rel, present}
//	changes     snapshot.Inspect(home, root, nil, false): {count, first} or {error}
//	lockfile    PATH/package-lock.json decoded with the fields npm-ci reads, or {read_error|decode_error}
//	package     PATH/package.json's scripts, or {read_error|decode_error}
//	outputs     per input output, the lstat chain of its prefixes
//	tools       per input tool: {name, found, resolved} or with error / resolve_error
//
// Only folder and preparation are reported when the folder does not verify.
func init() {
	Register("prepare", prepareFacts)
}

type prepareInput struct {
	Outputs []string `json:"outputs"`
	Tools   []string `json:"tools"`
}

func prepareFacts(args []string, stdin io.Reader) (any, error) {
	if len(args) != 3 {
		return nil, errors.New("use workspace facts prepare DEST HOME PATH")
	}
	dest, home, path := args[0], args[1], args[2]
	var input prepareInput
	decoder := json.NewDecoder(stdin)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil && !errors.Is(err, io.EOF) {
		return nil, errors.New("workspace facts prepare input: " + err.Error())
	}
	facts := map[string]any{"dest": dest, "home": home, "path": path}

	verified, err := snapshot.Verified(home, dest)
	if err != nil {
		facts["folder"] = map[string]any{"error": err.Error()}
		return facts, nil
	}
	root, _ := verified["root"].(string)
	baseline, _ := verified["baseline"].(string)
	facts["folder"] = map[string]any{"root": root, "snapshot_id": verified["snapshot_id"],
		"repositories": verified["repositories"], "baseline": baseline}
	facts["preparation"] = preparationFact(home, root)
	facts["tracked"] = trackedFact(baseline, path, input.Outputs)
	facts["chain"] = lstatChain(root, path)
	facts["npmrc"] = npmrcFact(root, path)
	facts["changes"] = changesFact(home, root)
	facts["lockfile"] = lockfileFact(filepath.Join(root, path, "package-lock.json"))
	facts["package"] = packageFact(filepath.Join(root, path, "package.json"))
	outputs := []any{}
	for _, output := range input.Outputs {
		outputs = append(outputs, map[string]any{"output": output, "chain": lstatChain(root, output)})
	}
	facts["outputs"] = outputs
	tools := []any{}
	for _, name := range input.Tools {
		tools = append(tools, toolFact(name))
	}
	facts["tools"] = tools
	return facts, nil
}

// preparationFact is the recorded preparation result of root as written: decoded as one generic
// JSON value (the first, as snapshot.LoadPreparation's decoder reads it), never judged here.
func preparationFact(home, root string) map[string]any {
	result := snapshot.PreparationResult(home, root)
	fact := map[string]any{"result": result}
	data, err := os.ReadFile(result)
	if errors.Is(err, fs.ErrNotExist) {
		fact["absent"] = true
		return fact
	} else if err != nil {
		// LoadPreparation's own text for an unreadable result.
		if _, loadErr := snapshot.LoadPreparation(home, root); loadErr != nil {
			fact["error"] = loadErr.Error()
		} else {
			fact["error"] = err.Error()
		}
		return fact
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var raw any
	if decoder.Decode(&raw) != nil {
		raw = nil
		fact["undecodable"] = true
	}
	fact["raw"] = raw
	return fact
}

// trackedFact lists the verified baseline's entries the plan looks at: on, below or above path,
// on or above an output, or below one, and every .npmrc candidate.
func trackedFact(baseline, path string, outputs []string) any {
	data, err := os.ReadFile(filepath.Join(baseline, "manifest.json"))
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	var manifest struct {
		Entries []struct {
			Path string `json:"path"`
			Kind string `json:"kind"`
		} `json:"entries"`
	}
	if err = json.Unmarshal(data, &manifest); err != nil {
		return map[string]any{"error": err.Error()}
	}
	candidates := map[string]bool{}
	for _, rel := range npmrcCandidates(path) {
		candidates[rel] = true
	}
	near := func(a, b string) bool { return lexicallyWithin(a, b) || lexicallyWithin(b, a) }
	entries := []map[string]any{}
	for _, e := range manifest.Entries {
		relevant := near(path, e.Path) || candidates[e.Path]
		for _, output := range outputs {
			relevant = relevant || near(output, e.Path)
		}
		if relevant {
			entries = append(entries, map[string]any{"path": e.Path, "kind": e.Kind})
		}
	}
	slices.SortFunc(entries, func(a, b map[string]any) int { return strings.Compare(a["path"].(string), b["path"].(string)) })
	return entries
}

func lexicallyWithin(dir, path string) bool { return path == dir || strings.HasPrefix(path, dir+"/") }

// lstatChain lstats every prefix of rel below root, without following a symlink at any of them.
func lstatChain(root, rel string) []map[string]any {
	chain := []map[string]any{}
	segments := strings.Split(rel, "/")
	for i := range segments {
		prefix := strings.Join(segments[:i+1], "/")
		item := map[string]any{"rel": prefix}
		info, err := os.Lstat(filepath.Join(root, prefix))
		switch {
		case errors.Is(err, fs.ErrNotExist):
			item["type"] = "absent"
		case err != nil:
			item["type"], item["error"] = "error", err.Error()
		case info.Mode()&fs.ModeSymlink != 0:
			item["type"] = "symlink"
		case info.IsDir():
			item["type"] = "dir"
		case info.Mode().IsRegular():
			item["type"] = "file"
		default:
			item["type"] = "other"
		}
		chain = append(chain, item)
	}
	return chain
}

// npmrcCandidates are the .npmrc files from the package folder path up to the root, deepest first.
func npmrcCandidates(path string) []string {
	segments := strings.Split(path, "/")
	candidates := []string{}
	for i := len(segments); i >= 0; i-- {
		candidates = append(candidates, strings.Join(append(slices.Clone(segments[:i]), ".npmrc"), "/"))
	}
	return candidates
}

func npmrcFact(root, path string) []map[string]any {
	facts := []map[string]any{}
	for _, rel := range npmrcCandidates(path) {
		_, err := os.Lstat(filepath.Join(root, rel))
		facts = append(facts, map[string]any{"rel": rel, "present": err == nil})
	}
	return facts
}

// changesFact is the folder's change count since it was materialized, outside excluded outputs.
func changesFact(home, root string) map[string]any {
	inspection, err := snapshot.Inspect(home, root, nil, false)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	body, err := json.Marshal(inspection["changes"])
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	var changes []map[string]any
	if err = json.Unmarshal(body, &changes); err != nil {
		return map[string]any{"error": err.Error()}
	}
	fact := map[string]any{"count": len(changes), "first": nil}
	if len(changes) > 0 {
		fact["first"] = map[string]any{"change": changes[0]["change"], "path": changes[0]["path"]}
	}
	return fact
}

// lockfileFact decodes a package-lock.json into exactly the fields an npm-ci preparation reads,
// with Go's decoding error text, and splits each resolved URL into the parts the registry rule reads.
func lockfileFact(name string) map[string]any {
	data, err := os.ReadFile(name)
	if err != nil {
		return map[string]any{"read_error": err.Error()}
	}
	var lock struct {
		LockfileVersion int `json:"lockfileVersion"`
		Packages        map[string]struct {
			Resolved  string `json:"resolved"`
			Integrity string `json:"integrity"`
			Link      bool   `json:"link"`
			InBundle  bool   `json:"inBundle"`
		} `json:"packages"`
	}
	if err = json.Unmarshal(data, &lock); err != nil {
		return map[string]any{"decode_error": err.Error()}
	}
	fact := map[string]any{"lockfile_version": lock.LockfileVersion, "packages": nil}
	if lock.Packages != nil {
		packages := map[string]any{}
		for name, pkg := range lock.Packages {
			item := map[string]any{"resolved": pkg.Resolved, "integrity": pkg.Integrity, "link": pkg.Link, "in_bundle": pkg.InBundle}
			if u, err := url.Parse(pkg.Resolved); err != nil {
				item["url_error"] = err.Error()
			} else {
				item["url"] = map[string]any{"scheme": u.Scheme, "host": u.Host, "user": u.User != nil,
					"opaque": u.Opaque, "raw_query": u.RawQuery, "fragment": u.Fragment}
			}
			packages[name] = item
		}
		fact["packages"] = packages
	}
	return fact
}

// packageFact decodes a package.json's scripts as an npm-run preparation reads them.
func packageFact(name string) map[string]any {
	data, err := os.ReadFile(name)
	if err != nil {
		return map[string]any{"read_error": err.Error()}
	}
	var manifest struct {
		Scripts map[string]any `json:"scripts"`
	}
	if err = json.Unmarshal(data, &manifest); err != nil {
		return map[string]any{"decode_error": err.Error()}
	}
	return map[string]any{"scripts": manifest.Scripts}
}

// toolFact looks name up on PATH as the preparation runner does (exec.LookPath) and resolves what
// it found.
func toolFact(name string) map[string]any {
	fact := map[string]any{"name": name}
	found, err := exec.LookPath(name)
	fact["found"] = found
	if err != nil {
		fact["error"] = err.Error()
		return fact
	}
	absolute, err := filepath.Abs(found)
	if err == nil {
		absolute, err = filepath.EvalSymlinks(absolute)
	}
	if err != nil {
		fact["resolve_error"] = err.Error()
		return fact
	}
	fact["resolved"] = absolute
	return fact
}
