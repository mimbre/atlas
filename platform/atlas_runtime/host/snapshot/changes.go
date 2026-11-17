package snapshot

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
)

// afterChangesCapture runs between capturing the blobs and the second scan; tests change the folder there.
var afterChangesCapture = func() {}

// Failure is a refusal of snapshot changes or compose with its stable code; the CLI writes the
// code beside the error text, so a caller branches on the code and never on the text.
type Failure struct {
	Code string
	err  error
}

func (f *Failure) Error() string { return f.err.Error() }

func (f *Failure) Unwrap() error { return f.err }

// Result is the code the CLI reports with the error.
func (f *Failure) Result() map[string]any { return map[string]any{"code": f.Code} }

func fail(kind string, err error) error { return &Failure{Code: kind, err: err} }

func failf(kind, format string, args ...any) error { return fail(kind, fmt.Errorf(format, args...)) }

// changedRoot is one baseline repository of a change set: its path and its Code-shaped entries.
type changedRoot struct {
	Root    string        `json:"root"`
	Entries []changeEntry `json:"entries"`
}

// Changes reports the folder dest, published by Materialize or Compose, as a change set against
// its recorded baseline: every baseline repository with its entries (none when it is unchanged)
// and the paths outside every repository. Every written file's content is kept in blobs as
// blobs/<sha256> (read-only; an existing blob is kept). It takes the folder lock and scans twice;
// the result is reported only when both scans agree. It writes nothing to dest or its baseline,
// works on a read-only dest, and never contacts Code or runs Git.
func Changes(home, dest, blobs string) (map[string]any, error) {
	canonical, err := materialized(dest)
	if err != nil {
		return nil, fail("io", err)
	}
	if _, err = os.Lstat(recordPath(home, canonical)); errors.Is(err, fs.ErrNotExist) {
		return nil, failf("not_materialized", "no materialization record for %s", canonical)
	}
	f, err := openFolder(home, canonical)
	if err != nil {
		return nil, fail("io", err)
	}
	lock, err := hold(f.dest, "scan", "nothing was reported")
	if err != nil {
		// hold's refusal while a worker, preparation or another command owns the folder.
		if strings.Contains(err.Error(), "has an active Runtime owner") {
			return nil, fail("busy", err)
		}
		return nil, fail("io", err)
	}
	defer lock.Close()

	// The check compares canonical paths: a DIR reached through a symlink, a firmlink or another
	// case spelling of the folder still lies inside it, and is refused before anything is created.
	if blobs, err = canonicalTarget(blobs); err != nil {
		return nil, fail("io", err)
	}
	if within(f.dest, blobs) {
		return nil, failf("io", "blob folder %s lies inside the folder %s", blobs, f.dest)
	}
	if err = os.MkdirAll(blobs, 0700); err != nil {
		return nil, fail("io", err)
	}
	captured, err := os.MkdirTemp(blobs, ".changes-*")
	if err != nil {
		return nil, fail("io", err)
	}
	defer os.RemoveAll(captured)

	first, err := f.scan(captured)
	if err != nil {
		return nil, err
	}
	afterChangesCapture()
	// The blobs come from the first scan. A second scan that hashes the folder again must agree,
	// so a change set never mixes content from before and after an edit.
	second, err := f.scan("")
	if err != nil {
		return nil, err
	}
	if !reflect.DeepEqual(first, second) {
		return nil, failf("changed_during_scan", "folder %s changed during the scan; nothing was reported, run the command again", f.dest)
	}
	if err = publishBlobs(captured, blobs); err != nil {
		return nil, fail("io", err)
	}
	return map[string]any{"snapshot_id": f.id, "roots": first.Roots, "outside": first.Outside}, nil
}

// canonicalTarget is the canonical form of path, which need not exist yet: its nearest existing
// ancestor resolved by the kernel (symlinks followed), with the missing components appended.
func canonicalTarget(path string) (string, error) {
	path, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	missing := []string{}
	for {
		info, err := os.Lstat(path)
		if errors.Is(err, fs.ErrNotExist) && filepath.Dir(path) != path {
			missing = append([]string{filepath.Base(path)}, missing...)
			path = filepath.Dir(path)
			continue
		}
		if err != nil {
			return "", err
		}
		if info.Mode()&fs.ModeSymlink != 0 {
			if path, err = filepath.EvalSymlinks(path); err != nil {
				return "", err
			}
		}
		if path, err = canonicalDirectory(path); err != nil {
			return "", err
		}
		return filepath.Join(append([]string{path}, missing...)...), nil
	}
}

// scanned is one scan of a folder: every root in manifest order and the outside paths.
type scanned struct {
	Roots   []changedRoot
	Outside []string
}

// scan converts the folder's changes into every root's entries; with blobs set, every written
// file is copied there under its sha256. Content a change set cannot hold is refused, never left out.
func (f *folder) scan(blobs string) (*scanned, error) {
	changes, err := f.changes(nil, false)
	if err != nil {
		return nil, fail("io", err)
	}
	result := &scanned{Roots: []changedRoot{}, Outside: []string{}}
	for _, c := range changes {
		if c.Repository == "" {
			if c.NewKind == "other" {
				return nil, failf("unsupported_entry", "cannot report %s: only files, symlinks and directories can be reported, not a FIFO, socket or device", c.Path)
			}
			result.Outside = append(result.Outside, c.Path)
		}
	}
	for _, r := range f.m.Repositories {
		mine := []change{}
		for _, c := range changes {
			if within(r.Path, c.Path) {
				mine = append(mine, c)
			}
		}
		if err = f.ancestors(r); err != nil {
			return nil, fail("unsupported_entry", err)
		}
		entries, err := f.convert(r, mine, blobs)
		if err != nil {
			// A file that vanished or changed kind after the walk is a concurrent change, not
			// unsupported content: the folder no longer matches the walk that listed it.
			if again, cerr := f.changes(nil, false); cerr != nil || !reflect.DeepEqual(again, changes) {
				return nil, failf("changed_during_scan", "folder %s changed during the scan (%v); nothing was reported, run the command again", f.dest, err)
			}
			return nil, fail("unsupported_entry", err)
		}
		result.Roots = append(result.Roots, changedRoot{Root: r.Path, Entries: entries})
	}
	return result, nil
}

// publishBlobs moves every captured blob into dir as a read-only file named by its sha256. An
// existing blob is kept: blobs are content-addressed, so it holds the same bytes.
func publishBlobs(captured, dir string) error {
	names, err := os.ReadDir(captured)
	if err != nil {
		return err
	}
	for _, name := range names {
		if !digest.MatchString(name.Name()) {
			continue // a .blob-* temporary left by a refused capture
		}
		from := filepath.Join(captured, name.Name())
		if err = os.Chmod(from, 0444); err != nil {
			return err
		}
		if err = renameExclusive(from, filepath.Join(dir, name.Name())); err != nil && !errors.Is(err, fs.ErrExist) {
			return err
		}
	}
	return nil
}
