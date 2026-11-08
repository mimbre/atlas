package workspace

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
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

func workspaceTestCall(t *testing.T, args ...string) any {
	t.Helper()
	var output bytes.Buffer
	if err := Run(args, &output); err != nil {
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

func workspaceTestRefuse(t *testing.T, message string, args ...string) {
	t.Helper()
	var output bytes.Buffer
	err := Run(args, &output)
	if err == nil || !strings.Contains(err.Error(), message) {
		t.Fatalf("workspace %v: wanted refusal containing %q, got %v", args, message, err)
	}
	if output.Len() != 0 {
		t.Fatalf("refused operation emitted success: %s", output.String())
	}
}

// workspaceTestDecode round-trips value through JSON; exact numbers match Native host arguments.
func workspaceTestDecode(t *testing.T, value any, exact bool) any {
	t.Helper()
	body, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	if exact {
		decoder.UseNumber()
	}
	var result any
	if err := decoder.Decode(&result); err != nil {
		t.Fatal(err)
	}
	return result
}

// workspaceTestRefused fails unless err is a refusal containing message; empty refusal expects success.
func workspaceTestRefused(t *testing.T, err error, refusal string) {
	t.Helper()
	if refusal == "" && err != nil {
		t.Fatal(err)
	}
	if refusal != "" && (err == nil || !strings.Contains(err.Error(), refusal)) {
		t.Fatalf("wanted refusal containing %q, got %v", refusal, err)
	}
}

func workspaceTestContext(t *testing.T, path, refusal string) any {
	t.Helper()
	context, err := Context(path)
	workspaceTestRefused(t, err, refusal)
	return workspaceTestDecode(t, context, false)
}

func workspaceTestPrepare(t *testing.T, input map[string]any, refusal string) any {
	t.Helper()
	request := workspaceTestDecode(t, input, true).(map[string]any)
	var prefix []string
	for _, arg := range request["command_prefix"].([]any) {
		prefix = append(prefix, arg.(string))
	}
	prepared, err := Prepare(request["scope"].(map[string]any), request["repository"].(map[string]any), request["created"].(bool), prefix)
	workspaceTestRefused(t, err, refusal)
	return workspaceTestDecode(t, prepared, false)
}

func TestWorkspaceCanonicalPathsAndMetadata(t *testing.T) {
	root := workspaceTestRoot(t)
	repo := filepath.Join(root, "repo")
	workspaceTestGit(t, root, "init", "-q", repo)
	scope := workspaceTestCall(t, "scope", repo).(map[string]any)
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
	child := filepath.Join(repo, "child")
	if err := os.Mkdir(child, 0700); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{alias, repo + "/../repo", alias + "/../repo", child} {
		workspaceTestRefuse(t, "canonical root", "scope", path)
	}
	if got := workspaceTestCall(t, "path", alias+"/missing/../future/child"); got != filepath.Join(repo, "future", "child") {
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
	if got := workspaceTestCall(t, "path", nestedAlias+"/../future"); got != filepath.Join(repo, "future") {
		t.Fatalf("resolved .. before following symlink: %v", got)
	}
	workspaceTestRefuse(t, "", "path", "bad\x00path")

	for _, kind := range []string{"alternates", "symlink", "hardlink", "project config", "parent project config"} {
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
			case "parent project config":
				if err := os.Mkdir(filepath.Join(root, ".codex"), 0700); err != nil {
					t.Fatal(err)
				}
				path = filepath.Join(root, ".codex", "config.toml")
				workspaceTestWrite(t, path, "sandbox_mode = \"read-only\"\n")
				// The user's own Codex home config is not a project config.
				workspaceTestCall(t, "scope", repo)
				t.Setenv("CODEX_HOME", filepath.Join(root, "other-codex"))
			}
			t.Cleanup(func() { os.Remove(path) })
			workspaceTestRefuse(t, "Dedicated", "scope", repo)
		})
	}
	workspaceTestGit(t, repo, "commit", "--allow-empty", "-qm", "initial")
	worktree := filepath.Join(root, "worktree")
	workspaceTestGit(t, repo, "worktree", "add", "-q", "-b", "other", worktree)
	workspaceTestRefuse(t, "canonical root", "scope", worktree)
	workspaceTestRefuse(t, "cannot share Git metadata", "scope", repo)
}

