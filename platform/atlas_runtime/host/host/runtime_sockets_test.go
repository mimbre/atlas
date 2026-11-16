package host

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// expectedRuntimeSockets are the Unix sockets the Runtime serves in its home (runtime.sock in
// entrypoints/socket.ex, read.sock in entrypoints/read_socket.ex, backend.sock in backend/listener.ex).
// They are written out rather than taken from runtimeSockets, so a socket dropped from that list fails.
var expectedRuntimeSockets = []string{"runtime.sock", "read.sock", "backend.sock"}

// socketPaths are the expectedRuntimeSockets in home.
func socketPaths(home string) []string {
	var paths []string
	for _, name := range expectedRuntimeSockets {
		paths = append(paths, filepath.Join(home, name))
	}
	return paths
}

// socketRules are the Claude Read deny rules of the socketPaths.
func socketRules(home string) []string {
	var rules []string
	for _, path := range socketPaths(home) {
		rules = append(rules, "Read(/"+path+")")
	}
	return rules
}

// socketNone renders the socketPaths as Codex filesystem entries, each prefixed by a comma.
func socketNone(home string) string {
	var rendered strings.Builder
	for _, path := range socketPaths(home) {
		rendered.WriteString("," + quoted(path) + `="none"`)
	}
	return rendered.String()
}

// codexDeniesEverySocket fails unless the Codex permission profile args denies every expected
// Runtime socket in home by path.
func codexDeniesEverySocket(t *testing.T, subject string, args []string, err error, home string) {
	t.Helper()
	if err != nil {
		t.Fatalf("%s: %v", subject, err)
	}
	for _, path := range socketPaths(home) {
		if !strings.Contains(args[3], quoted(path)+`="none"`) {
			t.Errorf("%s does not deny the Runtime socket %s: %s", subject, path, args[3])
		}
	}
}

// claudeDeniesEverySocket fails unless the Claude settings deny every expected Runtime socket in home
// to the file tools (a Read rule) and, when the settings have a Bash sandbox, to its reads and writes.
func claudeDeniesEverySocket(t *testing.T, subject, encoded string, err error, home string, sandbox bool) {
	t.Helper()
	if err != nil {
		t.Fatalf("%s: %v", subject, err)
	}
	var settings struct {
		Sandbox struct {
			Filesystem struct{ DenyWrite, DenyRead, AllowRead []string }
		}
		Permissions struct{ Deny []string }
	}
	if err := json.Unmarshal([]byte(encoded), &settings); err != nil {
		t.Fatal(err)
	}
	filesystem := settings.Sandbox.Filesystem
	for _, path := range socketPaths(home) {
		if !slices.Contains(settings.Permissions.Deny, "Read(/"+path+")") {
			t.Errorf("%s has no Read rule for the Runtime socket %s: %s", subject, path, encoded)
		}
		if sandbox && (!slices.Contains(filesystem.DenyRead, path) || !slices.Contains(filesystem.DenyWrite, path) ||
			slices.ContainsFunc(filesystem.AllowRead, func(allowed string) bool { return within(allowed, path) })) {
			t.Errorf("%s does not deny Bash the Runtime socket %s: %s", subject, path, encoded)
		}
	}
}

// The Codex profiles, each with a workspace outside the Runtime home and, where one may lie there, inside it.

func TestCodexReadOnlyDeniesEveryRuntimeSocket(t *testing.T) {
	user := isolatedHome(t)
	home, _ := runtimeHomeWithToken(t, user)
	for _, workspace := range []string{filepath.Join(user, "project"), filepath.Join(home, "workspace")} {
		args, err := sandboxArguments("read-only", workspace, home)
		codexDeniesEverySocket(t, "read-only "+workspace, args, err, home)
	}
}

func TestCodexWorkspaceWriteDeniesEveryRuntimeSocket(t *testing.T) {
	user := isolatedHome(t)
	home, _ := runtimeHomeWithToken(t, user)
	for _, workspace := range []string{filepath.Join(user, "project"), filepath.Join(home, "workspace")} {
		args, err := sandboxArguments("workspace-write", workspace, home)
		codexDeniesEverySocket(t, "workspace-write "+workspace, args, err, home)
	}
}

