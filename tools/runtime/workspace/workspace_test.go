package workspace

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

func workspaceTestRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if strings.HasPrefix(name, "GIT_") {
			t.Setenv(name, "")
			if err := os.Unsetenv(name); err != nil {
				t.Fatal(err)
			}
		}
	}
	t.Setenv("HOME", root)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(root, "config"))
	t.Setenv("CODEX_HOME", filepath.Join(root, ".codex"))
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	return root
}

func workspaceTestGit(t *testing.T, root string, args ...string) string {
	t.Helper()
	command := exec.Command("git", append([]string{"-C", root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid"}, args...)...)
	out, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func workspaceTestWrite(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0600); err != nil {
		t.Fatal(err)
	}
}

func workspaceTestCall(t *testing.T, input any, args ...string) any {
	t.Helper()
	body, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := Run(args, bytes.NewReader(body), &output); err != nil {
		t.Fatalf("workspace %v: %v", args, err)
	}
	decoder := json.NewDecoder(&output)
	var result any
	if err := decoder.Decode(&result); err != nil {
		t.Fatal(err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		t.Fatalf("expected one JSON result, got %v: %v", extra, err)
	}
	return result
}

func workspaceTestRefuse(t *testing.T, input any, message string, args ...string) {
	t.Helper()
	body, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	err = Run(args, bytes.NewReader(body), &output)
	if err == nil || !strings.Contains(err.Error(), message) {
		t.Fatalf("workspace %v: wanted refusal containing %q, got %v", args, message, err)
	}
	if output.Len() != 0 {
		t.Fatalf("refused operation emitted success: %s", output.String())
	}
}

func TestWorkspaceCanonicalPathsAndMetadata(t *testing.T) {
	root := workspaceTestRoot(t)
	repo := filepath.Join(root, "repo")
	workspaceTestGit(t, root, "init", "-q", repo)
	scope := workspaceTestCall(t, nil, "scope", repo).(map[string]any)
	want := map[string]any{
		"profile": "dedicated-repository", "version": float64(1), "root": repo,
		"git_dir": filepath.Join(repo, ".git"), "network_hosts": []any{"github.com", "api.github.com"},
	}
	if !reflect.DeepEqual(scope, want) {
		t.Fatalf("scope = %#v, want %#v", scope, want)
	}
	alias := filepath.Join(root, "alias")
	if err := os.Symlink(repo, alias); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{alias, repo + "/../repo", alias + "/../repo"} {
		workspaceTestRefuse(t, nil, "canonical root", "scope", path)
	}
	if got := workspaceTestCall(t, nil, "path", alias+"/missing/../future/child"); got != filepath.Join(repo, "future", "child") {
		t.Fatalf("nonexistent suffix resolved to %v", got)
	}
	deep := filepath.Join(repo, "deep")
	if err := os.Mkdir(deep, 0700); err != nil {
		t.Fatal(err)
	}
	nestedAlias := filepath.Join(root, "nested-alias")
	if err := os.Symlink(deep, nestedAlias); err != nil {
		t.Fatal(err)
	}
	if got := workspaceTestCall(t, nil, "path", nestedAlias+"/../future"); got != filepath.Join(repo, "future") {
		t.Fatalf("resolved .. before following symlink: %v", got)
	}
	workspaceTestRefuse(t, nil, "", "path", "bad\x00path")

	for _, kind := range []string{"alternates", "symlink", "hardlink", "project config"} {
		t.Run(kind, func(t *testing.T) {
			var path string
			switch kind {
			case "alternates":
				path = filepath.Join(repo, ".git", "objects", "info", "alternates")
				workspaceTestWrite(t, path, root+"/objects\n")
			case "symlink":
				path = filepath.Join(repo, ".git", "linked")
				if err := os.Symlink(root, path); err != nil {
					t.Fatal(err)
				}
			case "hardlink":
				path = filepath.Join(root, "shared-head")
				if err := os.Link(filepath.Join(repo, ".git", "HEAD"), path); err != nil {
					t.Fatal(err)
				}
			case "project config":
				if err := os.Mkdir(filepath.Join(repo, ".codex"), 0700); err != nil {
					t.Fatal(err)
				}
				path = filepath.Join(repo, ".codex", "config.toml")
				workspaceTestWrite(t, path, "sandbox_mode = \"read-only\"\n")
			}
			t.Cleanup(func() { os.Remove(path) })
			workspaceTestRefuse(t, nil, "Dedicated", "scope", repo)
		})
	}
}

func TestWorkspaceManagedGitFreshBaseAndContinuation(t *testing.T) {
	root := workspaceTestRoot(t)
	source := filepath.Join(root, "source")
	workspaceTestGit(t, root, "init", "-q", "-b", "develop", source)
	workspaceTestWrite(t, filepath.Join(source, "state.txt"), "base\n")
	workspaceTestGit(t, source, "add", "state.txt")
	workspaceTestGit(t, source, "commit", "-qm", "base")
	url := "https://github.com/test/fixture.git"
	home := filepath.Join(root, "runtime")
	request := workspaceTestCall(t, nil, "request", home, url, "task/first").(map[string]any)
	scope := request["permissions"].(map[string]any)
	repo := scope["root"].(string)
	if err := os.MkdirAll(repo, 0700); err != nil {
		t.Fatal(err)
	}
	// Local Git transport fixture exercises real Git, not provider sandbox enforcement.
	bridge := filepath.Join(root, "local-git")
	workspaceTestWrite(t, bridge, `#!/bin/sh
set -eu
root=$1
source=$2
url=$3
shift 3
transport=false
for arg do
    case "$arg" in clone|fetch) transport=true;; esac
done
shift
if "$transport"; then
    exec git -C "$root" -c "url.file://$source.insteadOf=$url" "$@"
fi
exec git -C "$root" "$@"
`)
	if err := os.Chmod(bridge, 0700); err != nil {
		t.Fatal(err)
	}
	input := func(repository any, created bool) map[string]any {
		return map[string]any{"scope": scope, "repository": repository, "created": created,
			"command_prefix": []string{bridge, repo, source, url}}
	}
	first := workspaceTestCall(t, input(request["repository"], true), "prepare").(map[string]any)
	initial := workspaceTestGit(t, source, "rev-parse", "HEAD")
	if first["base_sha"] != initial {
		t.Fatalf("clone base = %v, want %s", first["base_sha"], initial)
	}
	workspaceTestGit(t, repo, "commit", "--allow-empty", "-qm", "prior task")
	previous := workspaceTestGit(t, repo, "rev-parse", "HEAD")
	workspaceTestGit(t, source, "commit", "--allow-empty", "-qm", "new develop")
	latest := workspaceTestGit(t, source, "rev-parse", "HEAD")
	second := map[string]any{"url": url, "branch": "task/second"}
	prepared := workspaceTestCall(t, input(second, false), "prepare").(map[string]any)
	if prepared["base_sha"] != latest || workspaceTestGit(t, repo, "rev-parse", "HEAD") != latest || workspaceTestGit(t, repo, "rev-parse", "task/first") != previous {
		t.Fatal("fresh task did not use fetched develop while preserving previous task")
	}

	workspaceTestWrite(t, filepath.Join(repo, "state.txt"), "unfinished tracked work\n")
	workspaceTestWrite(t, filepath.Join(repo, "unfinished.txt"), "unfinished untracked work\n")
	workspaceTestGit(t, source, "commit", "--allow-empty", "-qm", "unfetched develop")
	// Presence, not truthiness, selects continuation; preserve caller-owned fields.
	prepared["base_sha"] = nil
	prepared["extra"] = map[string]any{"keep": "context"}
	continued := workspaceTestCall(t, input(prepared, false), "prepare")
	if !reflect.DeepEqual(continued, prepared) {
		t.Fatalf("continuation changed repository record: %#v", continued)
	}
	if workspaceTestGit(t, repo, "rev-parse", "HEAD") != latest || workspaceTestGit(t, repo, "rev-parse", "origin/develop") != latest {
		t.Fatal("continuation fetched or reset repository")
	}
	fresh := map[string]any{"url": url, "branch": "task/third"}
	workspaceTestRefuse(t, input(fresh, false), "uncommitted work", "prepare")
	workspaceTestGit(t, repo, "checkout", "-qb", "different-task")
	workspaceTestRefuse(t, input(prepared, false), "Saved repository branch changed", "prepare")
	if workspaceTestGit(t, repo, "branch", "--show-current") != "different-task" {
		t.Fatal("continuation switched branch")
	}
	for name, want := range map[string]string{"state.txt": "unfinished tracked work\n", "unfinished.txt": "unfinished untracked work\n"} {
		got, err := os.ReadFile(filepath.Join(repo, name))
		if err != nil || string(got) != want {
			t.Fatalf("refusal changed %s: %q, %v", name, got, err)
		}
	}
	scope["unknown_policy"] = true
	workspaceTestRefuse(t, input(fresh, false), "Managed repository request changed", "prepare")
	delete(scope, "unknown_policy")
	workspaceTestWrite(t, filepath.Join(repo, "state.txt"), "base\n")
	if err := os.Remove(filepath.Join(repo, "unfinished.txt")); err != nil {
		t.Fatal(err)
	}
	workspaceTestRefuse(t, input(second, false), "Task branch already exists", "prepare")
	workspaceTestGit(t, source, "branch", "task/remote")
	workspaceTestRefuse(t, input(map[string]any{"url": url, "branch": "task/remote"}, false), "Task branch already exists remotely", "prepare")
	workspaceTestGit(t, repo, "remote", "set-url", "origin", "https://github.com/other/repo.git")
	workspaceTestRefuse(t, input(fresh, false), "origin does not match", "prepare")
	if err := os.Remove(filepath.Join(repo, ".git", "atlas-runtime-repository.json")); err != nil {
		t.Fatal(err)
	}
	workspaceTestRefuse(t, input(fresh, false), "unmanaged or mismatched", "prepare")
	if workspaceTestGit(t, repo, "rev-parse", "HEAD") != latest || workspaceTestGit(t, repo, "branch", "--show-current") != "different-task" {
		t.Fatal("refusal changed task HEAD or branch")
	}
}

func TestWorkspaceLockDescriptorOwnsRepositoryUntilReceiverCloses(t *testing.T) {
	root := workspaceTestRoot(t)
	repo := filepath.Join(root, "repositories", "new")
	sockets, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(sockets[0])
	defer syscall.Close(sockets[1])
	result := workspaceTestCall(t, nil, "lock", repo, "true", strconv.Itoa(sockets[0])).(map[string]any)
	if result["created"] != true {
		t.Fatalf("new repository not reported created: %#v", result)
	}
	payload := make([]byte, 1)
	control := make([]byte, syscall.CmsgSpace(4))
	n, controlN, flags, _, err := syscall.Recvmsg(sockets[1], payload, control, syscall.MSG_DONTWAIT)
	if err != nil || n != 1 || flags&syscall.MSG_CTRUNC != 0 {
		t.Fatalf("receiving lock descriptor: n=%d flags=%d error=%v", n, flags, err)
	}
	messages, err := syscall.ParseSocketControlMessage(control[:controlN])
	if err != nil || len(messages) != 1 {
		t.Fatalf("lock control messages: %v, %v", messages, err)
	}
	fds, err := syscall.ParseUnixRights(&messages[0])
	if err != nil || len(fds) != 1 {
		t.Fatalf("lock descriptors: %v, %v", fds, err)
	}
	received := os.NewFile(uintptr(fds[0]), "received-workspace-lock")
	defer received.Close()
	info, err := received.Stat()
	if err != nil || !info.IsDir() {
		t.Fatalf("transferred descriptor is not repository directory: %v", err)
	}
	actual, err := os.Stat(repo)
	if err != nil || !os.SameFile(info, actual) {
		t.Fatalf("transferred wrong directory: %v", err)
	}
	contender, err := os.Open(repo)
	if err != nil {
		t.Fatal(err)
	}
	defer contender.Close()
	if err := syscall.Flock(int(contender.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); !errors.Is(err, syscall.EWOULDBLOCK) {
		t.Fatalf("receiver must retain sender's lock: %v", err)
	}
	workspaceTestRefuse(t, nil, "active Runtime owner", "lock", repo, "false", strconv.Itoa(sockets[0]))
	if err := received.Close(); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(contender.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatalf("sender leaked ownership after receiver closed: %v", err)
	}
}

func TestWorkspaceContextIdentityAndUnfinishedFiles(t *testing.T) {
	root := workspaceTestRoot(t)
	repo := filepath.Join(root, "repo")
	workspaceTestGit(t, root, "init", "-q", "-b", "feature/context", repo)
	want := map[string]any{
		"cwd": repo,
		"git": map[string]any{"root": repo, "branch": "refs/heads/feature/context", "origin": []any{}},
	}
	if got := workspaceTestCall(t, nil, "context", repo); !reflect.DeepEqual(got, want) {
		t.Fatalf("unborn branch context = %#v, want %#v", got, want)
	}
	workspaceTestWrite(t, filepath.Join(repo, "tracked"), "committed\n")
	workspaceTestGit(t, repo, "add", "tracked")
	workspaceTestGit(t, repo, "commit", "-qm", "initial")
	initial := workspaceTestGit(t, repo, "rev-parse", "HEAD")
	workspaceTestGit(t, repo, "commit", "--allow-empty", "-qm", "same branch")
	if got := workspaceTestCall(t, nil, "context", repo); !reflect.DeepEqual(got, want) {
		t.Fatalf("commit on same branch changed context: %#v", got)
	}
	workspaceTestGit(t, repo, "config", "--add", "remote.origin.url", "https://example.invalid/first")
	workspaceTestGit(t, repo, "config", "--add", "remote.origin.url", "ssh://example.invalid/second")
	want["git"].(map[string]any)["origin"] = []any{"https://example.invalid/first", "ssh://example.invalid/second"}
	workspaceTestWrite(t, filepath.Join(repo, "tracked"), "staged unfinished\n")
	workspaceTestGit(t, repo, "add", "tracked")
	workspaceTestWrite(t, filepath.Join(repo, "tracked"), "unstaged unfinished\x00bytes\n")
	workspaceTestWrite(t, filepath.Join(repo, "untracked"), "untracked unfinished\x00bytes\n")
	saved := map[string][]byte{}
	for _, path := range []string{"tracked", "untracked", ".git/index", ".git/HEAD", ".git/config"} {
		content, err := os.ReadFile(filepath.Join(repo, path))
		if err != nil {
			t.Fatal(err)
		}
		saved[path] = content
	}
	deep := filepath.Join(repo, "nested", "child")
	if err := os.MkdirAll(deep, 0700); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(root, "alias")
	if err := os.Symlink(deep, alias); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{repo, deep, alias, alias + "/.."} {
		want["cwd"] = repo
		if path == deep || path == alias {
			want["cwd"] = deep
		} else if path == alias+"/.." {
			want["cwd"] = filepath.Dir(deep)
		}
		if got := workspaceTestCall(t, nil, "context", path); !reflect.DeepEqual(got, want) {
			t.Fatalf("context %q = %#v, want %#v", path, got, want)
		}
	}
	for path, content := range saved {
		got, err := os.ReadFile(filepath.Join(repo, path))
		if err != nil || !bytes.Equal(got, content) {
			t.Fatalf("context changed unfinished file %s: %v", path, err)
		}
	}
	workspaceTestGit(t, repo, "checkout", "--detach", "-q", initial)
	want["cwd"] = repo
	want["git"].(map[string]any)["branch"] = initial
	if got := workspaceTestCall(t, nil, "context", repo); !reflect.DeepEqual(got, want) {
		t.Fatalf("detached context = %#v, want %#v", got, want)
	}
	linked := filepath.Join(root, "linked")
	workspaceTestGit(t, repo, "worktree", "add", "-q", "-b", "linked", linked)
	want["cwd"] = linked
	want["git"].(map[string]any)["root"] = linked
	want["git"].(map[string]any)["branch"] = "refs/heads/linked"
	if got := workspaceTestCall(t, nil, "context", linked); !reflect.DeepEqual(got, want) {
		t.Fatalf("linked worktree context = %#v, want %#v", got, want)
	}
}

func TestWorkspaceContextOriginLines(t *testing.T) {
	root := workspaceTestRoot(t)
	workspaceTestGit(t, root, "init", "-q", "-b", "main")
	workspaceTestGit(t, root, "config", "--add", "remote.origin.url", "")
	workspaceTestGit(t, root, "config", "--add", "remote.origin.url", "one\r\ntwo\rthree\vfour\ffive\x1csix\x1dseven\x1eeight\u0085nine\u2028ten\u2029eleven\n")
	want := map[string]any{
		"cwd": root,
		"git": map[string]any{
			"root": root, "branch": "refs/heads/main",
			"origin": []any{"", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", ""},
		},
	}
	if got := workspaceTestCall(t, nil, "context", root); !reflect.DeepEqual(got, want) {
		t.Fatalf("origin lines = %#v, want %#v", got, want)
	}
}

func TestWorkspaceContextPlainAndBrokenGitDirectories(t *testing.T) {
	root := workspaceTestRoot(t)
	for _, path := range []string{root, filepath.Join(root, "missing", "child")} {
		want := map[string]any{"cwd": path, "git": nil}
		if got := workspaceTestCall(t, nil, "context", path); !reflect.DeepEqual(got, want) {
			t.Fatalf("plain context = %#v, want %#v", got, want)
		}
	}
	for _, kind := range []string{"invalid file", "missing gitdir", "empty directory", "dangling symlink", "symlink loop"} {
		t.Run(kind, func(t *testing.T) {
			repo := filepath.Join(root, kind)
			nested := filepath.Join(repo, "nested", "child")
			if err := os.MkdirAll(nested, 0700); err != nil {
				t.Fatal(err)
			}
			git := filepath.Join(repo, ".git")
			switch kind {
			case "invalid file":
				workspaceTestWrite(t, git, "not git metadata\n")
			case "missing gitdir":
				workspaceTestWrite(t, git, "gitdir: missing\n")
			case "empty directory":
				if err := os.Mkdir(git, 0700); err != nil {
					t.Fatal(err)
				}
			case "dangling symlink":
				if err := os.Symlink(filepath.Join(root, "absent"), git); err != nil {
					t.Fatal(err)
				}
			case "symlink loop":
				if err := os.Symlink(".git", git); err != nil {
					t.Fatal(err)
				}
			}
			unfinished := filepath.Join(nested, "unfinished")
			workspaceTestWrite(t, unfinished, "keep unfinished\x00bytes\n")
			for _, path := range []string{repo, nested, filepath.Join(nested, "missing")} {
				workspaceTestRefuse(t, nil, "Cannot inspect Claude working directory", "context", path)
			}
			if got, err := os.ReadFile(unfinished); err != nil || string(got) != "keep unfinished\x00bytes\n" {
				t.Fatalf("refusal changed unfinished bytes: %q, %v", got, err)
			}
		})
	}
}

func TestWorkspaceContextInspectionFailures(t *testing.T) {
	root := workspaceTestRoot(t)
	repo := filepath.Join(root, "repo")
	workspaceTestGit(t, root, "init", "-q", "-b", "main", repo)
	workspaceTestGit(t, repo, "commit", "--allow-empty", "-qm", "initial")
	realGit, err := exec.LookPath("git")
	if err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(root, "bin")
	if err := os.Mkdir(bin, 0700); err != nil {
		t.Fatal(err)
	}
	wrapper := filepath.Join(bin, "git")
	workspaceTestWrite(t, wrapper, "#!/bin/sh\nif [ \"$3:$4\" = \"$CONTEXT_FAIL\" ]; then\n  echo 'inspection unavailable' >&2\n  exit 2\nfi\ncase \"$CONTEXT_INVALID_UTF8\" in\n  stdout) printf '\\377'; exit 0;;\n  stderr) printf '\\377' >&2;;\nesac\nexec \"$CONTEXT_REAL_GIT\" \"$@\"\n")
	if err := os.Chmod(wrapper, 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CONTEXT_REAL_GIT", realGit)
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	for _, failure := range []struct {
		command string
		message string
	}{
		{"rev-parse:--show-toplevel", "Cannot inspect Claude working directory"},
		{"symbolic-ref:--quiet", "Cannot inspect Claude repository branch"},
		{"config:--get-all", "Cannot inspect Claude repository identity"},
	} {
		t.Run(failure.command, func(t *testing.T) {
			t.Setenv("CONTEXT_FAIL", failure.command)
			workspaceTestRefuse(t, nil, failure.message, "context", repo)
		})
	}
	for _, stream := range []string{"stdout", "stderr"} {
		t.Run("invalid UTF-8 "+stream, func(t *testing.T) {
			t.Setenv("CONTEXT_INVALID_UTF8", stream)
			workspaceTestRefuse(t, nil, "Cannot decode Claude Git output as UTF-8", "context", repo)
		})
	}
	workspaceTestGit(t, repo, "checkout", "--detach", "-q")
	t.Setenv("CONTEXT_FAIL", "rev-parse:HEAD")
	workspaceTestRefuse(t, nil, "Cannot inspect Claude repository identity", "context", repo)
	t.Setenv("PATH", filepath.Join(root, "no-git"))
	workspaceTestRefuse(t, nil, "git", "context", repo)
}

func TestWorkspaceContextUnreadableGitMetadata(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can read mode-000 Git metadata")
	}
	root := workspaceTestRoot(t)
	workspaceTestGit(t, root, "init", "-q", "-b", "main")
	config := filepath.Join(root, ".git", "config")
	if err := os.Chmod(config, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(config, 0600) })
	workspaceTestRefuse(t, nil, "Cannot inspect Claude working directory", "context", root)
}
