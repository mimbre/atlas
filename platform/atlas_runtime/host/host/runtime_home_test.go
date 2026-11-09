package host

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"testing"

	"github.com/eyra/atlas/platform/atlas_runtime/host/workspace"
)

// runtimeHomeWithToken is a Runtime home below user whose code.json names a Code token outside it.
func runtimeHomeWithToken(t *testing.T, user string) (home, token string) {
	t.Helper()
	home, token = filepath.Join(user, "runtime"), filepath.Join(user, "code-home", "runtime.token")
	if err := os.MkdirAll(home, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, "code.json"), []byte(fmt.Sprintf(`{"url":"http://127.0.0.1:1","token_file":%q}`, token)), 0600); err != nil {
		t.Fatal(err)
	}
	return home, token
}

func quoted(path string) string { body, _ := json.Marshal(path); return string(body) }

// TestCodexRepositoryAndPlainProfilesDenyTheRuntimeHome pins the Codex profiles that used to leave the
// Runtime home and the Code token readable: dedicated-repository (independent and managed below the
// home) and the plain read-only and workspace-write modes, now explicit profiles of the same built-ins.
func TestCodexRepositoryAndPlainProfilesDenyTheRuntimeHome(t *testing.T) {
	user := isolatedHome(t)
	home, token := runtimeHomeWithToken(t, user)
	denied := quoted(home) + `="none",` + quoted(token) + `="none",` + quoted(filepath.Dir(token)) + `="none"`
	// A managed repository below the home: TestCodexManagedRepositoryDeniesTheRuntimeHomeBesideItsAncestors.
	for _, root := range []string{filepath.Join(user, "repo")} {
		args, err := permissionArguments(map[string]any{"profile": "dedicated-repository", "root": root}, "", "", home)
		if err != nil {
			t.Fatal(err)
		}
		want := []string{"-c", `default_permissions="atlas_repository"`, "-c",
			`permissions={atlas_repository={extends=":read-only",filesystem={` + quoted(root) + `="write",` + quoted(root+"/.git") + `="write",` +
				quoted(root+"/.agents") + `="read",` + quoted(root+"/.codex") + `="read",` + quoted(root+"/.aws") + `="read",` + denied +
				`},network={enabled=true,domains={"github.com"="allow","api.github.com"="allow"}}}}`,
			"-c", "features.network_proxy=true", "-c", `web_search="live"`}
		if !slices.Equal(args, want) {
			t.Fatalf("repository %s:\ngot  %q\nwant %q", root, args, want)
		}
	}
	workspace := filepath.Join(user, "project")
	for _, mode := range [][3]string{{"read-only", "atlas_read_only", ":read-only"}, {"workspace-write", "atlas_workspace_write", ":workspace"}} {
		args, err := sandboxArguments(mode[0], workspace, home)
		if err != nil {
			t.Fatal(err)
		}
		want := []string{"-c", `default_permissions="` + mode[1] + `"`, "-c",
			`permissions={` + mode[1] + `={extends="` + mode[2] + `",filesystem={` + denied + `},network={enabled=false}}}`}
		if !slices.Equal(args, want) {
			t.Fatalf("%s:\ngot  %q\nwant %q", mode[0], args, want)
		}
		// A workspace below the home keeps the mode's access to it as the more specific path; the home itself is refused.
		inside := filepath.Join(home, "workspace")
		access := map[string]string{"read-only": "read", "workspace-write": "write"}[mode[0]]
		args, err = sandboxArguments(mode[0], inside, home)
		if want := `permissions={` + mode[1] + `={extends="` + mode[2] + `",filesystem={` + quoted(inside) + `="` + access + `",` + denied +
			`},network={enabled=false}}}`; err != nil || args[3] != want {
			t.Fatalf("%s workspace inside the home: %v\ngot  %s\nwant %s", mode[0], err, args, want)
		}
		if _, err := sandboxArguments(mode[0], home, home); err == nil || err.Error() != "Workspace "+home+" is the Runtime home" {
			t.Fatalf("%s workspace at the Runtime home accepted: %v", mode[0], err)
		}
	}
	// A repository in the token directory stays writable; the token file stays denied but, like a
	// Runtime home containing the repository, the directory is denied beside the repository's ancestors.
	inToken := filepath.Join(filepath.Dir(token), "repo")
	if args, err := repositoryArguments(map[string]any{"root": inToken}, home); err != nil ||
		!strings.Contains(args[3], quoted(inToken)+`="write"`) || !strings.Contains(args[3], quoted(home)+`="none",`+quoted(token)+`="none"`) ||
		strings.Contains(args[3], quoted(filepath.Dir(token))+`="none"`) {
		t.Fatalf("repository inside the token directory: %q %v", args, err)
	}
	// Without a Code configuration only the home is denied.
	bare := filepath.Join(user, "bare-runtime")
	if args, err := sandboxArguments("read-only", workspace, bare); err != nil || !strings.Contains(args[3], `filesystem={`+quoted(bare)+`="none"}`) {
		t.Fatalf("home without code.json: %q %v", args, err)
	}
	for _, refused := range []struct{ root, home, message string }{
		{home, home, "Workspace " + home + " is the Runtime home"},
		{filepath.Dir(token), home, "Workspace " + filepath.Dir(token) + " is the Code token directory"},
		{filepath.Join(user, "repo"), "", "Runtime home must be an absolute path"},
		{filepath.Join(user, "repo"), "runtime", "Runtime home must be an absolute path"},
	} {
		if _, err := repositoryArguments(map[string]any{"root": refused.root}, refused.home); err == nil || err.Error() != refused.message {
			t.Fatalf("repository %s with home %q: got %v, want %s", refused.root, refused.home, err, refused.message)
		}
	}
}

