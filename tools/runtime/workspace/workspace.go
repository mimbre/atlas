package workspace

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"syscall"
)

func Run(args []string, input io.Reader, output io.Writer) error {
	if len(args) == 0 {
		return errors.New("use workspace path|scope|dedicated-scope|request|lock|prepare")
	}
	var result any
	var err error
	switch args[0] {
	case "path", "scope", "dedicated-scope":
		if len(args) != 2 {
			return fmt.Errorf("workspace %s requires one path", args[0])
		}
		switch args[0] {
		case "path":
			result, err = workspaceResolve(args[1])
		case "scope":
			result, err = workspaceScope(args[1])
		case "dedicated-scope":
			result = workspaceDedicatedScope(workspacePath(args[1]))
		}
	case "request":
		if len(args) != 4 {
			return errors.New("workspace request requires home, URL and branch")
		}
		result, err = workspaceRequest(args[1], args[2], args[3])
	case "lock":
		if len(args) != 4 || (args[2] != "true" && args[2] != "false") {
			return errors.New("workspace lock requires path, true|false and socket FD")
		}
		fd, parseErr := strconv.Atoi(args[3])
		if parseErr != nil || fd < 0 {
			return errors.New("Invalid workspace lock socket FD")
		}
		result, err = workspaceLock(args[1], args[2] == "true", fd)
	case "prepare":
		if len(args) != 1 {
			return errors.New("workspace prepare takes JSON on stdin")
		}
		var request struct {
			Scope         map[string]any `json:"scope"`
			Repository    map[string]any `json:"repository"`
			Created       *bool          `json:"created"`
			CommandPrefix []string       `json:"command_prefix"`
		}
		decoder := json.NewDecoder(input)
		decoder.UseNumber()
		if err = decoder.Decode(&request); err != nil {
			return err
		}
		var extra any
		if err = decoder.Decode(&extra); err != io.EOF {
			if err == nil {
				return errors.New("workspace prepare requires exactly one JSON value")
			}
			return err
		}
		if request.Scope == nil || request.Repository == nil || request.Created == nil || len(request.CommandPrefix) == 0 || request.CommandPrefix[0] == "" {
			return errors.New("workspace prepare requires scope, repository, created and an explicit command_prefix")
		}
		result, err = workspacePrepare(request.Scope, request.Repository, *request.Created, request.CommandPrefix)
	default:
		return fmt.Errorf("unknown workspace operation: %s", args[0])
	}
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}

// Pathlib collapses dots and separators but retains '..' until resolution.
func workspacePath(path string) string {
	prefix := ""
	if strings.HasPrefix(path, "/") {
		prefix = "/"
		if strings.HasPrefix(path, "//") && !strings.HasPrefix(path, "///") {
			prefix = "//"
		}
	}
	parts := strings.Split(path, "/")
	kept := parts[:0]
	for _, part := range parts {
		if part != "" && part != "." {
			kept = append(kept, part)
		}
	}
	result := prefix + strings.Join(kept, "/")
	if result == "" {
		return "."
	}
	return result
}

func workspaceAbsolute(path string) (string, error) {
	path = workspacePath(path)
	if filepath.IsAbs(path) {
		return path, nil
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	cwd, err = filepath.EvalSymlinks(cwd)
	if err != nil {
		return "", err
	}
	return workspacePath(cwd + "/" + path), nil
}

func workspaceResolve(path string) (string, error) {
	if strings.ContainsRune(path, 0) {
		return "", errors.New("embedded null byte in path")
	}
	absolute, err := workspaceAbsolute(path)
	if err != nil {
		return "", err
	}
	return workspaceResolveParts("/", strings.Split(absolute, "/"), make(map[string]bool))
}

func workspaceResolveParts(root string, parts []string, active map[string]bool) (string, error) {
	for _, part := range parts {
		if part == "" || part == "." {
			continue
		}
		if part == ".." {
			root = filepath.Dir(root)
			continue
		}
		path := filepath.Join(root, part)
		info, err := os.Lstat(path)
		if err != nil {
			if errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ENOTDIR) || errors.Is(err, syscall.EACCES) {
				root = path
				continue
			}
			return "", err
		}
		if info.Mode()&os.ModeSymlink == 0 {
			root = path
			continue
		}
		if active[path] {
			return "", fmt.Errorf("Symlink loop from %s", path)
		}
		target, err := os.Readlink(path)
		if err != nil {
			return "", err
		}
		active[path] = true
		if filepath.IsAbs(target) {
			root = "/"
		}
		root, err = workspaceResolveParts(root, strings.Split(target, "/"), active)
		delete(active, path)
		if err != nil {
			return "", err
		}
	}
	return root, nil
}

