package snapshot

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"unicode/utf8"
)

const (
	// maxText bounds the files Inspect classifies and diffs; larger content changes get a note.
	maxText = 1 << 20
	// maxEdits bounds the changed lines one textual diff may have.
	maxEdits = 2000
)

// change is one difference between a materialized folder and its baseline.
type change struct {
	Repository string `json:"repository"`
	Path       string `json:"path"`
	Change     string `json:"change"`
	Binary     bool   `json:"binary,omitempty"`
	OldMode    string `json:"old_mode,omitempty"`
	NewMode    string `json:"new_mode,omitempty"`
	OldTarget  string `json:"old_target,omitempty"`
	NewTarget  string `json:"new_target,omitempty"`
	OldKind    string `json:"old_kind,omitempty"`
	NewKind    string `json:"new_kind,omitempty"`
	Note       string `json:"note,omitempty"`
	Diff       string `json:"diff,omitempty"`
}

type inspection struct {
	dest, tree string
	diffs      bool
	changes    []change
}

// Inspect compares the folder dest, published by Materialize, with its recorded baseline
// without writing to either. paths selects repository paths; none selects every repository
// and also reports anything outside them. diffs adds unified diffs for text content changes.
func Inspect(home, dest string, paths []string, diffs bool) (map[string]any, error) {
	dest, err := materialized(dest)
	if err != nil {
		return nil, err
	}
	id, err := recorded(home, dest)
	if err != nil {
		return nil, err
	}
	baseline := filepath.Join(home, "snapshots", strings.TrimPrefix(id, "sha256:"))
	m, entries, err := loadBaseline(baseline, id)
	if err != nil {
		return nil, err
	}
	selected := m.Repositories
	if len(paths) > 0 {
		selected = nil
		for _, r := range m.Repositories {
			if slices.Contains(paths, r.Path) {
				selected = append(selected, r)
			}
		}
		for _, path := range paths {
			if !slices.ContainsFunc(selected, func(r repository) bool { return r.Path == path }) {
				known := []string{}
				for _, r := range m.Repositories {
					known = append(known, r.Path)
				}
				return nil, fmt.Errorf("--path %q is not a materialized repository path; use one of %q", path, known)
			}
		}
	}

	in := &inspection{dest: dest, tree: filepath.Join(baseline, "tree"), diffs: diffs}
	seen := map[string]bool{}
	// WalkDir never follows symlinks, so a symlinked directory is compared as a link.
	err = filepath.WalkDir(dest, func(name string, d fs.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("cannot inspect %s: %v", name, err)
		}
		if name == dest {
			return nil
		}
		rel, err := filepath.Rel(dest, name)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		r := owner(m.Repositories, rel)
		if r == nil || !slices.Contains(selected, *r) {
			if d.IsDir() && len(paths) > 0 && !slices.ContainsFunc(selected, func(s repository) bool { return within(rel, s.Path) }) {
				return filepath.SkipDir
			}
			if d.IsDir() || len(paths) > 0 || r != nil {
				return nil
			}
			// Outside every repository: reported as added, without a repository.
			return in.added(repository{}, name, rel, d)
		}
		e := entries[rel]
		if e == nil {
			if d.IsDir() {
				return nil // a new directory's files are reported one by one; empty ones not at all
			}
			return in.added(*r, name, rel, d)
		}
		seen[rel] = true
		return in.compare(*r, name, e, d)
	})
	if err != nil {
		return nil, err
	}
	for _, r := range selected {
		for i := range m.Entries {
			if e := &m.Entries[i]; within(r.Path, e.Path) && !seen[e.Path] {
				c := change{Repository: r.Repository, Path: e.Path, Change: "deleted", OldTarget: target(e)}
				if e.Kind == "file" {
					if err = in.content(&c, e, nil, false); err != nil {
						return nil, err
					}
				}
				in.changes = append(in.changes, c)
			}
		}
	}
	slices.SortFunc(in.changes, func(a, b change) int { return strings.Compare(a.Path, b.Path) })
	if in.changes == nil {
		in.changes = []change{}
	}
	return map[string]any{"snapshot_id": id, "destination": dest, "clean": len(in.changes) == 0, "changes": in.changes}, nil
}

