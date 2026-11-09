package host

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// readOnlyTree builds what a worker can leave in its scratch: read-only files in read-only and
// unreadable directories, plus symlinks to a file and a directory outside the scratch.
func readOnlyTree(t *testing.T) (scratch, outside, outsideFile string) {
	t.Helper()
	root := t.TempDir()
	scratch, outside = filepath.Join(root, "scratch"), filepath.Join(root, "outside")
	outsideFile = filepath.Join(outside, "kept.txt")
	nested := filepath.Join(scratch, "tmp", "baseline", "snapshot")
	for _, directory := range []string{nested, outside} {
		if err := os.MkdirAll(directory, 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, file := range []string{filepath.Join(nested, "rebind_test.go"), outsideFile} {
		if err := os.WriteFile(file, []byte("x"), 0400); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chmod(outside, 0500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(outside, 0700) })
	for link, target := range map[string]string{"file-link": outsideFile, "directory-link": outside} {
		if err := os.Symlink(target, filepath.Join(scratch, "tmp", link)); err != nil {
			t.Fatal(err)
		}
	}
	for directory, mode := range map[string]os.FileMode{nested: 0500, filepath.Dir(nested): 0, filepath.Join(scratch, "tmp"): 0500} {
		if err := os.Chmod(directory, mode); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { removeScratch(scratch) })
	// Plain removal fails as on the host after the outage (its error can wrap an unprintable Go
	// internal symlink error, so only its presence is checked).
	if os.RemoveAll(scratch) == nil {
		t.Fatal("fixture is not read-only")
	}
	return scratch, outside, outsideFile
}

func TestRemoveScratchRemovesReadOnlyTreesWithoutFollowingLinks(t *testing.T) {
	scratch, outside, outsideFile := readOnlyTree(t)
	if err := removeScratch(scratch); err != nil {
		t.Fatalf("read-only scratch not removed: %v", err)
	}
	if _, err := os.Lstat(scratch); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("scratch remains: %v", err)
	}
	// Link targets keep their content and their read-only modes.
	for path, mode := range map[string]os.FileMode{outside: 0500, outsideFile: 0400} {
		info, err := os.Lstat(path)
		if err != nil || info.Mode().Perm() != mode {
			t.Fatalf("link target %s changed: %v %v", path, info, err)
		}
	}
	if content, err := os.ReadFile(outsideFile); err != nil || string(content) != "x" {
		t.Fatalf("link target content changed: %q %v", content, err)
	}
}

func TestRemoveScratchAcceptsAMissingTree(t *testing.T) {
	if err := removeScratch(filepath.Join(t.TempDir(), "absent")); err != nil {
		t.Fatal(err)
	}
}

// A worker that leaves a read-only scratch still ends a completed turn successfully, and the
// host removes the scratch without touching what a scratch symlink points at.
func TestFolderLaunchRemovesReadOnlyScratchAfterCompletion(t *testing.T) {
	dest, home, folder, _, _, scope := folderLaunch(t, "")
	outside := filepath.Join(filepath.Dir(home), "outside.txt")
	if err := os.WriteFile(outside, []byte("x"), 0400); err != nil {
		t.Fatal(err)
	}
	native := fixture(t, folder, `mkdir -p "$TMPDIR/baseline/snapshot" && echo x > "$TMPDIR/baseline/snapshot/rebind_test.go"
ln -s `+outside+` "$TMPDIR/baseline/outside"
chmod 0444 "$TMPDIR/baseline/snapshot/rebind_test.go"
chmod 0555 "$TMPDIR/baseline/snapshot" "$TMPDIR/baseline"
printf '%s\n' '{"type":"thread.started","thread_id":"native-session"}' '{"type":"turn.completed"}'
`)
	scratch := filepath.Join(home, "scratch", filepath.Base(folder))
	host := startHost(t, scopedArgs(t, native, dest, folder, scope))
	records, code := host.finish(t)
	if code != 0 || records[len(records)-1]["exit_code"] != 0.0 || records[len(records)-1]["stopped"] != false {
		t.Fatalf("code=%d records=%v stderr=%s", code, records, host.stderr.String())
	}
	if _, err := os.Lstat(scratch); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("read-only scratch not removed: %v", err)
	}
	if info, err := os.Lstat(outside); err != nil || info.Mode().Perm() != 0400 {
		t.Fatalf("symlink target changed: %v %v", info, err)
	}
	if log, _ := os.ReadFile(filepath.Join(folder, "stderr.log")); strings.Contains(string(log), "cleanup warning") {
		t.Fatalf("unexpected cleanup warning: %s", log)
	}
}