// TestCodexManagedRepositoryDeniesTheRuntimeHomeBesideItsAncestors pins the Codex profile of a managed
// repository below the Runtime home: Git must lstat the repository's ancestors, so the home and the
// directories down to the repository are not denied whole, but every other entry existing in them is,
// and the sensitive home entries and the Code token are denied by path even when absent at launch.
func TestCodexManagedRepositoryDeniesTheRuntimeHomeBesideItsAncestors(t *testing.T) {
	user := isolatedHome(t)
	home, token := runtimeHomeWithToken(t, user)
	workers := filepath.Join(home, "workers")
	for _, path := range []string{"turns/turn-1/stream.jsonl", "extra.sock", "notes.txt", "workers/w1/admission-latch.json", "workers/w1/repo/.git/HEAD", "workers/w2/repo/file"} {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(home, path)), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(home, path), []byte("x"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	none := func(paths ...string) string {
		var rendered []string
		for _, path := range paths {
			rendered = append(rendered, quoted(path)+`="none"`)
		}
		return strings.Join(rendered, ",")
	}
	sensitive := func(skip ...string) []string {
		var paths []string
		for _, name := range []string{"runtime.sock", "read.sock", "turns", "code.json", "server.json", "backends.json", "policy.json", "availability.json", "service.log",
			"service.lock", "passes", "snapshots", "materializations", "scratch"} {
			if !slices.Contains(skip, name) {
				paths = append(paths, filepath.Join(home, name))
			}
		}
		return paths
	}
	project := func(root string) string {
		return quoted(root) + `="write",` + quoted(root+"/.git") + `="write",` + quoted(root+"/.agents") + `="read",` +
			quoted(root+"/.codex") + `="read",` + quoted(root+"/.aws") + `="read",`
	}
	filesystem := func(args []string) string {
		start := strings.Index(args[3], "filesystem={") + len("filesystem={")
		return args[3][start : start+strings.Index(args[3][start:], "},network=")]
	}
	// The deny-read globs of every workers entry except the named worker directory, each with its subtree.
	globs := func(patterns ...string) []string {
		var paths []string
		for _, pattern := range patterns {
			paths = append(paths, workers+"/"+pattern, workers+"/"+pattern+"/**")
		}
		return paths
	}
	managed := filepath.Join(workers, "w1", "repo")
	args, err := repositoryArguments(map[string]any{"root": managed}, home)
	if err != nil {
		t.Fatal(err)
	}
	// Existing home entries beside workers, workers beside w1 and w1 beside the repository, then the
	// token and its directory, then the sensitive names not already listed, then the sibling worker globs.
	want := project(managed) + none(slices.Concat([]string{filepath.Join(home, "code.json"), filepath.Join(home, "extra.sock"), filepath.Join(home, "notes.txt"),
		filepath.Join(home, "turns"), filepath.Join(workers, "w2"), filepath.Join(workers, "w1", "admission-latch.json"), token, filepath.Dir(token)},
		sensitive("turns", "code.json"), globs("[!w]*", "w[!1]*", "[w]", "w1[!/]*"))...)
	if got := filesystem(args); got != want {
		t.Fatalf("managed repository:\ngot  %s\nwant %s", got, want)
	}
	for _, ancestor := range []string{home, workers, filepath.Join(workers, "w1")} {
		if strings.Contains(args[3], quoted(ancestor)+`="none"`) {
			t.Fatalf("ancestor %s of the managed repository is denied: %s", ancestor, args[3])
		}
	}
	// A repository not yet created (managed preparation) below a worker directory not yet created.
	fresh := filepath.Join(workers, "w9", "repo")
	args, err = repositoryArguments(map[string]any{"root": fresh}, home)
	want = project(fresh) + none(append([]string{filepath.Join(home, "code.json"), filepath.Join(home, "extra.sock"), filepath.Join(home, "notes.txt"),
		filepath.Join(home, "turns"), filepath.Join(workers, "w1"), filepath.Join(workers, "w2"), token, filepath.Dir(token)},
		slices.Concat(sensitive("turns", "code.json"), globs("[!w]*", "w[!9]*", "[w]", "w9[!/]*"))...)...)
	if err != nil || filesystem(args) != want {
		t.Fatalf("repository to prepare: %v\ngot  %s\nwant %s", err, filesystem(args), want)
	}
	// The token in the home (the Elixir fixtures' layout): the token is denied by path, the home is not denied whole.
	if err := os.WriteFile(filepath.Join(home, "code.json"), []byte(fmt.Sprintf(`{"token_file":%q}`, filepath.Join(home, "runtime.token"))), 0600); err != nil {
		t.Fatal(err)
	}
	args, err = repositoryArguments(map[string]any{"root": managed}, home)
	if err != nil || strings.Contains(args[3], quoted(home)+`="none"`) || !strings.Contains(args[3], quoted(filepath.Join(home, "runtime.token"))+`="none"`) ||
		!strings.Contains(args[3], quoted(filepath.Join(workers, "w2"))+`="none"`) {
		t.Fatalf("token in the home: %v %s", err, args)
	}
	// The service lock, passes, snapshot store, materialization records and scratch are denied by path even
	// when absent at launch, so ones created after launch stay out of reach.
	for _, name := range []string{"service.lock", "passes", "snapshots", "materializations", "scratch"} {
		if path := filepath.Join(home, name); !strings.Contains(args[3], quoted(path)+`="none"`) {
			t.Fatalf("absent %s is not denied: %s", path, args[3])
		}
	}
	// A repository inside a sensitive entry is refused rather than re-opening it.
	inside := filepath.Join(home, "turns", "repo")
	if _, err := repositoryArguments(map[string]any{"root": inside}, home); err == nil ||
		err.Error() != "Repository "+inside+" is inside the Runtime home's "+filepath.Join(home, "turns") {
		t.Fatalf("repository inside the turn records accepted: %v", err)
	}
}

// TestClaudeRepositoryAndReadOnlySettingsDenyTheRuntimeHome pins the Claude settings that used to leave
// the Runtime home and the Code token readable: an independent and a managed dedicated repository and
// the plain read-only file tools.
func TestClaudeRepositoryAndReadOnlySettingsDenyTheRuntimeHome(t *testing.T) {
	user := isolatedHomeIn(t, outsideSystemTemp(t))
	t.Setenv("TMPDIR", t.TempDir())
	previous := platform
	platform = "linux"
	t.Cleanup(func() { platform = previous })
	home, token := runtimeHomeWithToken(t, user)
	var roots []string
	for _, path := range []string{"/tmp", "/var/tmp", os.Getenv("TMPDIR")} {
		if resolved, _ := resolvePath(path); !slices.Contains(roots, resolved) {
			roots = append(roots, resolved)
		}
	}
	slices.Sort(roots)
	temporary := "/u/.ac-12345678"
	q := func(values ...string) string { body, _ := json.Marshal(values); return string(body) }
	settings := func(root string, denyWrite, allowRead, rules []string) string {
		filesystem := `{"allowWrite":` + q(root, temporary) + `,"denyWrite":` + q(denyWrite...) + `,"denyRead":` + q(home, token, filepath.Dir(token))
		if allowRead != nil {
			filesystem += `,"allowRead":` + q(allowRead...)
		}
		return `{"sandbox":{"enabled":true,"failIfUnavailable":true,"allowUnsandboxedCommands":false,"excludedCommands":[],"filesystem":` + filesystem +
			`},"network":{"allowedDomains":["github.com","api.github.com"],"allowAllUnixSockets":false,"allowLocalBinding":false}},"permissions":{"deny":` + q(rules...) + `}}`
	}
	protected := func(root string) []string {
		var paths []string
		for _, name := range []string{".agents", ".codex", ".aws", ".claude", ".git/config", ".git/hooks"} {
			paths = append(paths, filepath.Join(root, name))
		}
		return append(slices.Clone(roots), paths...)
	}
	tokenRules := []string{"Read(/" + token + ")", "Read(/" + filepath.Dir(token) + ")"}
	// An independent repository: the home and the token are denied to Bash reads and writes and to Read.
	independent := filepath.Join(user, "repo")
	encoded, err := claudeRepositorySettings(testScope(independent), temporary, home)
	if want := settings(independent, append(protected(independent), home, token, filepath.Dir(token)), nil,
		append([]string{"Read(/" + home + ")"}, tokenRules...)); err != nil || encoded != want {
		t.Fatalf("independent repository: %v\ngot  %s\nwant %s", err, encoded, want)
	}
	// A managed repository below the home: Bash may read only the repository there; a write or Read
	// deny on the home would win over the repository's own allow.
	managed := filepath.Join(home, "workers", "w1", "repo")
	encoded, err = claudeRepositorySettings(testScope(managed), temporary, home)
	if want := settings(managed, append(protected(managed), token, filepath.Dir(token)), []string{managed}, tokenRules); err != nil || encoded != want {
		t.Fatalf("managed repository: %v\ngot  %s\nwant %s", err, encoded, want)
	}
	if _, err = claudeRepositorySettings(testScope(home), temporary, home); err == nil || err.Error() != "Workspace "+home+" is the Runtime home" {
		t.Fatalf("repository at the Runtime home accepted: %v", err)
	}
	// Plain read-only has file tools only: they are denied the home and the token.
	workspace := filepath.Join(user, "project")
	encoded, err = claudeReadOnlySettings(workspace, home)
	if want := `{"permissions":{"deny":` + q(append([]string{"Read(/" + home + ")"}, tokenRules...)...) + `}}`; err != nil || encoded != want {
		t.Fatalf("read-only: %v\ngot  %s\nwant %s", err, encoded, want)
	}
	// A Read rule on a home containing the workspace would deny the workspace; --restricted confines the tools there.
	encoded, err = claudeReadOnlySettings(filepath.Join(home, "workspace"), home)
	if want := `{"permissions":{"deny":` + q(tokenRules...) + `}}`; err != nil || encoded != want {
		t.Fatalf("read-only inside the home: %v\ngot  %s\nwant %s", err, encoded, want)
	}
	if _, err = claudeReadOnlySettings(home, home); err == nil || err.Error() != "Workspace "+home+" is the Runtime home" {
		t.Fatalf("read-only workspace at the Runtime home accepted: %v", err)
	}
}

// TestHostDeniesThePassedRuntimeHomeAndKeepsItFromNativeChildren launches plain and dedicated-repository
// Codex turns and a plain Claude turn through the host: each native argv denies the ATLAS_RUNTIME_HOME the
// Runtime passed, and no native CLI inherits that variable.
func TestHostDeniesThePassedRuntimeHomeAndKeepsItFromNativeChildren(t *testing.T) {
	runtimeHome := t.TempDir()
	t.Setenv("ATLAS_RUNTIME_HOME", runtimeHome)
	resolved, err := resolvePath(runtimeHome)
	if err != nil {
		t.Fatal(err)
	}
	repository, scope := dedicatedRepository(t)
	for _, test := range []struct {
		name, backend string
		scoped        bool
		want          string
	}{
		{"codex read-only", "codex", false, `default_permissions="atlas_read_only"`},
		{"codex dedicated-repository", "codex", true, `default_permissions="atlas_repository"`},
		{"claude read-only", "claude", false, `"permissions":{"deny":["Read(/` + resolved + `)"]}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			folder := t.TempDir()
			native := fixture(t, folder, `printf '%s\n' "$@" > "$0.argv"
env > "$0.env"
printf '%s\n' '{"type":"result","result":"done"}'
`)
			args := codexArgs(native, repository)
			args[2], args[8] = folder, test.backend
			if test.scoped {
				args = scopedArgs(t, native, repository, folder, scope)
			}
			host := startHost(t, args)
			if records, code := host.finish(t); code != 0 || records[len(records)-1]["exit_code"] != 0.0 {
				stderr, _ := os.ReadFile(filepath.Join(folder, "stderr.log"))
				t.Fatalf("code=%d records=%v host=%s turn=%s", code, records, host.stderr.String(), stderr)
			}
			argv, _ := os.ReadFile(native + ".argv")
			environment, _ := os.ReadFile(native + ".env")
			if !strings.Contains(string(argv), test.want) {
				t.Fatalf("argv lacks %s: %s", test.want, argv)
			}
			if test.backend == "codex" && !strings.Contains(string(argv), quoted(resolved)+`="none"`) {
				t.Fatalf("argv does not deny the passed Runtime home %s: %s", resolved, argv)
			}
			if strings.Contains(string(environment), "ATLAS_RUNTIME_HOME=") {
				t.Fatalf("native CLI inherited ATLAS_RUNTIME_HOME: %s", environment)
			}
		})
	}
	// A relative Runtime home is refused before any native CLI runs.
	t.Setenv("ATLAS_RUNTIME_HOME", "relative/home")
	folder := t.TempDir()
	native := fixture(t, folder, "touch \"$0.executed\"\n")
	host := startHost(t, codexArgs(native, folder))
	if _, code := host.finish(t); code != 1 || !strings.Contains(host.stderr.String(), "ATLAS_RUNTIME_HOME must be an absolute path") {
		t.Fatalf("relative Runtime home: code=%d stderr=%s", code, host.stderr.String())
	}
	if _, err := os.Stat(native + ".executed"); err == nil {
		t.Fatal("native CLI executed with a relative Runtime home")
	}
}

// TestManagedPreparationDeniesThePassedRuntimeHome prepares a managed repository with a non-default
// ATLAS_RUNTIME_HOME: the Codex sandbox that runs the preparation's Git denies that home, not the default.
func TestManagedPreparationDeniesThePassedRuntimeHome(t *testing.T) {
	user := isolatedHome(t)
	runtimeHome := filepath.Join(user, "passed-runtime-home")
	if err := os.Mkdir(runtimeHome, 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ATLAS_RUNTIME_HOME", runtimeHome)
	source := filepath.Join(user, "source")
	gitIn(t, user, "init", "-q", "-b", "develop", source)
	gitIn(t, source, "commit", "--allow-empty", "-qm", "base")
	url := "https://github.com/test/fixture.git"
	var response bytes.Buffer
	if err := workspace.Run([]string{"request", filepath.Join(user, "managed"), url, "task/first"}, &response); err != nil {
		t.Fatal(err)
	}
	var request struct {
		Permissions map[string]any `json:"permissions"`
		Repository  map[string]any `json:"repository"`
	}
	if err := json.Unmarshal(response.Bytes(), &request); err != nil {
		t.Fatal(err)
	}
	folder := t.TempDir()
	// As Codex's sandbox prefix, record its argv and run Git over a local transport; otherwise act as Codex.
	native := fixture(t, folder, `if [ "$1" = sandbox ]; then
  printf '%s\n' "$@" >> "$0.sandbox.argv"
  while [ "$1" != -C ]; do shift; done
  cd "$2" || exit 1
  while [ "$1" != -- ]; do shift; done
  shift 2
  case " $* " in *" clone "*|*" fetch "*) exec git -c "url.file://`+source+`.insteadOf=`+url+`" "$@" ;; esac
  exec git "$@"
fi
printf '%s\n' '{"type":"thread.started","thread_id":"native-session"}' '{"type":"turn.completed"}'
`)
	encoded, err := json.Marshal(request.Repository)
	if err != nil {
		t.Fatal(err)
	}
	args := scopedArgs(t, native, request.Permissions["root"].(string), folder, request.Permissions)
	args[7] = string(encoded)
	host := startHost(t, args)
	if records, code := host.finish(t); code != 0 || !slices.Contains(types(records), "runtime.repository_prepared") {
		stderr, _ := os.ReadFile(filepath.Join(folder, "stderr.log"))
		t.Fatalf("code=%d records=%v host=%s turn=%s", code, records, host.stderr.String(), stderr)
	}
	argv, err := os.ReadFile(native + ".sandbox.argv")
	if err != nil {
		t.Fatalf("preparation did not run through the sandbox: %v", err)
	}
	if !strings.Contains(string(argv), quoted(runtimeHome)+`="none"`) {
		t.Fatalf("preparation does not deny the passed Runtime home %s: %s", runtimeHome, argv)
	}
	if defaultHome := filepath.Join(user, ".local", "state", "atlas-runtime"); strings.Contains(string(argv), quoted(defaultHome)) {
		t.Fatalf("preparation denies the default Runtime home %s instead: %s", defaultHome, argv)
	}
}

// listenInRuntimeHome opens a Unix socket at user/runtime/name, bound relative to user to stay below
// macOS's 104-byte socket path limit, and returns that relative path.
func listenInRuntimeHome(t *testing.T, user, name string) string {
	t.Helper()
	t.Chdir(user)
	relative := filepath.Join("runtime", name)
	listener, err := net.Listen("unix", relative)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			connection.Close()
		}
	}()
	return relative
}

// The dial mode of the socket probe works unsandboxed, so a sandboxed refusal means the sandbox.
func TestSocketProbeDialsARuntimeHomeSocket(t *testing.T) {
	probe := buildSocketProbe(t, t.TempDir())
	user := t.TempDir()
	if err := os.Mkdir(filepath.Join(user, "runtime"), 0700); err != nil {
		t.Fatal(err)
	}
	socket := listenInRuntimeHome(t, user, "runtime.sock")
	command := exec.Command(probe, "dial", socket)
	command.Dir = user
	if out, err := command.CombinedOutput(); err != nil {
		t.Fatalf("dial: %v %s", err, out)
	}
	command = exec.Command(probe, "dial", filepath.Join("runtime", "missing.sock"))
	command.Dir = user
	if err := command.Run(); err == nil {
		t.Fatal("dial of a missing socket succeeded")
	}
}

// TestRepositoryAndPlainProfilesDenyTheRuntimeHomeUnderInstalledCodexSandbox runs real commands under the
// installed Codex seatbelt with the exact dedicated-repository (independent and managed below the Runtime
// home), read-only and workspace-write profile arguments: the fake Runtime home's files, turn records and
// Unix sockets and the Code token are out of reach, while each profile's own project writes still succeed.
func TestRepositoryAndPlainProfilesDenyTheRuntimeHomeUnderInstalledCodexSandbox(t *testing.T) {
	codex, err := exec.LookPath("codex")
	if runtime.GOOS != "darwin" || err != nil {
		t.Skip("requires the installed Codex CLI on macOS")
	}
	requireNestedSeatbelt(t)
	user := installedCodexHome(t)
	home, token := runtimeHomeWithToken(t, user)
	turn := filepath.Join(home, "turns", "turn-1", "stream.jsonl")
	for path, body := range map[string]string{token: "TOKEN-SENTINEL", turn: "TURN-SENTINEL", filepath.Join(user, "project", "file"): "project"} {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	probe := buildSocketProbe(t, t.TempDir())
	independent := filepath.Join(user, "repo")
	managed := filepath.Join(home, "workers", "w1", "repo")
	for _, root := range []string{independent, managed} {
		gitIn(t, user, "init", "-q", root)
	}
	socket := listenInRuntimeHome(t, user, "runtime.sock")
	sentinel := filepath.Join(home, "sentinel")
	if err := os.WriteFile(sentinel, []byte("HOME-SENTINEL"), 0600); err != nil {
		t.Fatal(err)
	}
	// Relative to user, which these profiles leave readable, so the socket path fits the limit.
	dial := fmt.Sprintf("cd -P %q && %q dial %q", user, probe, socket)
	late := filepath.Join(home, "service.log")
	listHome := fmt.Sprintf("ls %q", home)
	denied := []string{
		fmt.Sprintf("cat %q", sentinel),
		fmt.Sprintf("cat %q", filepath.Join(home, "code.json")),
		fmt.Sprintf("cat %q", late),
		fmt.Sprintf("ls %q", filepath.Join(home, "turns")),
		fmt.Sprintf("cat %q", turn),
		fmt.Sprintf("cat %q", token),
		fmt.Sprintf("ls %q", filepath.Dir(token)),
		fmt.Sprintf("touch %q", filepath.Join(home, "planted")),
		dial,
	}
	run := func(arguments []string, profile, cwd, script string) (string, error) {
		command := exec.Command(codex, append(append([]string{"sandbox", "-P", profile, "-C", cwd}, arguments...), "--", "sh", "-c", script)...)
		command.Dir = cwd
		out, err := command.CombinedOutput()
		return string(out), err
	}
	for _, test := range []struct {
		name, profile, cwd string
		arguments          func() ([]string, error)
		allowed            []string
		listsHome          bool // a managed repository's profile leaves the home's names listable
	}{
		{"independent repository", "atlas_repository", independent, func() ([]string, error) {
			return repositoryArguments(map[string]any{"root": independent}, home)
		}, []string{"echo edit > new.txt && cat new.txt", "git add new.txt && git status --porcelain"}, false},
		{"managed repository", "atlas_repository", managed, func() ([]string, error) {
			arguments, err := repositoryArguments(map[string]any{"root": managed}, home)
			// A sensitive entry the service creates after launch stays denied.
			if err == nil {
				err = os.WriteFile(late, []byte("LOG-SENTINEL"), 0600)
			}
			return arguments, err
		}, []string{"echo edit > new.txt && cat new.txt", "git add new.txt && git status --porcelain"}, true},
		{"read-only", "atlas_read_only", filepath.Join(user, "project"), func() ([]string, error) {
			return sandboxArguments("read-only", filepath.Join(user, "project"), home)
		}, []string{"cat file"}, false},
		{"workspace-write", "atlas_workspace_write", filepath.Join(user, "project"), func() ([]string, error) {
			return sandboxArguments("workspace-write", filepath.Join(user, "project"), home)
		}, []string{"echo edit > new.txt && cat new.txt"}, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			arguments, err := test.arguments()
			if err != nil {
				t.Fatal(err)
			}
			scripts := append(slices.Clone(test.allowed), denied...)
			if !test.listsHome {
				scripts = append(scripts, listHome)
			}
			for _, script := range scripts {
				out, err := run(arguments, test.profile, test.cwd, script)
				allowed := slices.Contains(test.allowed, script)
				t.Logf("sandboxed %q: err=%v output=%q", script, err, out)
				if (err == nil) != allowed {
					t.Fatalf("sandboxed %q: allowed=%v want %v: %s", script, err == nil, allowed, out)
				}
				if !allowed && strings.Contains(out, "SENTINEL") {
					t.Fatalf("sandboxed %q leaked a sentinel: %s", script, out)
				}
			}
		})
	}
	// Positive controls: the same reads and the socket connection succeed outside the sandbox.
	for _, script := range []string{fmt.Sprintf("cat %q %q %q %q", sentinel, turn, token, late), dial} {
		command := exec.Command("sh", "-c", script)
		if out, err := command.CombinedOutput(); err != nil {
			t.Fatalf("unsandboxed control %q failed: %v %s", script, err, out)
		}
	}
}

// globRegexp approximates globset's translation of a Codex deny-read glob: * and ? cross / unless
// separator is set, [!…] is a negated class and a trailing /** matches the whole subtree.
func globRegexp(t *testing.T, pattern string, separator bool) *regexp.Regexp {
	t.Helper()
	any := "."
	if separator {
		any = "[^/]"
	}
	var expression strings.Builder
	for i := 0; i < len(pattern); i++ {
		switch c := pattern[i]; {
		case strings.HasPrefix(pattern[i:], "/**") && i+3 == len(pattern):
			expression.WriteString("/.*")
			i += 2
		case c == '*':
			expression.WriteString(any + "*")
		case c == '?':
			expression.WriteString(any)
		case c == '[':
			end := strings.IndexByte(pattern[i+2:], ']') + i + 2
			body, negated := strings.CutPrefix(pattern[i+1:end], "!")
			if expression.WriteString("["); negated {
				expression.WriteString("^")
			}
			expression.WriteString(regexp.QuoteMeta(body) + "]")
			i = end
		default:
			expression.WriteString(regexp.QuoteMeta(string(c)))
		}
	}
	matcher, err := regexp.Compile("^" + expression.String() + "$")
	if err != nil {
		t.Fatalf("glob %s: %v", pattern, err)
	}
	return matcher
}

// TestCodexSiblingWorkerGlobsExcludeOnlyTheOwnWorker checks the sibling worker globs of a managed
// repository against paths: under either reading of * they deny every other name in workers, however
// close to the own name, and its subtree, but never workers, the own worker directory or its contents.
func TestCodexSiblingWorkerGlobsExcludeOnlyTheOwnWorker(t *testing.T) {
	home := "/u/runtime"
	workers := home + "/workers"
	for _, own := range []string{"w1", "a", "alpha-2_x"} {
		globs, err := siblingWorkerGlobs(home, filepath.Join(workers, own, "repo"))
		if err != nil {
			t.Fatal(err)
		}
		for _, glob := range globs {
			if glob[1] != "none" {
				t.Fatalf("glob %s is %s, want none", glob[0], glob[1])
			}
		}
		allowed := []string{workers, workers + "/" + own, workers + "/" + own + "/repo", workers + "/" + own + "/repo/.git/HEAD", workers + "/" + own + "/admission-latch.json"}
		denied := []string{workers + "/" + own + "x", workers + "/" + own + "x/secret", workers + "/z" + own, workers + "/.hidden/secret",
			workers + "/" + strings.ToUpper(own) + "/secret", workers + "/" + own + "-2/repo/file"}
		if len(own) > 1 {
			denied = append(denied, workers+"/"+own[:len(own)-1], workers+"/"+own[:len(own)-1]+"/secret", workers+"/"+own[:1],
				workers+"/"+own[:1]+"z"+own[2:]+"/secret")
		}
		for _, separator := range []bool{false, true} {
			matches := func(path string) bool {
				return slices.ContainsFunc(globs, func(glob [2]string) bool { return globRegexp(t, glob[0], separator).MatchString(path) })
			}
			for _, path := range allowed {
				if matches(path) {
					t.Fatalf("own %s (separator %v): %s is denied by %v", own, separator, path, globs)
				}
			}
			for _, path := range denied {
				if !matches(path) {
					t.Fatalf("own %s (separator %v): sibling %s is not denied by %v", own, separator, path, globs)
				}
			}
		}
	}
	// Repositories outside workers, and workers itself, get no globs.
	for _, root := range []string{"/u/repo", home + "/other/repo", workers} {
		if globs, err := siblingWorkerGlobs(home, root); err != nil || globs != nil {
			t.Fatalf("root %s: %v %v", root, globs, err)
		}
	}
	// Glob metacharacters in the home are literal one-character classes; a backslash or a worker name
	// that is not a plain name is refused rather than denying less.
	if globs, err := siblingWorkerGlobs("/u/r[1]{a}*?", "/u/r[1]{a}*?/workers/w/repo"); err != nil || globs[0][0] != "/u/r[[]1[]][{]a[}][*][?]/workers/[!w]*" {
		t.Fatalf("home with metacharacters: %v %v", globs, err)
	}
	for _, refused := range [][2]string{{`/u/r\x`, "Runtime home /u/r\\x cannot be written as a Codex deny-read glob"},
		{"/u/runtime", "Worker directory /u/runtime/workers/w* cannot be excluded by a Codex deny-read glob"}} {
		root := refused[0] + "/workers/w1/repo"
		if refused[0] == "/u/runtime" {
			root = "/u/runtime/workers/w*/repo"
		}
		if _, err := siblingWorkerGlobs(refused[0], root); err == nil || err.Error() != refused[1] {
			t.Fatalf("home %s root %s: got %v, want %s", refused[0], root, err, refused[1])
		}
	}
}

// TestManagedRepositoryDeniesLateSiblingWorkerUnderInstalledCodexSandbox runs real commands under the
// installed Codex seatbelt with the exact managed-repository profile arguments, computed before sibling
// worker directories exist: siblings created after the arguments (as during a running turn), with names
// near the own worker's, are unreadable, while Git in the own repository still works.
func TestManagedRepositoryDeniesLateSiblingWorkerUnderInstalledCodexSandbox(t *testing.T) {
	codex, err := exec.LookPath("codex")
	if runtime.GOOS != "darwin" || err != nil {
		t.Skip("requires the installed Codex CLI on macOS")
	}
	requireNestedSeatbelt(t)
	user := installedCodexHome(t)
	home, _ := runtimeHomeWithToken(t, user)
	workers := filepath.Join(home, "workers")
	managed := filepath.Join(workers, "w1", "repo")
	gitIn(t, user, "init", "-q", managed)
	arguments, err := repositoryArguments(map[string]any{"root": managed}, home)
	if err != nil {
		t.Fatal(err)
	}
	var late []string
	for _, name := range []string{"w2", "w1x", "w", "x9", ".hidden"} {
		secret := filepath.Join(workers, name, "repo", "secret")
		if err := os.MkdirAll(filepath.Dir(secret), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(secret, []byte("WORKER-SENTINEL"), 0600); err != nil {
			t.Fatal(err)
		}
		late = append(late, secret)
	}
	run := func(script string) (string, error) {
		command := exec.Command(codex, append(append([]string{"sandbox", "-P", "atlas_repository", "-C", managed}, arguments...), "--", "sh", "-c", script)...)
		command.Dir = managed
		out, err := command.CombinedOutput()
		return string(out), err
	}
	for _, script := range []string{"echo edit > new.txt && cat new.txt", "git add new.txt && git status --porcelain",
		"git -c user.name=t -c user.email=t@t commit -qm edit && git log --oneline"} {
		if out, err := run(script); err != nil {
			t.Fatalf("own repository %q: %v %s", script, err, out)
		}
	}
	for _, secret := range late {
		for _, script := range []string{fmt.Sprintf("cat %q", secret), fmt.Sprintf("ls %q", filepath.Dir(secret))} {
			out, err := run(script)
			t.Logf("sandboxed %q: err=%v output=%q", script, err, out)
			if err == nil || strings.Contains(out, "WORKER-SENTINEL") {
				t.Fatalf("late sibling worker readable: %q: %v %s", script, err, out)
			}
		}
	}
	// Positive control: the same reads succeed outside the sandbox.
	for _, secret := range late {
		if body, err := os.ReadFile(secret); err != nil || string(body) != "WORKER-SENTINEL" {
			t.Fatalf("unsandboxed control %s: %v %q", secret, err, body)
		}
	}
}
