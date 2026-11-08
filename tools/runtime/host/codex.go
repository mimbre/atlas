package host

import (
	"encoding/json"
	"errors"
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

// permissionArguments translates a dedicated-repository scope into the Codex permission profile.
func permissionArguments(scope any) ([]string, error) {
	fields, _ := scope.(map[string]any)
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
