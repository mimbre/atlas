package workspace

import (
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"math/rand/v2"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"github.com/eyra/atlas/platform/atlas_runtime/host/snapshot"
)

// Facts kind `launch` (S6 package A2e, plan B4 and R4): the raw facts the Elixir spec decision
// (AtlasRuntime.Sandbox.Spec) needs for one launch. It resolves, lstats and lists; it decides
// nothing and refuses only malformed input or an unreadable stdin. Every failure to inspect one
// item is reported as that item's `error`, because whether it matters is the decision's call.
//
// The name lists are input (stdin JSON), never Go constants: this file has no copy of
// credentialPaths, homeReadNames or sensitiveHomeNames, and it does not import package host.
//
//	{"user_names": {"<list>": ["<name relative to the user home>", ...], ...},
//	 "homes": ["<Runtime home>", ...],       // besides the helper's own, which is always reported
//	 "home_names": ["<home entry>", ...],    // lstat'd in every reported home
//	 "paths": ["<path>", ...],               // resolved as resolvePath does (host/host/claude.go)
//	 "root": "<path>",                       // optional: every ancestor directory of root is listed
//	 "markers": [{"home": "<home>", "root": "<folder>"}, ...]}
//
// The resolution helpers below repeat host/host's resolvePath, pythonAbsolute, homeDirectory,
// temporaryDirectory and deniedRuntimeHome (without its unsetenv) mechanically; package host
// cannot be imported here (no cycle: host imports workspace).
func init() {
	Register("launch", launchFacts)
}

type launchInput struct {
	UserNames map[string][]string `json:"user_names"`
	Homes     []string            `json:"homes"`
	HomeNames []string            `json:"home_names"`
	Paths     []string            `json:"paths"`
	Root      string              `json:"root"`
	Markers   []struct {
		Home string `json:"home"`
		Root string `json:"root"`
	} `json:"markers"`
}

// launchEnvironment are the variables whose raw value the decision reads.
var launchEnvironment = []string{"HOME", "PATH", "ATLAS_RUNTIME_HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR",
	"TMPDIR", "TEMP", "TMP"}

