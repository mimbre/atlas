package host

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
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
// scratch is the owned scratch folder of a materialized-folder turn.
func permissionArguments(scope any, scratch string) ([]string, error) {
	fields, _ := scope.(map[string]any)
	switch fields["profile"] {
	case "dedicated-repository":
		return repositoryArguments(fields)
	case "materialized-folder":
		user, err := homeDirectory()
		if err != nil {
			return nil, err
		}
		return folderArguments(fields, scratch, user)
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
	".config/git", ".netrc", ".claude", ".claude.json", ".local/state/atlas-runtime", ".gitconfig"}

// folderArguments translates a materialized-folder scope into the Codex permission profile:
// write only the folder and scratch, read only the snapshot record and baseline, deny Git
// metadata, the Runtime home, the Code token and user credentials under user, no network.
func folderArguments(scope map[string]any, scratch, user string) ([]string, error) {
	root, _ := scope["root"].(string)
	home, _ := scope["home"].(string)
	record, _ := scope["record"].(string)
	baseline, _ := scope["baseline"].(string)
	repositories, _ := scope["repositories"].([]any)
	if root == "" || home == "" || record == "" || baseline == "" || len(repositories) == 0 || scratch == "" {
		return nil, errors.New("Materialized folder scope is incomplete")
	}
	entries := [][2]string{{root, "write"}, {scratch, "write"}, {home, "none"}, {record, "read"}, {baseline, "read"},
		{filepath.Join(root, ".git"), "none"}}
	for _, repository := range repositories {
		path, ok := repository.(string)
		if !ok {
			return nil, errors.New("Materialized folder scope is incomplete")
		}
		entries = append(entries, [2]string{filepath.Join(root, path, ".git"), "none"})
	}
	token, err := codeToken(home)
	if err != nil {
		return nil, err
	}
	if token != "" {
		directory := filepath.Dir(token)
		for _, writable := range []string{root, scratch} {
			if writable == directory || strings.HasPrefix(writable, directory+"/") {
				return nil, fmt.Errorf("Code token directory %s contains %s", directory, writable)
			}
		}
		entries = append(entries, [2]string{token, "none"}, [2]string{directory, "none"})
	}
	credentials := []string{}
	for _, name := range credentialPaths {
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
	profile := `permissions={atlas_folder={extends=":read-only",filesystem={` + strings.Join(paths, ",") +
		`},network={enabled=false}}}`
	return []string{"-c", `default_permissions="atlas_folder"`, "-c", profile}, nil
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