func TestWorkspaceRequestRejectsUntrustedRepositoryAndBranch(t *testing.T) {
	home := filepath.Join(workspaceTestRoot(t), "runtime")
	url := "https://github.com/test/fixture.git"
	for _, test := range []struct{ url, branch, message string }{
		{"file:///tmp/repo", "task/new", "HTTPS github.com"},
		{"https://example.com/test/repo", "task/new", "HTTPS github.com"},
		{"https://github.com/test/../repo", "task/new", "HTTPS github.com"},
		{url, "develop", "other than develop"},
		{url, "../branch", "other than develop"},
		{url, "--force", "other than develop"},
	} {
		workspaceTestRefuse(t, test.message, "request", home, test.url, test.branch)
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
	request := workspaceTestCall(t, "request", home, url, "task/first").(map[string]any)
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
	initial := workspaceTestGit(t, source, "rev-parse", "HEAD")
	workspaceTestPrepare(t, input(request["repository"], true), "no commit resolved by Code")
	workspaceTestPrepare(t, input(map[string]any{"url": url, "branch": "task/first", "resolved_commit": "abc"}, true), "no commit resolved by Code")
	if entries, err := os.ReadDir(repo); err != nil || len(entries) != 0 {
		t.Fatalf("refusal without a resolved commit cloned: %v %v", entries, err)
	}
	first := workspaceTestPrepare(t, input(map[string]any{"url": url, "branch": "task/first", "resolved_commit": initial}, true), "").(map[string]any)
	if _, present := first["resolved_commit"]; present || first["base_sha"] != initial {
		t.Fatalf("clone base = %v, want %s", first, initial)
	}
	workspaceTestGit(t, repo, "commit", "--allow-empty", "-qm", "prior task")
	previous := workspaceTestGit(t, repo, "rev-parse", "HEAD")
	workspaceTestGit(t, source, "commit", "--allow-empty", "-qm", "new develop")
	latest := workspaceTestGit(t, source, "rev-parse", "HEAD")
	// Code resolved latest; develop moves again before preparation fetches.
	workspaceTestGit(t, source, "commit", "--allow-empty", "-qm", "after resolution")
	moved := workspaceTestGit(t, source, "rev-parse", "HEAD")
	second := map[string]any{"url": url, "branch": "task/second", "resolved_commit": latest}
	prepared := workspaceTestPrepare(t, input(second, false), "").(map[string]any)
	if prepared["base_sha"] != latest || workspaceTestGit(t, repo, "rev-parse", "HEAD") != latest || workspaceTestGit(t, repo, "rev-parse", "task/first") != previous ||
		workspaceTestGit(t, repo, "rev-parse", "origin/develop") != moved {
		t.Fatal("fresh task did not use the resolved commit while preserving previous task")
	}
	workspaceTestPrepare(t, input(map[string]any{"url": url, "branch": "task/missing", "resolved_commit": strings.Repeat("0", 40)}, false), "not in the fetched repository")
	if workspaceTestGit(t, repo, "branch", "--show-current") != "task/second" {
		t.Fatal("missing resolved commit changed the checked-out branch")
	}

	workspaceTestWrite(t, filepath.Join(repo, "state.txt"), "unfinished tracked work\n")
	workspaceTestWrite(t, filepath.Join(repo, "unfinished.txt"), "unfinished untracked work\n")
	workspaceTestGit(t, source, "commit", "--allow-empty", "-qm", "unfetched develop")
	// Presence, not truthiness, selects continuation; preserve caller-owned fields.
	prepared["base_sha"] = nil
	prepared["extra"] = map[string]any{"keep": "context"}
	continued := workspaceTestPrepare(t, input(prepared, false), "")
	if !reflect.DeepEqual(continued, prepared) {
		t.Fatalf("continuation changed repository record: %#v", continued)
	}
	if workspaceTestGit(t, repo, "rev-parse", "HEAD") != latest || workspaceTestGit(t, repo, "rev-parse", "origin/develop") != moved {
		t.Fatal("continuation fetched or reset repository")
	}
	fresh := map[string]any{"url": url, "branch": "task/third", "resolved_commit": latest}
	workspaceTestPrepare(t, input(fresh, false), "uncommitted work")
	workspaceTestGit(t, repo, "checkout", "-qb", "different-task")
	workspaceTestPrepare(t, input(prepared, false), "Saved repository branch changed")
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
	workspaceTestPrepare(t, input(fresh, false), "Managed repository request changed")
	delete(scope, "unknown_policy")
	// Untracked and tracked changes each refuse a fresh task on their own.
	workspaceTestWrite(t, filepath.Join(repo, "state.txt"), "base\n")
	workspaceTestPrepare(t, input(fresh, false), "uncommitted work")
	if err := os.Remove(filepath.Join(repo, "unfinished.txt")); err != nil {
		t.Fatal(err)
	}
	workspaceTestWrite(t, filepath.Join(repo, "state.txt"), "unfinished tracked work\n")
	workspaceTestPrepare(t, input(fresh, false), "uncommitted work")
	workspaceTestWrite(t, filepath.Join(repo, "state.txt"), "base\n")
	workspaceTestPrepare(t, input(second, false), "Task branch already exists")
	workspaceTestGit(t, source, "branch", "task/remote")
	workspaceTestPrepare(t, input(map[string]any{"url": url, "branch": "task/remote", "resolved_commit": latest}, false), "Task branch already exists remotely")
	workspaceTestGit(t, repo, "remote", "set-url", "origin", "https://github.com/other/repo.git")
	workspaceTestPrepare(t, input(fresh, false), "origin does not match")
	if err := os.Remove(filepath.Join(repo, ".git", "atlas-runtime-repository.json")); err != nil {
		t.Fatal(err)
	}
	workspaceTestPrepare(t, input(fresh, false), "unmanaged or mismatched")
	if workspaceTestGit(t, repo, "rev-parse", "HEAD") != latest || workspaceTestGit(t, repo, "branch", "--show-current") != "different-task" {
		t.Fatal("refusal changed task HEAD or branch")
	}
}

func TestWorkspaceLockOwnsRepositoryUntilClosed(t *testing.T) {
	root := workspaceTestRoot(t)
	repo := filepath.Join(root, "repositories", "new")
	lock, created, err := Lock(repo, true)
	if err != nil || !created {
		t.Fatalf("new repository not locked and reported created: %v %v", created, err)
	}
	defer lock.Close()
	info, err := lock.Stat()
	if err != nil || !info.IsDir() {
		t.Fatalf("lock is not the repository directory: %v", err)
	}
	actual, err := os.Stat(repo)
	if err != nil || !os.SameFile(info, actual) {
		t.Fatalf("locked wrong directory: %v", err)
	}
	contender, err := os.Open(repo)
	if err != nil {
		t.Fatal(err)
	}
	defer contender.Close()
	if err := syscall.Flock(int(contender.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); !errors.Is(err, syscall.EWOULDBLOCK) {
		t.Fatalf("owner must hold the lock: %v", err)
	}
	if _, _, err := Lock(repo, false); err == nil || !strings.Contains(err.Error(), "active Runtime owner") {
		t.Fatalf("second owner admitted: %v", err)
	}
	if err := lock.Close(); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(contender.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatalf("closing the owner leaked ownership: %v", err)
	}
	if _, _, err := Lock(repo, false); err == nil || !strings.Contains(err.Error(), "active Runtime owner") {
		t.Fatalf("an existing flock owner must block acquisition: %v", err)
	}
	contender.Close()
	again, created, err := Lock(repo, false)
	if err != nil || created {
		t.Fatalf("released repository not reacquired as existing: %v %v", created, err)
	}
	again.Close()
}

// workspaceTestMaterialize records dest under home as Materialize would, for a snapshot of
// one empty repository "repo", and returns the snapshot ID.
func workspaceTestMaterialize(t *testing.T, home, dest string) string {
	t.Helper()
	manifest := `{"entries":[],"repositories":[{"commit":"` + strings.Repeat("a", 40) + `","path":"repo","repository":"r"}]}`
	sum := sha256.Sum256([]byte(manifest))
	id := "sha256:" + hex.EncodeToString(sum[:])
	baseline := filepath.Join(home, "snapshots", hex.EncodeToString(sum[:]))
	for _, directory := range []string{filepath.Join(baseline, "tree"), filepath.Join(home, "materializations"), filepath.Join(dest, "repo")} {
		if err := os.MkdirAll(directory, 0700); err != nil {
			t.Fatal(err)
		}
	}
	workspaceTestWrite(t, filepath.Join(baseline, "manifest.json"), manifest)
	workspaceTestWrite(t, filepath.Join(baseline, "complete"), id+"\n")
	workspaceTestWrite(t, filepath.Join(home, "materializations", fmt.Sprintf("%x.json", sha256.Sum256([]byte(dest)))),
		fmt.Sprintf(`{"destination":%q,"snapshot_id":%q,"materialized_at":"2026-11-08T00:00:00Z"}`, dest, id))
	return id
}

func TestWorkspaceFolderScopeVerifiesMaterializationWithoutGit(t *testing.T) {
	root := workspaceTestRoot(t)
	home := filepath.Join(root, "runtime")
	dest := filepath.Join(root, "work")
	id := workspaceTestMaterialize(t, home, dest)
	// No Git may run: an empty PATH makes any attempt fail.
	t.Setenv("PATH", "")
	baseline := filepath.Join(home, "snapshots", strings.TrimPrefix(id, "sha256:"))
	record := filepath.Join(home, "materializations", fmt.Sprintf("%x.json", sha256.Sum256([]byte(dest))))
	want := map[string]any{"profile": "materialized-folder", "version": 1.0, "root": dest, "snapshot_id": id,
		"repositories": []any{"repo"}, "home": home, "record": record, "baseline": baseline}
	if got := workspaceTestCall(t, "folder-scope", dest, home); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	exact, err := FolderScope(dest, home)
	if err != nil || !JSONEqual(exact, workspaceTestDecode(t, want, true)) {
		t.Fatalf("Native host comparison differs: %v %v", exact, err)
	}

	workspaceTestRefuse(t, "requires destination and Runtime home", "folder-scope", dest)
	workspaceTestRefuse(t, "must be absolute", "folder-scope", "work", home)
	other := filepath.Join(root, "other")
	if err := os.Mkdir(other, 0700); err != nil {
		t.Fatal(err)
	}
	workspaceTestRefuse(t, "no materialization record", "folder-scope", other, home)
	if err := os.Symlink(root, filepath.Join(root, "alias")); err != nil {
		t.Fatal(err)
	}
	workspaceTestRefuse(t, "canonical path", "folder-scope", filepath.Join(root, "alias", "work"), home)

	// A Git work tree here or above would make the trusted native CLI run Git.
	outer := filepath.Join(root, "outer")
	nested := filepath.Join(outer, "deep", "work")
	workspaceTestMaterialize(t, home, nested)
	if err := os.Mkdir(filepath.Join(outer, ".git"), 0700); err != nil {
		t.Fatal(err)
	}
	workspaceTestRefuse(t, "inside a Git work tree", "folder-scope", nested, home)
	workspaceTestWrite(t, filepath.Join(dest, ".git"), "gitdir: /elsewhere\n")
	workspaceTestRefuse(t, "inside a Git work tree", "folder-scope", dest, home)
	if err := os.Remove(filepath.Join(dest, ".git")); err != nil {
		t.Fatal(err)
	}

	if err := os.Mkdir(filepath.Join(dest, ".codex"), 0700); err != nil {
		t.Fatal(err)
	}
	workspaceTestWrite(t, filepath.Join(dest, ".codex", "config.toml"), "")
	workspaceTestRefuse(t, "Materialized folder cannot load project or system Codex config", "folder-scope", dest, home)
	if err := os.RemoveAll(filepath.Join(dest, ".codex")); err != nil {
		t.Fatal(err)
	}

	// The record binds the folder to its snapshot; another destination or snapshot is refused.
	workspaceTestWrite(t, record, fmt.Sprintf(`{"destination":"/elsewhere","snapshot_id":%q}`, id))
	workspaceTestRefuse(t, "invalid materialization record", "folder-scope", dest, home)
	workspaceTestWrite(t, record, fmt.Sprintf(`{"destination":%q,"snapshot_id":"sha256:%s"}`, dest, strings.Repeat("0", 64)))
	workspaceTestRefuse(t, "missing or incomplete", "folder-scope", dest, home)
}

func TestWorkspaceContextIdentityAndUnfinishedFiles(t *testing.T) {
	root := workspaceTestRoot(t)
	repo := filepath.Join(root, "repo")
	workspaceTestGit(t, root, "init", "-q", "-b", "feature/context", repo)
	want := map[string]any{
		"cwd": repo,
		"git": map[string]any{"root": repo, "branch": "refs/heads/feature/context", "origin": []any{}},
	}
	if got := workspaceTestContext(t, repo, ""); !reflect.DeepEqual(got, want) {
		t.Fatalf("unborn branch context = %#v, want %#v", got, want)
	}
	workspaceTestWrite(t, filepath.Join(repo, "tracked"), "committed\n")
	workspaceTestGit(t, repo, "add", "tracked")
	workspaceTestGit(t, repo, "commit", "-qm", "initial")
	initial := workspaceTestGit(t, repo, "rev-parse", "HEAD")
	workspaceTestGit(t, repo, "commit", "--allow-empty", "-qm", "same branch")
	if got := workspaceTestContext(t, repo, ""); !reflect.DeepEqual(got, want) {
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
		if got := workspaceTestContext(t, path, ""); !reflect.DeepEqual(got, want) {
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
	if got := workspaceTestContext(t, repo, ""); !reflect.DeepEqual(got, want) {
		t.Fatalf("detached context = %#v, want %#v", got, want)
	}
	linked := filepath.Join(root, "linked")
	workspaceTestGit(t, repo, "worktree", "add", "-q", "-b", "linked", linked)
	want["cwd"] = linked
	want["git"].(map[string]any)["root"] = linked
	want["git"].(map[string]any)["branch"] = "refs/heads/linked"
	if got := workspaceTestContext(t, linked, ""); !reflect.DeepEqual(got, want) {
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
	if got := workspaceTestContext(t, root, ""); !reflect.DeepEqual(got, want) {
		t.Fatalf("origin lines = %#v, want %#v", got, want)
	}
}

func TestWorkspaceContextPlainAndBrokenGitDirectories(t *testing.T) {
	root := workspaceTestRoot(t)
	for _, path := range []string{root, filepath.Join(root, "missing", "child")} {
		want := map[string]any{"cwd": path, "git": nil}
		if got := workspaceTestContext(t, path, ""); !reflect.DeepEqual(got, want) {
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
				workspaceTestContext(t, path, "Cannot inspect Claude working directory")
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
			workspaceTestContext(t, repo, failure.message)
		})
	}
	for _, stream := range []string{"stdout", "stderr"} {
		t.Run("invalid UTF-8 "+stream, func(t *testing.T) {
			t.Setenv("CONTEXT_INVALID_UTF8", stream)
			workspaceTestContext(t, repo, "Cannot decode Claude Git output as UTF-8")
		})
	}
	workspaceTestGit(t, repo, "checkout", "--detach", "-q")
	t.Setenv("CONTEXT_FAIL", "rev-parse:HEAD")
	workspaceTestContext(t, repo, "Cannot inspect Claude repository identity")
	t.Setenv("PATH", filepath.Join(root, "no-git"))
	workspaceTestContext(t, repo, "git")
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
	workspaceTestContext(t, root, "Cannot inspect Claude working directory")
}