func launchFacts(args []string, stdin io.Reader) (any, error) {
	if len(args) != 0 {
		return nil, errors.New("workspace facts launch takes no arguments; its input is JSON on stdin")
	}
	decoder := json.NewDecoder(stdin)
	decoder.DisallowUnknownFields()
	var input launchInput
	if err := decoder.Decode(&input); err != nil {
		return nil, errors.New("workspace facts launch input: " + err.Error())
	}
	for _, name := range input.HomeNames {
		if name == "" || strings.Contains(name, "/") || name == "." || name == ".." {
			return nil, errors.New("workspace facts launch input: a home name must be one path segment")
		}
	}

	environment := map[string]any{}
	for _, name := range launchEnvironment {
		if value, present := os.LookupEnv(name); present {
			environment[name] = value
		} else {
			environment[name] = nil
		}
	}
	facts := map[string]any{
		"env":      environment,
		"platform": runtime.GOOS,
		"uid":      os.Getuid(),
	}

	// The user home as homeDirectory reports it, and resolved.
	userHome, err := factsHomeDirectory()
	resolvedUser := ""
	if err != nil {
		facts["user"] = map[string]any{"error": err.Error()}
	} else {
		entry := map[string]any{"home": userHome}
		if resolvedUser, err = factsResolvePath(userHome); err != nil {
			entry["error"] = err.Error()
			resolvedUser = ""
		} else {
			entry["resolved"] = resolvedUser
		}
		facts["user"] = entry
	}

	// Each listed name, joined to the resolved user home and resolved.
	userNames := map[string]any{}
	for list, names := range input.UserNames {
		items := []any{}
		for _, name := range names {
			item := map[string]any{"name": name}
			if resolvedUser != "" {
				path := filepath.Join(resolvedUser, name)
				item["path"] = path
				resolvedFact(item, path)
			} else {
				item["error"] = "user home unavailable"
			}
			items = append(items, item)
		}
		userNames[list] = items
	}
	facts["user_names"] = userNames

	// The helper's own Runtime home (deniedRuntimeHome for a turn without a scope home).
	own := map[string]any{}
	ownHome, err := factsOwnRuntimeHome()
	if err != nil {
		own["error"] = err.Error()
	} else {
		own["home"] = ownHome
	}
	facts["own_home"] = own

	// Per home: code.json as written, its token file resolved, and the listed names.
	homes := map[string]any{}
	candidates := append([]string{}, input.Homes...)
	if ownHome != "" {
		candidates = append(candidates, ownHome)
	}
	for _, home := range candidates {
		if _, done := homes[home]; done {
			continue
		}
		names := map[string]any{}
		for _, name := range input.HomeNames {
			names[name] = lstatType(filepath.Join(home, name))
		}
		homes[home] = map[string]any{"code_json": codeJSONFact(home), "names": names}
	}
	facts["homes"] = homes

	// Paths named by the environment, raw and resolved: each PATH entry, CODEX_HOME and
	// CLAUDE_CONFIG_DIR.
	pathEntries := []any{}
	for _, entry := range filepath.SplitList(os.Getenv("PATH")) {
		item := map[string]any{"entry": entry}
		if filepath.IsAbs(entry) {
			resolvedFact(item, entry)
		}
		pathEntries = append(pathEntries, item)
	}
	facts["path_entries"] = pathEntries
	envPaths := map[string]any{}
	for _, name := range []string{"CODEX_HOME", "CLAUDE_CONFIG_DIR"} {
		if value := os.Getenv(name); value != "" {
			item := map[string]any{"value": value}
			resolvedFact(item, value)
			envPaths[name] = item
		}
	}
	facts["env_paths"] = envPaths

	// The input paths, resolved.
	resolved := map[string]any{}
	for _, path := range input.Paths {
		item := map[string]any{}
		resolvedFact(item, path)
		resolved[path] = item
	}
	facts["resolved"] = resolved

	// The system temp directory (Python's tempfile.gettempdir()), raw and resolved.
	temporary := map[string]any{}
	if system, err := factsTemporaryDirectory(); err != nil {
		temporary["error"] = err.Error()
	} else {
		temporary["path"] = system
		resolvedFact(temporary, system)
	}
	facts["system_temp"] = temporary

	// The listing of every ancestor directory of root, top down.
	listings := map[string]any{}
	if input.Root != "" {
		root := filepath.Clean(input.Root)
		if !filepath.IsAbs(root) {
			return nil, errors.New("workspace facts launch input: root must be an absolute path")
		}
		for directory := filepath.Dir(root); ; directory = filepath.Dir(directory) {
			listings[directory] = listingFact(directory)
			if directory == filepath.Dir(directory) {
				break
			}
		}
	}
	facts["listings"] = listings

	// A folder's rebind marker and preparation result, where they are and whether they exist.
	markers := []any{}
	for _, marker := range input.Markers {
		markers = append(markers, map[string]any{"home": marker.Home, "root": marker.Root,
			"rebind":      markerFact(snapshot.RebindMarker(marker.Home, marker.Root)),
			"preparation": markerFact(snapshot.PreparationResult(marker.Home, marker.Root))})
	}
	facts["markers"] = markers

	// The codex executable on PATH, as exec.LookPath reports it.
	codex := map[string]any{}
	if found, err := exec.LookPath("codex"); err == nil {
		codex["path"] = found
	} else if errors.Is(err, exec.ErrDot) {
		codex["path"], codex["relative"] = found, true
	} else {
		codex["absent"] = true
	}
	facts["codex"] = codex
	return facts, nil
}

func resolvedFact(item map[string]any, path string) {
	if resolved, err := factsResolvePath(path); err != nil {
		item["error"] = err.Error()
	} else {
		item["resolved"] = resolved
	}
}

func lstatType(path string) string {
	info, err := os.Lstat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return "absent"
	case err != nil:
		return "error: " + err.Error()
	case info.Mode()&fs.ModeSymlink != 0:
		return "symlink"
	case info.IsDir():
		return "dir"
	case info.Mode().IsRegular():
		return "file"
	case info.Mode()&fs.ModeSocket != 0:
		return "socket"
	}
	return "other"
}

