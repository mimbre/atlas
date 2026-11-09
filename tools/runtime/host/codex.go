package host

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/eyra/atlas/tools/runtime/snapshot"
)

// codexCommand builds the official Codex CLI argv; an empty model keeps Codex's own default.
func codexCommand(executable, workspace, folder, goal string, permissions []string, session, model string) []string {
	command := append([]string{executable, "exec"}, permissions...)
	command = append(command, "--disable", "hooks", "-c", `forced_login_method="chatgpt"`,
		"-c", `approval_policy="never"`, "--color", "never", "--cd", workspace)
	if session != "" {
		command = append(command, "resume")
	}
	if model != "" {
		command = append(command, "--model", model)
	}
	command = append(command, "--json", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check",
		"--output-last-message", filepath.Join(folder, "answer.txt"), "--")
	if session != "" {
		command = append(command, session)
	}
	return append(command, goal)
}

// permissionArguments translates a permission scope into its Codex permission profile;
// scratch is the owned scratch folder and inspector the Runtime executable of a materialized-folder turn.
func permissionArguments(scope any, scratch, inspector string) ([]string, error) {
	fields, _ := scope.(map[string]any)
	switch fields["profile"] {
	case "dedicated-repository":
		return repositoryArguments(fields)
	case "materialized-folder":
		user, err := homeDirectory()
		if err != nil {
			return nil, err
		}
		return folderArguments(fields, scratch, user, inspector)
	}
	return nil, errors.New("Unknown permission profile")
}

// repositoryArguments translates a dedicated-repository scope into the Codex permission profile.
func repositoryArguments(fields map[string]any) ([]string, error) {
	root, ok := fields["root"].(string)
	if !ok {
		return nil, errors.New("Dedicated repository scope requires a root path")
	}
	root = filepath.Clean(root)
	var paths []string
	for _, entry := range [][2]string{
		{root, "write"}, {filepath.Join(root, ".git"), "write"},
		{filepath.Join(root, ".agents"), "read"}, {filepath.Join(root, ".codex"), "read"}, {filepath.Join(root, ".aws"), "read"},
	} {
		key, err := json.Marshal(entry[0])
		if err != nil {
			return nil, err
		}
		paths = append(paths, string(key)+`="`+entry[1]+`"`)
	}
	// One TOML table preserves quoted path keys; dotted CLI override keys do not.
	profile := `permissions={atlas_repository={extends=":read-only",filesystem={` + strings.Join(paths, ",") +
		`},network={enabled=true,domains={"github.com"="allow","api.github.com"="allow"}}}}`
	return []string{"-c", `default_permissions="atlas_repository"`, "-c", profile,
		"-c", "features.network_proxy=true"}, nil
}

// credentialPaths are the user's known credential and control locations, relative to the user home.
var credentialPaths = []string{".codex", ".config/gh", ".ssh", ".aws", ".docker", "Library/Keychains", ".git-credentials",
	".config/git", ".netrc", ".claude", ".claude.json", ".local/state/atlas-runtime", ".gitconfig", ".erlang.cookie"}