// materialized resolves dest like Materialize did and requires an existing real directory there.
func materialized(dest string) (string, error) {
	dest, err := filepath.Abs(dest)
	if err != nil {
		return "", err
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(dest))
	if err != nil {
		return "", fmt.Errorf("destination %s does not exist: %v", dest, reason(err))
	}
	dest = filepath.Join(parent, filepath.Base(dest))
	info, err := os.Lstat(dest)
	if err != nil {
		return "", fmt.Errorf("destination %s does not exist: %v", dest, reason(err))
	}
	if !info.IsDir() {
		return "", fmt.Errorf("destination %s is not a directory", dest)
	}
	return dest, nil
}

// recorded returns the snapshot ID Materialize recorded for dest.
func recorded(home, dest string) (string, error) {
	path := filepath.Join(home, "materializations", fmt.Sprintf("%x.json", sha256.Sum256([]byte(dest))))
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return "", fmt.Errorf("no materialization record for %s", dest)
	} else if err != nil {
		return "", fmt.Errorf("cannot read materialization record %s: %v", path, reason(err))
	}
	var r struct {
		Destination string `json:"destination"`
		SnapshotID  string `json:"snapshot_id"`
	}
	if json.Unmarshal(data, &r) != nil || r.Destination != dest || !snapshotID.MatchString(r.SnapshotID) {
		return "", fmt.Errorf("invalid materialization record %s for %s", path, dest)
	}
	return r.SnapshotID, nil
}

