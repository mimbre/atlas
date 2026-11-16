package host

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// An entry the owner cannot unlink even when writable (a user-immutable flag) is a cleanup
// warning in the turn's stderr.log; the completed turn still exits 0.
func TestFolderLaunchReportsUnremovableScratchAsWarning(t *testing.T) {
	dest, home, folder, _, _, scope := folderLaunch(t, "")
	scratch := filepath.Join(home, "scratch", filepath.Base(folder))
	immutable := filepath.Join(scratch, "tmp", "pinned")
	t.Cleanup(func() {
		exec.Command("chflags", "nouchg", immutable).Run()
		os.RemoveAll(scratch)
	})
	native := fixture(t, folder, `echo x > "$TMPDIR/pinned" && chflags uchg "$TMPDIR/pinned" || exit 9
printf '%s\n' '{"type":"thread.started","thread_id":"native-session"}' '{"type":"turn.completed"}'
`)
	host := startHost(t, scopedArgs(t, native, dest, folder, scope))
	records, code := host.finish(t)
	if code != 0 || records[len(records)-1]["exit_code"] != 0.0 {
		t.Fatalf("cleanup problem changed the outcome: code=%d records=%v stderr=%s", code, records, host.stderr.String())
	}
	log, err := os.ReadFile(filepath.Join(folder, "stderr.log"))
	if err != nil || !strings.Contains(string(log), "Native runner cleanup warning: ") || !strings.Contains(string(log), "pinned") {
		t.Fatalf("cleanup warning not recorded: %q %v", log, err)
	}
	if !strings.Contains(host.stderr.String(), "Native runner cleanup warning: ") {
		t.Fatalf("cleanup warning not on host stderr: %q", host.stderr.String())
	}
}