func workspaceDedicatedScope(root string) map[string]any {
	return map[string]any{
		"profile": "dedicated-repository", "version": json.Number("1"), "root": root,
		"git_dir": workspacePath(root + "/.git"), "network_hosts": []any{"github.com", "api.github.com"},
	}
}

func workspaceRun(argv []string, env []string) (string, string, int, error) {
	command := exec.Command(argv[0], argv[1:]...)
	command.Env = env
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	err := command.Run()
	code := 0
	if err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			return "", "", 0, err
		}
		code = exit.ExitCode()
	}
	// subprocess text mode translates all universal newlines.
	text := func(value string) string {
		return strings.ReplaceAll(strings.ReplaceAll(value, "\r\n", "\n"), "\r", "\n")
	}
	return text(stdout.String()), text(stderr.String()), code, nil
}

func workspaceRequest(home, url, branch string) (map[string]any, error) {
	match := regexp.MustCompile(`^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9_.-]+)$`).FindStringSubmatch(url)
	if match == nil {
		return nil, errors.New("Repository must be an HTTPS github.com owner/repository URL")
	}
	owner, name := strings.ToLower(match[1]), strings.TrimSuffix(strings.ToLower(match[2]), ".git")
	if name == "" || name == "." || name == ".." {
		return nil, errors.New("Invalid repository name")
	}
	stdout, _, code, err := workspaceRun([]string{"git", "check-ref-format", "--branch", branch}, nil)
	if err != nil {
		return nil, err
	}
	if code != 0 || strings.TrimSpace(stdout) != branch || branch == "develop" {
		return nil, errors.New("Task branch must be a new explicit Git branch other than develop")
	}
	absolute, err := workspaceAbsolute(home)
	if err != nil {
		return nil, err
	}
	root := workspacePath(absolute + "/repositories/" + owner + "/" + name)
	resolved, err := workspaceResolve(root)
	if err != nil {
		return nil, err
	}
	if root != resolved {
		return nil, errors.New("Managed repository path must not contain symlinks")
	}
	return map[string]any{
		"permissions": workspaceDedicatedScope(root),
		"repository":  map[string]any{"url": "https://github.com/" + owner + "/" + name + ".git", "branch": branch},
	}, nil
}

func workspaceExists(path string) (bool, error) {
	_, err := os.Stat(path)
	if errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ENOTDIR) ||
		errors.Is(err, syscall.ELOOP) || errors.Is(err, syscall.EBADF) {
		return false, nil
	}
	return err == nil, err
}