// loadBaseline verifies the completion marker, the manifest identity and its entries.
func loadBaseline(baseline, id string) (*manifest, map[string]*entry, error) {
	marker, err := os.ReadFile(filepath.Join(baseline, "complete"))
	if err != nil || string(marker) != id+"\n" {
		return nil, nil, fmt.Errorf("baseline %s for %s is missing or incomplete", baseline, id)
	}
	raw, err := os.ReadFile(filepath.Join(baseline, "manifest.json"))
	if err != nil {
		return nil, nil, fmt.Errorf("cannot read baseline manifest: %v", err)
	}
	if sum := sha256.Sum256(raw); "sha256:"+hex.EncodeToString(sum[:]) != id {
		return nil, nil, fmt.Errorf("baseline manifest %s hashes to sha256:%x, not %s", filepath.Join(baseline, "manifest.json"), sum, id)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	var m manifest
	if err = decoder.Decode(&m); err != nil {
		return nil, nil, fmt.Errorf("invalid baseline manifest: %v", err)
	}
	m.SnapshotID = id
	entries, err := m.check(id, m.canonical())
	if err != nil {
		return nil, nil, fmt.Errorf("invalid baseline manifest: %v", err)
	}
	return &m, entries, nil
}

func owner(repositories []repository, path string) *repository {
	for i := range repositories {
		if within(repositories[i].Path, path) {
			return &repositories[i]
		}
	}
	return nil
}

func target(e *entry) string {
	if e.Target == nil {
		return ""
	}
	return *e.Target
}

// kind names what d is: file, symlink, directory or other (a FIFO, socket or device).
func kind(d fs.DirEntry) string {
	switch {
	case d.Type().IsRegular():
		return "file"
	case d.Type()&fs.ModeSymlink != 0:
		return "symlink"
	case d.IsDir():
		return "directory"
	}
	return "other"
}

func mode(d fs.DirEntry) (string, error) {
	info, err := d.Info()
	if err != nil {
		return "", err
	}
	if info.Mode()&0111 != 0 {
		return "100755", nil
	}
	return "100644", nil
}

func (in *inspection) added(r repository, name, rel string, d fs.DirEntry) error {
	c := change{Repository: r.Repository, Path: rel, Change: "added"}
	switch kind(d) {
	case "symlink":
		link, err := os.Readlink(name)
		if err != nil {
			return err
		}
		c.NewTarget = link
	case "file":
		data, _, large, err := readFile(name)
		if err != nil {
			return err
		}
		if err = in.content(&c, nil, data, large); err != nil {
			return err
		}
	default:
		c.NewKind = "other"
	}
	in.changes = append(in.changes, c)
	return nil
}

// compare reports how the worker's name differs from manifest entry e, if it does.
func (in *inspection) compare(r repository, name string, e *entry, d fs.DirEntry) error {
	c := change{Repository: r.Repository, Path: e.Path}
	now := kind(d)
	var link string
	if now == "symlink" {
		var err error
		if link, err = os.Readlink(name); err != nil {
			return err
		}
	}
	switch {
	case now != e.Kind:
		c.Change, c.OldKind, c.NewKind, c.OldTarget, c.NewTarget = "kind", e.Kind, now, target(e), link
	case now == "symlink":
		if link == *e.Target {
			return nil
		}
		c.Change, c.OldTarget, c.NewTarget = "symlink", *e.Target, link
	default:
		data, sum, large, err := readFile(name)
		if err != nil {
			return err
		}
		m, err := mode(d)
		if err != nil {
			return err
		}
		if m != e.Mode {
			c.Change, c.OldMode, c.NewMode = "mode", e.Mode, m
		}
		if sum == e.SHA256 {
			if c.Change == "" {
				return nil
			}
			break
		}
		// A content change that also flips the executable bit is one "modified" entry with both modes.
		c.Change = "modified"
		if err = in.content(&c, e, data, large); err != nil {
			return err
		}
	}
	in.changes = append(in.changes, c)
	return nil
}

// content classifies a file content change and, for diffs, adds its unified diff. old is the
// baseline entry (nil when added); data is the worker's content (unused when deleted).
func (in *inspection) content(c *change, old *entry, data []byte, large bool) error {
	if large || old != nil && old.Size > maxText {
		c.Note = "larger than 1 MiB: not classified or diffed"
		return nil
	}
	var before []byte
	if old != nil {
		var err error
		if before, err = in.baselineFile(old); err != nil {
			return err
		}
	}
	if binary(before) || binary(data) {
		c.Binary = true
		return nil
	}
	if !in.diffs {
		return nil
	}
	from, to := "a/"+c.Path, "b/"+c.Path
	switch c.Change {
	case "added":
		from = "/dev/null"
	case "deleted":
		to = "/dev/null"
	}
	diff, ok := unified(from, to, lines(before), lines(data))
	if !ok {
		c.Note = fmt.Sprintf("more than %d changed lines: no text diff", maxEdits)
	}
	c.Diff = diff
	return nil
}

// baselineFile returns e's baseline content, verified against the manifest.
func (in *inspection) baselineFile(e *entry) ([]byte, error) {
	name := filepath.Join(in.tree, filepath.FromSlash(e.Path))
	data, sum, _, err := readFile(name)
	if err != nil || sum != e.SHA256 {
		return nil, fmt.Errorf("baseline file %s is missing or does not match the manifest", name)
	}
	return data, nil
}

// readFile hashes a regular file read-only and returns its content up to maxText bytes;
// large reports that it is longer and data is nil. Symlinks are never followed.
func readFile(name string) (data []byte, sum string, large bool, err error) {
	// O_NONBLOCK: a FIFO swapped in after the walk must not hang the inspection.
	file, err := os.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, "", false, err
	}
	defer file.Close()
	if data, err = io.ReadAll(io.LimitReader(file, maxText+1)); err != nil {
		return nil, "", false, err
	}
	hash := sha256.New()
	hash.Write(data)
	if len(data) > maxText {
		if _, err = io.Copy(hash, file); err != nil {
			return nil, "", false, err
		}
		data, large = nil, true
	}
	return data, hex.EncodeToString(hash.Sum(nil)), large, nil
}

func binary(data []byte) bool { return bytes.IndexByte(data, 0) >= 0 || !utf8.Valid(data) }

// lines splits text after each newline; a last line without one keeps no terminator.
func lines(data []byte) []string {
	result := strings.SplitAfter(string(data), "\n")
	return result[:len(result)-1+min(1, len(result[len(result)-1]))]
}

type edit struct {
	op   byte // ' ', '-' or '+'
	line string
}

