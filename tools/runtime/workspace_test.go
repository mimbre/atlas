package main

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
	if err := workspaceCommand(args, bytes.NewReader(body), &output); err != nil {
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
	err = workspaceCommand(args, bytes.NewReader(body), &output)
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