func workspaceScope(workspace string) (map[string]any, error) {
	root, err := workspaceAbsolute(workspace)
	if err != nil {
		return nil, err
	}
	resolved, err := workspaceResolve(root)
	if err != nil {
		return nil, err
	}
	gitDir := workspacePath(root + "/.git")
	info, statErr := os.Lstat(gitDir)
	if root != resolved || statErr != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("Dedicated repository requires a canonical root with its own .git directory")
	}
	inherited := os.Environ()
	env := make([]string, 0, len(inherited))
	for _, entry := range inherited {
		if !strings.HasPrefix(entry, "GIT_") {
			env = append(env, entry)
		}
	}
	stdout, stderr, code, err := workspaceRun([]string{"git", "-C", root, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"}, env)
	if err != nil {
		return nil, err
	}
	if code != 0 {
		return nil, fmt.Errorf("Git repository inspection failed: %s", strings.TrimSpace(stderr))
	}
	if !reflect.DeepEqual(strings.Split(strings.TrimSuffix(stdout, "\n"), "\n"), []string{root, gitDir, gitDir}) {
		return nil, errors.New("Dedicated repository cannot use worktree or external Git metadata")
	}
	for _, path := range []string{"commondir", "objects/info/alternates", "objects/info/http-alternates", "worktrees"} {
		exists, err := workspaceExists(filepath.Join(gitDir, path))
		if err != nil {
			return nil, err
		}
		if exists {
			return nil, errors.New("Dedicated repository cannot share Git metadata or object stores")
		}
	}
	err = filepath.WalkDir(gitDir, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			// Like os.walk without onerror, skip directories that cannot be read.
			return filepath.SkipDir
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return errors.New("Dedicated Git metadata cannot contain symlinks or shared hardlinks")
		}
		if !entry.IsDir() {
			info, err := entry.Info()
			if err != nil {
				return err
			}
			if info.Mode().IsRegular() && info.Sys().(*syscall.Stat_t).Nlink > 1 {
				return errors.New("Dedicated Git metadata cannot contain symlinks or shared hardlinks")
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	codexHome, present := os.LookupEnv("CODEX_HOME")
	if !present {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		codexHome = filepath.Join(home, ".codex")
	}
	ignored, err := workspaceResolve(codexHome)
	if err != nil {
		return nil, err
	}
	ignored = filepath.Join(ignored, "config.toml")
	for directory := root; ; directory = filepath.Dir(directory) {
		config := filepath.Join(directory, ".codex/config.toml")
		if config != ignored {
			exists, err := workspaceExists(config)
			if err != nil {
				return nil, err
			}
			if exists {
				return nil, errors.New("Dedicated repository cannot load project or system Codex config")
			}
		}
		if directory == "/" {
			break
		}
	}
	if config := "/etc/codex/config.toml"; config != ignored {
		exists, err := workspaceExists(config)
		if err != nil {
			return nil, err
		}
		if exists {
			return nil, errors.New("Dedicated repository cannot load project or system Codex config")
		}
	}
	return workspaceDedicatedScope(root), nil
}

func workspaceLock(path string, create bool, socketFD int) (map[string]any, error) {
	root := workspacePath(path)
	canonical := func() error {
		resolved, err := workspaceResolve(root)
		if err != nil {
			return err
		}
		if root != resolved {
			return errors.New("Repository path changed to a symlink")
		}
		return nil
	}
	if err := canonical(); err != nil {
		return nil, err
	}
	created := false
	if create {
		if err := os.MkdirAll(filepath.Dir(root), 0777); err != nil {
			return nil, err
		}
		if err := os.Mkdir(root, 0777); err == nil {
			created = true
		} else if !os.IsExist(err) {
			return nil, err
		}
	}
	if err := canonical(); err != nil {
		return nil, err
	}
	lock, err := os.Open(root)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, errors.New("Repository already has an active Runtime owner")
		}
		return nil, err
	}
	// Do not unlock: SCM_RIGHTS shares this open-file description with the receiver.
	if err = syscall.Sendmsg(socketFD, []byte{0}, syscall.UnixRights(int(lock.Fd())), nil, 0); err != nil {
		return nil, err
	}
	return map[string]any{"created": created}, nil
}

func workspaceJSONEqual(left, right any) bool {
	switch value := left.(type) {
	case map[string]any:
		other, ok := right.(map[string]any)
		if !ok || len(value) != len(other) {
			return false
		}
		for key, item := range value {
			otherItem, present := other[key]
			if !present || !workspaceJSONEqual(item, otherItem) {
				return false
			}
		}
		return true
	case []any:
		other, ok := right.([]any)
		if !ok || len(value) != len(other) {
			return false
		}
		for index, item := range value {
			if !workspaceJSONEqual(item, other[index]) {
				return false
			}
		}
		return true
	case json.Number:
		other, ok := right.(json.Number)
		if !ok {
			// Python considers booleans equal to numeric zero or one.
			if boolean, isBool := right.(bool); isBool {
				other = "0"
				if boolean {
					other = "1"
				}
			} else {
				return false
			}
		}
		// Expected numeric fields are integer versions; JSON decimals use Python's float semantics.
		expected, err := value.Int64()
		if err != nil {
			return false
		}
		if strings.ContainsAny(string(other), ".eE") {
			actual, err := other.Float64()
			return err == nil && actual == float64(expected)
		}
		actual, err := other.Int64()
		return err == nil && actual == expected
	default:
		return reflect.DeepEqual(left, right)
	}
}

func workspacePrepare(scope, repository map[string]any, created bool, prefix []string) (map[string]any, error) {
	root, rootOK := scope["root"].(string)
	url, urlOK := repository["url"].(string)
	branch, branchOK := repository["branch"].(string)
	if !rootOK || !urlOK || !branchOK {
		return nil, errors.New("Managed repository request changed")
	}
	home := root
	for range 3 {
		parent := filepath.Dir(home)
		if parent == home {
			return nil, errors.New("Managed repository request changed")
		}
		home = parent
	}
	expected, err := workspaceRequest(home, url, branch)
	if err != nil {
		return nil, err
	}
	if !workspaceJSONEqual(expected, map[string]any{"permissions": scope, "repository": map[string]any{"url": url, "branch": branch}}) {
		return nil, errors.New("Managed repository request changed")
	}
	marker := filepath.Join(root, ".git/atlas-runtime-repository.json")
	identity := map[string]any{"version": json.Number("1"), "url": url}
	env := os.Environ()
	for index, entry := range env {
		if strings.HasPrefix(entry, "GIT_TERMINAL_PROMPT=") {
			env = append(env[:index], env[index+1:]...)
			break
		}
	}
	env = append(env, "GIT_TERMINAL_PROMPT=0")
	git := func(check bool, args ...string) (string, int, error) {
		argv := make([]string, 0, len(prefix)+13+len(args))
		argv = append(argv, prefix...)
		argv = append(argv, "git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "maintenance.auto=false", "-c", "gc.auto=0", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential")
		argv = append(argv, args...)
		stdout, stderr, code, err := workspaceRun(argv, env)
		if err == nil && check && code != 0 {
			err = fmt.Errorf("Git preparation failed: %s", strings.TrimSpace(stderr))
		}
		return stdout, code, err
	}
	if created {
		if _, _, err = git(true, "clone", "--origin", "origin", "--branch", "develop", url, "."); err != nil {
			return nil, err
		}
		if _, err = workspaceScope(root); err != nil {
			return nil, err
		}
		data, err := json.Marshal(identity)
		if err != nil {
			return nil, err
		}
		if err = os.WriteFile(marker, append(data, '\n'), 0666); err != nil {
			return nil, err
		}
	} else {
		info, err := os.Stat(marker)
		if err != nil || !info.Mode().IsRegular() {
			return nil, errors.New("Refusing an unmanaged or mismatched repository")
		}
		data, err := os.ReadFile(marker)
		if err != nil {
			return nil, err
		}
		var saved any
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.UseNumber()
		if err = decoder.Decode(&saved); err != nil {
			return nil, err
		}
		var extra any
		if err = decoder.Decode(&extra); err != io.EOF {
			if err == nil {
				err = errors.New("Invalid repository marker JSON")
			}
			return nil, err
		}
		if !workspaceJSONEqual(identity, saved) {
			return nil, errors.New("Refusing an unmanaged or mismatched repository")
		}
		if _, err = workspaceScope(root); err != nil {
			return nil, err
		}
		origin, _, err := git(true, "remote", "get-url", "origin")
		if err != nil {
			return nil, err
		}
		if strings.TrimSpace(origin) != url {
			return nil, errors.New("Managed repository origin does not match the request")
		}
	}
	if _, present := repository["base_sha"]; present {
		current, _, err := git(true, "branch", "--show-current")
		if err != nil {
			return nil, err
		}
		if strings.TrimSpace(current) != branch {
			return nil, errors.New("Saved repository branch changed; continuation will not switch it")
		}
		return repository, nil
	}
	status, _, err := git(true, "status", "--porcelain", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	if status != "" {
		return nil, errors.New("Managed repository has uncommitted work; nothing was reset or stashed")
	}
	_, code, err := git(false, "show-ref", "--verify", "--quiet", "refs/heads/"+branch)
	if err != nil {
		return nil, err
	}
	if code != 1 {
		return nil, errors.New("Task branch already exists or cannot be checked")
	}
	if _, _, err = git(true, "fetch", "--no-tags", "origin", "+refs/heads/*:refs/remotes/origin/*"); err != nil {
		return nil, err
	}
	_, code, err = git(false, "show-ref", "--verify", "--quiet", "refs/remotes/origin/"+branch)
	if err != nil {
		return nil, err
	}
	if code != 1 {
		return nil, errors.New("Task branch already exists remotely or cannot be checked")
	}
	base, _, err := git(true, "rev-parse", "--verify", "refs/remotes/origin/develop^{commit}")
	if err != nil {
		return nil, err
	}
	base = strings.TrimSpace(base)
	if _, _, err = git(true, "checkout", "--no-overwrite-ignore", "--no-track", "-b", branch, base); err != nil {
		return nil, err
	}
	repository["base_sha"] = base
	return repository, nil
}