// folderArguments translates a materialized-folder scope into the Codex permission profile:
// write only the folder and scratch, read only the snapshot record and baseline, deny Git
// metadata, the Runtime home, the Code token and user credentials under user, loopback networking
// only: the network proxy allows no domain, so external connections fail. Workers may read
// (and so execute) the inspector even inside a denied path.
func folderArguments(scope map[string]any, scratch, user, inspector string) ([]string, error) {
	root, _ := scope["root"].(string)
	home, _ := scope["home"].(string)
	record, _ := scope["record"].(string)
	baseline, _ := scope["baseline"].(string)
	repositories, _ := scope["repositories"].([]any)
	if root == "" || home == "" || record == "" || baseline == "" || len(repositories) == 0 || scratch == "" || inspector == "" {
		return nil, errors.New("Materialized folder scope is incomplete")
	}
	if err := writableInspector(inspector, root, scratch); err != nil {
		return nil, err
	}
	entries := [][2]string{{root, "write"}, {scratch, "write"}, {home, "none"}, {record, "read"}, {baseline, "read"},
		{filepath.Join(root, ".git"), "none"}}
	// Status, diff and submit of a prepared folder read its minimal result, never its diagnostics.
	for _, file := range []string{snapshot.RebindMarker(home, root), snapshot.PreparationResult(home, root)} {
		if _, err := os.Lstat(file); err == nil {
			entries = append(entries, [2]string{file, "read"})
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	}
	for _, repository := range repositories {
		path, ok := repository.(string)
		if !ok {
			return nil, errors.New("Materialized folder scope is incomplete")
		}
		entries = append(entries, [2]string{filepath.Join(root, path, ".git"), "none"})
	}
	denied, err := deniedEntries(home, user, nil, root, scratch)
	if err != nil {
		return nil, err
	}
	entries = append(entries, denied...)
	// Seatbelt lets a specific file read win inside a denied directory; grant only the inspector itself.
	for _, entry := range entries {
		if entry[1] == "none" && within(entry[0], inspector) {
			entries = append(entries, [2]string{inspector, "read"})
			break
		}
	}
	arguments, err := profileArguments("atlas_folder", entries, "network={enabled=true,allow_local_binding=true}")
	if err != nil {
		return nil, err
	}
	return append(arguments, "-c", "features.network_proxy=true"), nil
}

// setupProfile names the Codex permission profile of a folder preparation.
const setupProfile = "atlas_setup"

// setupArguments translates a materialized-folder scope into the Codex permission profile of its
// preparation: write only the writable outputs and the owned scratch, keep the rest of the folder
// read-only, deny Git metadata, the Runtime home (its records and diagnostics included), the Code
// token, the worker credential paths and ~/.npmrc. With network an npm-ci reaches only the public npm
// registry through Codex's network proxy; without, an npm-run has no network at all.
func setupArguments(scope map[string]any, writable []string, scratch, user string, network bool) ([]string, error) {
	root, _ := scope["root"].(string)
	home, _ := scope["home"].(string)
	repositories, _ := scope["repositories"].([]any)
	if root == "" || home == "" || len(repositories) == 0 || len(writable) == 0 || scratch == "" {
		return nil, errors.New("Materialized folder scope is incomplete")
	}
	var entries [][2]string
	for _, output := range writable {
		if !within(root, output) || output == root {
			return nil, errors.New("Materialized folder scope is incomplete")
		}
		entries = append(entries, [2]string{output, "write"})
	}
	entries = append(entries, [2]string{scratch, "write"}, [2]string{home, "none"}, [2]string{filepath.Join(root, ".git"), "none"})
	for _, repository := range repositories {
		path, ok := repository.(string)
		if !ok {
			return nil, errors.New("Materialized folder scope is incomplete")
		}
		entries = append(entries, [2]string{filepath.Join(root, path, ".git"), "none"})
	}
	denied, err := deniedEntries(home, user, []string{".npmrc"}, append(slices.Clone(writable), scratch)...)
	if err != nil {
		return nil, err
	}
	if !network {
		return profileArguments(setupProfile, append(entries, denied...), "network={enabled=false}")
	}
	arguments, err := profileArguments(setupProfile, append(entries, denied...), `network={enabled=true,domains={"`+snapshot.NPMRegistry+`"="allow"}}`)
	if err != nil {
		return nil, err
	}
	return append(arguments, "-c", "features.network_proxy=true"), nil
}

// deniedEntries are the Code token and its directory, which may contain none of writable, and the
// user's credential paths plus extra (relative to user) and CODEX_HOME, resolved through symlinks.
func deniedEntries(home, user string, extra []string, writable ...string) ([][2]string, error) {
	var entries [][2]string
	token, err := codeToken(home)
	if err != nil {
		return nil, err
	}
	if token != "" {
		directory := filepath.Dir(token)
		for _, path := range writable {
			if path == directory || strings.HasPrefix(path, directory+"/") {
				return nil, fmt.Errorf("Code token directory %s contains %s", directory, path)
			}
		}
		entries = append(entries, [2]string{token, "none"}, [2]string{directory, "none"})
	}
	credentials := []string{}
	for _, name := range append(slices.Clone(credentialPaths), extra...) {
		credentials = append(credentials, filepath.Join(user, name))
	}
	// Codex authentication lives in CODEX_HOME when it is set.
	if codexHome := os.Getenv("CODEX_HOME"); codexHome != "" {
		credentials = append(credentials, codexHome)
	}
	for _, credential := range credentials {
		path, err := resolvePath(credential)
		if err != nil {
			return nil, err
		}
		entries = append(entries, [2]string{path, "none"})
	}
	return entries, nil
}

// profileArguments renders filesystem entries and a network table as one named Codex permission profile.
func profileArguments(name string, entries [][2]string, network string) ([]string, error) {
	access := map[string]string{}
	var paths []string
	for _, entry := range entries {
		if previous, seen := access[entry[0]]; seen {
			if previous != entry[1] {
				return nil, fmt.Errorf("Materialized folder permission path %s is both %s and %s", entry[0], previous, entry[1])
			}
			continue
		}
		access[entry[0]] = entry[1]
		key, err := json.Marshal(entry[0])
		if err != nil {
			return nil, err
		}
		paths = append(paths, string(key)+`="`+entry[1]+`"`)
	}
	profile := `permissions={` + name + `={extends=":read-only",filesystem={` + strings.Join(paths, ",") + `},` + network + `}}`
	return []string{"-c", `default_permissions="` + name + `"`, "-c", profile}, nil
}

func within(dir, path string) bool { return path == dir || strings.HasPrefix(path, dir+"/") }

// writableInspector refuses a Runtime executable that workers could replace before running it.
func writableInspector(inspector string, writable ...string) error {
	for _, path := range writable {
		if within(path, inspector) {
			return fmt.Errorf("Runtime executable %s is inside worker-writable %s; install atlas-runtime outside the materialized folder and worker temp", inspector, path)
		}
	}
	return nil
}

// codeToken is the resolved token_file of <home>/code.json, or empty when Code is not configured.
func codeToken(home string) (string, error) {
	data, err := os.ReadFile(filepath.Join(home, "code.json"))
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	} else if err != nil {
		return "", err
	}
	var config struct {
		TokenFile string `json:"token_file"`
	}
	if json.Unmarshal(data, &config) != nil || !filepath.IsAbs(config.TokenFile) {
		return "", errors.New("Runtime code.json must name an absolute token_file")
	}
	return resolvePath(config.TokenFile)
}

// codexProtocol confirms the requested session before any native record is forwarded.
type codexProtocol struct {
	session string
	seen    bool
}

func (protocol *codexProtocol) event(record map[string]any) error {
	if record["type"] == "thread.started" {
		identifier, ok := record["thread_id"].(string)
		if !ok || identifier == "" || (protocol.session != "" && identifier != protocol.session) {
			return errors.New("Codex did not confirm the requested session")
		}
		protocol.seen = true
	}
	return nil
}

func (protocol *codexProtocol) complete(stopped bool) error {
	if protocol.session != "" && !protocol.seen && !stopped {
		return errors.New("Codex resume ended without confirming its session")
	}
	return nil
}