// unified renders a unified diff with 3 lines of context; ok is false and the diff empty
// when more than maxEdits lines changed. Identical or two empty inputs give "".
func unified(from, to string, a, b []string) (string, bool) {
	prefix := 0
	for prefix < len(a) && prefix < len(b) && a[prefix] == b[prefix] {
		prefix++
	}
	suffix := 0
	for suffix < len(a)-prefix && suffix < len(b)-prefix && a[len(a)-1-suffix] == b[len(b)-1-suffix] {
		suffix++
	}
	middle, ok := myers(a[prefix:len(a)-suffix], b[prefix:len(b)-suffix])
	if !ok {
		return "", false
	}
	edits := make([]edit, 0, prefix+len(middle)+suffix)
	for _, line := range a[:prefix] {
		edits = append(edits, edit{' ', line})
	}
	edits = append(edits, middle...)
	for _, line := range a[len(a)-suffix:] {
		edits = append(edits, edit{' ', line})
	}

	// oldAt[i] and newAt[i] count the old and new lines before edits[i].
	oldAt, newAt := make([]int, len(edits)+1), make([]int, len(edits)+1)
	for i, e := range edits {
		oldAt[i+1], newAt[i+1] = oldAt[i], newAt[i]
		if e.op != '+' {
			oldAt[i+1]++
		}
		if e.op != '-' {
			newAt[i+1]++
		}
	}
	var out strings.Builder
	for i := 0; i < len(edits); {
		if edits[i].op == ' ' {
			i++
			continue
		}
		start, end := max(0, i-3), i
		for {
			for end < len(edits) && edits[end].op != ' ' {
				end++
			}
			next := end
			for next < len(edits) && edits[next].op == ' ' {
				next++
			}
			if next == len(edits) || next-end > 6 {
				break
			}
			end = next
		}
		stop := min(len(edits), end+3)
		if out.Len() == 0 {
			fmt.Fprintf(&out, "--- %s\n+++ %s\n", from, to)
		}
		fmt.Fprintf(&out, "@@ -%s +%s @@\n", hunkRange(oldAt[start], oldAt[stop]-oldAt[start]), hunkRange(newAt[start], newAt[stop]-newAt[start]))
		for _, e := range edits[start:stop] {
			out.WriteByte(e.op)
			out.WriteString(e.line)
			if !strings.HasSuffix(e.line, "\n") {
				out.WriteString("\n\\ No newline at end of file\n")
			}
		}
		i = stop
	}
	return out.String(), true
}

// hunkRange is diff's "start,count": count 1 is omitted and an empty range starts at the line before.
func hunkRange(before, count int) string {
	switch count {
	case 0:
		return fmt.Sprintf("%d,0", before)
	case 1:
		return fmt.Sprintf("%d", before+1)
	}
	return fmt.Sprintf("%d,%d", before+1, count)
}

// myers returns a shortest edit script from a to b (Myers 1986), or false beyond maxEdits.
func myers(a, b []string) ([]edit, bool) {
	n, m := len(a), len(b)
	offset := n + m + 1
	v := make([]int, 2*offset+1)
	var trace [][]int // trace[d][k+d] is the furthest x on diagonal k after d edits
	for d := 0; d <= n+m; d++ {
		if d > maxEdits {
			return nil, false
		}
		for k := -d; k <= d; k += 2 {
			x := v[offset+k-1] + 1
			if k == -d || k != d && v[offset+k-1] < v[offset+k+1] {
				x = v[offset+k+1]
			}
			y := x - k
			for x < n && y < m && a[x] == b[y] {
				x, y = x+1, y+1
			}
			v[offset+k] = x
			if x >= n && y >= m {
				trace = append(trace, slices.Clone(v[offset-d:offset+d+1]))
				return backtrack(a, b, trace), true
			}
		}
		trace = append(trace, slices.Clone(v[offset-d:offset+d+1]))
	}
	return nil, true // unreachable: d = n+m always reaches the end
}

func backtrack(a, b []string, trace [][]int) []edit {
	x, y := len(a), len(b)
	var reversed []edit
	for d := len(trace) - 1; d > 0; d-- {
		previous := trace[d-1]
		k := x - y
		down := k == -d || k != d && previous[k-1+d-1] < previous[k+1+d-1]
		pk := k - 1
		if down {
			pk = k + 1
		}
		px := previous[pk+d-1]
		py := px - pk
		// The edit lands on (px, py+1) going down or (px+1, py) going right; a snake follows.
		snake := px
		if !down {
			snake++
		}
		for x > snake {
			x, y = x-1, y-1
			reversed = append(reversed, edit{' ', a[x]})
		}
		if down {
			reversed = append(reversed, edit{'+', b[py]})
		} else {
			reversed = append(reversed, edit{'-', a[px]})
		}
		x, y = px, py
	}
	for x > 0 {
		x, y = x-1, y-1
		reversed = append(reversed, edit{' ', a[x]})
	}
	slices.Reverse(reversed)
	return reversed
}