func TestCodexDedicatedRepositoryDeniesEveryRuntimeSocket(t *testing.T) {
	user := isolatedHome(t)
	home, _ := runtimeHomeWithToken(t, user)
	// Independent, managed below the home, and managed with the sockets present at launch.
	for _, root := range []string{filepath.Join(user, "repo"), filepath.Join(home, "workers", "w1", "repo"), ""} {
		if root == "" {
			for _, name := range expectedRuntimeSockets {
				if err := os.WriteFile(filepath.Join(home, name), nil, 0600); err != nil {
					t.Fatal(err)
				}
			}
			root = filepath.Join(home, "workers", "w2", "repo")
		}
		args, err := permissionArguments(map[string]any{"profile": "dedicated-repository", "root": root}, "", "", home)
		codexDeniesEverySocket(t, "dedicated-repository "+root, args, err, home)
	}
}

func TestCodexMaterializedFolderDeniesEveryRuntimeSocket(t *testing.T) {
	user := isolatedHome(t)
	home := filepath.Join(user, "runtime")
	scope := materialize(t, home, filepath.Join(user, "work"))
	args, err := permissionArguments(scope, filepath.Join(home, "scratch", "turn-1"), filepath.Join(user, "bin", "atlas-runtime"), "")
	codexDeniesEverySocket(t, "materialized-folder", args, err, home)
}

func TestCodexReviewPacketDeniesEveryRuntimeSocket(t *testing.T) {
	user := isolatedHome(t)
	home, dest := filepath.Join(user, "runtime"), filepath.Join(user, "work")
	materialize(t, home, dest)
	scope := freeze(t, home, dest, filepath.Join(user, "packet"), packetID)
	args, err := permissionArguments(scope, filepath.Join(home, "scratch", "turn-1"), filepath.Join(user, "bin", "atlas-runtime"), "")
	codexDeniesEverySocket(t, "review-packet", args, err, home)
}

// The Claude profiles. Claude has no workspace-write mode: claudeValidate refuses it.

func claudeUser(t *testing.T) string {
	t.Helper()
	user := isolatedHomeIn(t, outsideSystemTemp(t))
	t.Setenv("TMPDIR", t.TempDir())
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	return user
}

func TestClaudeReadOnlyDeniesEveryRuntimeSocket(t *testing.T) {
	user := claudeUser(t)
	home, _ := runtimeHomeWithToken(t, user)
	// Inside the home the home itself gets no Read rule (it would deny the workspace); the sockets still do.
	for _, workspace := range []string{filepath.Join(user, "project"), filepath.Join(home, "workspace")} {
		encoded, err := claudeReadOnlySettings(workspace, home)
		claudeDeniesEverySocket(t, "read-only "+workspace, encoded, err, home, false)
	}
	if err := claudeValidate(nil, "workspace-write", "", nil, nil); err == nil {
		t.Fatal("Claude accepted workspace-write")
	}
}

func TestClaudeDedicatedRepositoryDeniesEveryRuntimeSocket(t *testing.T) {
	user := claudeUser(t)
	home, _ := runtimeHomeWithToken(t, user)
	// A managed repository below the home re-allows Bash reads of the repository only, never of a socket.
	for _, root := range []string{filepath.Join(user, "repo"), filepath.Join(home, "workers", "w1", "repo")} {
		encoded, err := claudeRepositorySettings(testScope(root), "/u/.ac-12345678", home)
		claudeDeniesEverySocket(t, "dedicated-repository "+root, encoded, err, home, true)
	}
}

func TestClaudeMaterializedFolderDeniesEveryRuntimeSocket(t *testing.T) {
	user := claudeUser(t)
	home := filepath.Join(user, "runtime")
	scope := materialize(t, home, filepath.Join(user, "work"))
	encoded, err := claudeFolderSettings(scope, "/u/.ac-12345678", user, filepath.Join(user, "bin", "atlas-runtime"))
	claudeDeniesEverySocket(t, "materialized-folder", encoded, err, home, true)
}

func TestClaudeReviewPacketDeniesEveryRuntimeSocket(t *testing.T) {
	user := claudeUser(t)
	home, dest := filepath.Join(user, "runtime"), filepath.Join(user, "work")
	materialize(t, home, dest)
	scope := freeze(t, home, dest, filepath.Join(user, "packet"), packetID)
	encoded, err := claudePacketSettings(scope, "/u/.ac-12345678", user, filepath.Join(user, "bin", "atlas-runtime"))
	claudeDeniesEverySocket(t, "review-packet", encoded, err, home, true)
}