// codeJSONFact is <home>/code.json as written: absent, its token_file string, a decode failure
// (as codeToken decodes it, host/host/codex.go) or a read error; plus the token file resolved
// when it is absolute.
func codeJSONFact(home string) any {
	data, err := os.ReadFile(filepath.Join(home, "code.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return "absent"
	} else if err != nil {
		return map[string]any{"read_error": err.Error()}
	}
	var config struct {
		TokenFile string `json:"token_file"`
	}
	if json.Unmarshal(data, &config) != nil {
		return map[string]any{"error": "decode"}
	}
	fact := map[string]any{"token_file": config.TokenFile}
	if filepath.IsAbs(config.TokenFile) {
		resolved := map[string]any{}
		resolvedFact(resolved, config.TokenFile)
		fact["token"] = resolved
	}
	return fact
}

func listingFact(directory string) any {
	children, err := os.ReadDir(directory)
	if errors.Is(err, fs.ErrNotExist) {
		return "absent"
	} else if err != nil {
		return map[string]any{"error": err.Error()}
	}
	names := []string{}
	for _, child := range children {
		names = append(names, child.Name())
	}
	return map[string]any{"entries": names}
}

func markerFact(path string) any {
	fact := map[string]any{"path": path}
	if _, err := os.Lstat(path); err == nil {
		fact["present"] = true
	} else if errors.Is(err, fs.ErrNotExist) {
		fact["present"] = false
	} else {
		fact["error"] = err.Error()
	}
	return fact
}

// factsHomeDirectory is homeDirectory: HOME when set, else the passwd entry.
func factsHomeDirectory() (string, error) {
	if home, present := os.LookupEnv("HOME"); present {
		if home = strings.TrimRight(home, "/"); home == "" {
			home = "/"
		}
		return home, nil
	}
	account, err := user.Current()
	if err != nil {
		return "", err
	}
	return account.HomeDir, nil
}

// factsOwnRuntimeHome is deniedRuntimeHome("") without the unsetenv: ATLAS_RUNTIME_HOME
// (absolute) or the default home, resolved.
func factsOwnRuntimeHome() (string, error) {
	home := os.Getenv("ATLAS_RUNTIME_HOME")
	if home == "" {
		userHome, err := factsHomeDirectory()
		if err != nil {
			return "", err
		}
		home = filepath.Join(userHome, ".local", "state", "atlas-runtime")
	} else if !filepath.IsAbs(home) {
		return "", errors.New("ATLAS_RUNTIME_HOME must be an absolute path")
	}
	return factsResolvePath(home)
}

// factsResolvePath is resolvePath: Python's non-strict Path.resolve().
func factsResolvePath(path string) (string, error) {
	absolute, err := factsAbsolute(path)
	if err != nil {
		return "", err
	}
	for prefix, rest := absolute, ""; ; {
		if resolved, err := filepath.EvalSymlinks(prefix); err == nil {
			return filepath.Join(resolved, rest), nil
		}
		parent := filepath.Dir(prefix)
		if parent == prefix {
			return absolute, nil
		}
		rest, prefix = filepath.Join(filepath.Base(prefix), rest), parent
	}
}

// factsAbsolute is os.path.abspath with the kernel's working directory.
func factsAbsolute(path string) (string, error) {
	if !filepath.IsAbs(path) {
		cwd, err := syscall.Getwd()
		if err != nil {
			return "", err
		}
		path = filepath.Join(cwd, path)
	}
	return filepath.Clean(path), nil
}

// factsTemporaryDirectory is temporaryDirectory: Python's tempfile.gettempdir(), the first
// candidate where a probe file can be created, written and removed.
func factsTemporaryDirectory() (string, error) {
	var candidates []string
	for _, name := range []string{"TMPDIR", "TEMP", "TMP"} {
		if value := os.Getenv(name); value != "" {
			candidates = append(candidates, value)
		}
	}
	candidates = append(candidates, "/tmp", "/var/tmp", "/usr/tmp")
	if cwd, err := syscall.Getwd(); err == nil {
		candidates = append(candidates, cwd)
	} else {
		candidates = append(candidates, ".")
	}
	const characters = "abcdefghijklmnopqrstuvwxyz0123456789_"
	for _, directory := range candidates {
		if directory != "." {
			var err error
			if directory, err = factsAbsolute(directory); err != nil {
				return "", err
			}
		}
		for range 100 {
			name := make([]byte, 8)
			for index := range name {
				name[index] = characters[rand.N(len(characters))]
			}
			probe := filepath.Join(directory, string(name))
			file, err := os.OpenFile(probe, os.O_RDWR|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
			if errors.Is(err, fs.ErrExist) {
				continue
			}
			if err != nil {
				break
			}
			_, writeErr := file.Write([]byte("blat"))
			closeErr := file.Close()
			if removeErr := os.Remove(probe); writeErr == nil && closeErr == nil && removeErr == nil {
				return directory, nil
			}
			break
		}
	}
	// Python's message; its repr is approximated for plain printable paths (the only kind the
	// candidates hold in practice), which is where the decision would ever report it.
	quoted := make([]string, len(candidates))
	for index, candidate := range candidates {
		quoted[index] = "'" + strings.NewReplacer(`\`, `\\`, "'", `\'`).Replace(candidate) + "'"
	}
	return "", errors.New("[Errno 2] No usable temporary directory found in [" + strings.Join(quoted, ", ") + "]")
}
