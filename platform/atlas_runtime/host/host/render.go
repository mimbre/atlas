package host

// render.go is the helper side of S6 move 2 (plan s6-plan.md, package A2g): it renders a fully
// resolved, neutral sandbox spec (B7) into today's exact Codex argv fragment, `codex sandbox`
// prefix or Claude flags and settings, and refuses a spec that breaks the fail-closed
// preconditions B8 (a)-(d). The spec is decided elsewhere (Elixir from C2 on); rendering decides
// nothing. Nothing in the launch path calls this file yet: C2 wires it in.
//
// The rendering code is deliberately separate from the legacy builders in codex.go and claude.go,
// so the parity test (s6_render_parity_test.go) compares two implementations, not one.

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Spec is the neutral sandbox spec of one launch (B7).
type Spec struct {
	Version int `json:"version"`
	// Harness is codex or claude. A `codex sandbox` run (Runner "codex-sandbox") is always codex.
	Harness string `json:"harness"`
	// Runner is empty for an agent spec and "codex-sandbox" for a setup or pre_exec run (B12).
	Runner string `json:"runner,omitempty"`
	// Kind is the codex-sandbox kind: setup or pre_exec. check is added with C0.
	Kind string `json:"kind,omitempty"`
	// RuntimeHome is the Runtime home this spec denies; it must be the helper's own (B8 c).
	RuntimeHome string `json:"runtime_home"`
	// HomeNames are the home entries the spec denies by name when the home contains its
	// workspace and so cannot be denied whole (B8 a).
	HomeNames []string       `json:"home_names,omitempty"`
	Codex     *CodexSpec     `json:"codex,omitempty"`
	Claude    *ClaudeSpec    `json:"claude,omitempty"`
	Env       SpecEnv        `json:"env"`
	Scratch   string         `json:"scratch"`
	Temporary *SpecTemporary `json:"temporary,omitempty"`
	Workspace SpecWorkspace  `json:"workspace"`
}

// CodexSpec is one Codex permission profile. Entries are [path, read|write|none] in decision
// order; Codex keeps the first occurrence of a path, and so does the renderer.
type CodexSpec struct {
	Profile      string       `json:"profile"`
	Base         string       `json:"base"`
	Entries      [][]string   `json:"entries"`
	Network      CodexNetwork `json:"network"`
	NetworkProxy bool         `json:"network_proxy"`
	// WebSearch is "" (no override), "live" or "disabled".
	WebSearch string `json:"web_search"`
}

// CodexNetwork is the profile's network table: none, loopback (local binding and Unix sockets
// only) or domains (the network proxy's allow list).
type CodexNetwork struct {
	Mode         string   `json:"mode"`
	Domains      []string `json:"domains"`
	UnixSockets  []string `json:"unix_sockets"`
	LocalBinding bool     `json:"local_binding"`
}

// ClaudeSpec is Claude's tool list, permission mode and `--settings`.
type ClaudeSpec struct {
	Tools        []string `json:"tools"`
	AllowedTools []string `json:"allowed_tools"`
	// PermissionMode is dontAsk (no prompts) or manual (host-answered questions over stdio).
	PermissionMode string         `json:"permission_mode"`
	Settings       ClaudeSettings `json:"settings"`
}

// ClaudeSettings are the claudeSettings fields; a plain read-only turn has no sandbox.
type ClaudeSettings struct {
	Sandbox     *claudeSandbox     `json:"sandbox,omitempty"`
	Permissions *claudePermissions `json:"permissions"`
}

// SpecEnv is what the launch changes in the inherited environment: unset first, then set in
// order, PATH prefixed with PrefixPath, and Mkdirs created (0700) before the launch.
type SpecEnv struct {
	Set        [][]string `json:"set"`
	Unset      []string   `json:"unset"`
	PrefixPath string     `json:"prefix_path"`
	Mkdirs     []string   `json:"mkdirs"`
}

// SpecTemporary is the private temp the helper creates in Parent; spec paths name it TemporaryToken.
type SpecTemporary struct {
	Parent string `json:"parent"`
}

// SpecWorkspace is the launch's project root and who chose it (B13).
type SpecWorkspace struct {
	Root   string `json:"root"`
	Origin string `json:"origin"`
}

// TemporaryToken stands for the created private temp in spec paths: the spec is decided before
// the helper creates it, under a random name.
const TemporaryToken = "$TEMPORARY"

// Launch is what only the helper knows when it renders: the canonical scope dest or workspace it
// launches in, this turn's own scratch ("" when it has none) and the private temp it created.
type Launch struct {
	Dest      string
	Scratch   string
	Temporary string
}

// Refusal texts of the B8 preconditions.
const (
	refuseHomeNotDenied = "Runtime spec does not deny the Runtime home"
	refuseHomeWrite     = "Runtime spec writes inside the Runtime home"
	refuseOtherHome     = "Runtime spec denies another home"
)

// codexSandboxUnavailable is B8 (d)'s refusal per kind; each is today's text (prepare.go:107,
// host.go:702). There is no unsandboxed fallback.
var codexSandboxUnavailable = map[string]string{
	"setup":    "Preparation requires the installed Codex sandbox (codex on PATH)",
	"pre_exec": "Managed repository preparation requires the installed Codex sandbox",
}

// DecodeSpec reads one spec strictly: one JSON value, no unknown field at any level, version 1.
func DecodeSpec(data []byte) (*Spec, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	var spec Spec
	if err := decoder.Decode(&spec); err != nil {
		return nil, errors.New("Runtime spec: " + err.Error())
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, errors.New("Runtime spec must be one JSON value")
	}
	return &spec, spec.validate()
}

func (spec *Spec) validate() error {
	if spec.Version != 1 {
		return errors.New("Runtime spec version must be 1")
	}
	switch {
	case spec.Harness == "codex" && spec.Codex != nil && spec.Claude == nil:
	case spec.Harness == "claude" && spec.Claude != nil && spec.Codex == nil && spec.Runner == "":
	default:
		return errors.New("Runtime spec must carry the settings of exactly its harness")
	}
	if spec.Runner == "" && spec.Kind != "" || spec.Runner != "" && (spec.Runner != "codex-sandbox" || codexSandboxUnavailable[spec.Kind] == "") {
		return errors.New("Runtime spec runner is invalid")
	}
	if !absoluteClean(spec.RuntimeHome) {
		return errors.New("Runtime spec runtime_home must be an absolute path")
	}
	for _, name := range spec.HomeNames {
		if name == "" || strings.Contains(name, "/") || name == "." || name == ".." {
			return errors.New("Runtime spec home name is invalid")
		}
	}
	if spec.Workspace.Origin != "runtime_chosen" && spec.Workspace.Origin != "client_named" || !absoluteClean(spec.Workspace.Root) {
		return errors.New("Runtime spec workspace is invalid")
	}
	if spec.Temporary != nil && !absoluteClean(spec.Temporary.Parent) {
		return errors.New("Runtime spec temporary parent must be an absolute path")
	}
	if codex := spec.Codex; codex != nil {
		if codex.Profile == "" || codex.Base != ":read-only" && codex.Base != ":workspace" {
			return errors.New("Runtime spec Codex profile is invalid")
		}
		for _, entry := range codex.Entries {
			if len(entry) != 2 || entry[0] == "" || entry[1] != "read" && entry[1] != "write" && entry[1] != "none" {
				return errors.New("Runtime spec entry is invalid")
			}
		}
		network := codex.Network
		switch {
		case network.Mode == "none" && len(network.Domains) == 0 && len(network.UnixSockets) == 0 && !network.LocalBinding:
		case network.Mode == "loopback" && len(network.Domains) == 0:
		case network.Mode == "domains" && len(network.Domains) > 0:
		default:
			return errors.New("Runtime spec network is invalid")
		}
		if codex.WebSearch != "" && codex.WebSearch != "live" && codex.WebSearch != "disabled" {
			return errors.New("Runtime spec web search is invalid")
		}
	}
	if claude := spec.Claude; claude != nil {
		if claude.PermissionMode != "dontAsk" && claude.PermissionMode != "manual" || len(claude.Tools) == 0 || len(claude.AllowedTools) == 0 {
			return errors.New("Runtime spec Claude tools or permission mode are invalid")
		}
		if claude.Settings.Permissions == nil {
			return errors.New("Runtime spec Claude settings need permissions")
		}
	}
	return nil
}

func absoluteClean(path string) bool { return filepath.IsAbs(path) && filepath.Clean(path) == path }

// RenderCodex renders a Codex agent spec as its permission arguments: the fragment that
// permissionArguments or sandboxArguments returns today.
func RenderCodex(spec *Spec, launch Launch) ([]string, error) {
	if spec.Harness != "codex" || spec.Runner != "" {
		return nil, errors.New("Runtime spec is not a Codex agent spec")
	}
	if err := checkSpec(spec, launch, nil); err != nil {
		return nil, err
	}
	return renderCodexProfile(spec.Codex)
}

// RenderCodexSandbox renders a codex-sandbox spec as the argv that runs argv in dir under
// `codex sandbox` with the spec's profile. It refuses when codex does not resolve (B8 d).
func RenderCodexSandbox(spec *Spec, launch Launch, dir string, argv []string) ([]string, error) {
	if spec.Runner != "codex-sandbox" {
		return nil, errors.New("Runtime spec is not a codex-sandbox spec")
	}
	if err := checkSpec(spec, launch, nil); err != nil {
		return nil, err
	}
	codex, err := exec.LookPath("codex")
	// A managed repository's preparation keeps today's acceptance of a PATH entry relative to
	// the working directory (host.go:701); a preparation needs an absolute codex (prepare.go:121).
	if spec.Kind == "pre_exec" && errors.Is(err, exec.ErrDot) {
		err = nil
	} else if err == nil && !filepath.IsAbs(codex) {
		err = exec.ErrNotFound
	}
	if err != nil {
		return nil, errors.New(codexSandboxUnavailable[spec.Kind])
	}
	permissions, err := renderCodexProfile(spec.Codex)
	if err != nil {
		return nil, err
	}
	command := append([]string{codex, "sandbox", "-P", spec.Codex.Profile, "-C", dir}, permissions...)
	return append(append(command, "--"), argv...), nil
}

// RenderClaude renders a Claude spec as its tool and permission flags (the claudeCommand part
// between the fixed flags and the session) and its `--settings` value.
func RenderClaude(spec *Spec, launch Launch) ([]string, string, error) {
	if spec.Harness != "claude" {
		return nil, "", errors.New("Runtime spec is not a Claude spec")
	}
	settings, err := spec.Claude.Settings.withTemporary(launch.Temporary)
	if err != nil {
		return nil, "", err
	}
	if err = checkSpec(spec, launch, &settings); err != nil {
		return nil, "", err
	}
	claude := spec.Claude
	args := []string{"--tools", strings.Join(claude.Tools, ","), "--allowedTools", strings.Join(claude.AllowedTools, ",")}
	if claude.PermissionMode == "manual" {
		args = append(args, "--input-format", "stream-json", "--permission-mode", "manual",
			"--permission-prompts", "host", "--permission-prompt-tool", "stdio")
	} else {
		args = append(args, "--permission-mode", "dontAsk", "--permission-prompts", "none")
	}
	var encoded string
	if settings.Sandbox == nil {
		encoded, err = renderJSON(struct {
			Permissions claudePermissions `json:"permissions"`
		}{*settings.Permissions})
	} else {
		encoded, err = renderJSON(settings)
	}
	return args, encoded, err
}

// withTemporary is a copy of the settings with TemporaryToken replaced by the created temp.
func (settings ClaudeSettings) withTemporary(temporary string) (ClaudeSettings, error) {
	if settings.Sandbox == nil {
		return settings, nil
	}
	var missing bool
	replace := func(paths []string) []string {
		if paths == nil {
			return nil
		}
		out := make([]string, len(paths))
		for index, path := range paths {
			if path == TemporaryToken || strings.HasPrefix(path, TemporaryToken+"/") {
				missing = missing || temporary == ""
				path = temporary + strings.TrimPrefix(path, TemporaryToken)
			}
			out[index] = path
		}
		return out
	}
	sandbox := *settings.Sandbox
	sandbox.Filesystem.AllowWrite = replace(sandbox.Filesystem.AllowWrite)
	sandbox.Filesystem.DenyWrite = replace(sandbox.Filesystem.DenyWrite)
	sandbox.Filesystem.DenyRead = replace(sandbox.Filesystem.DenyRead)
	sandbox.Filesystem.AllowRead = replace(sandbox.Filesystem.AllowRead)
	sandbox.Network.AllowUnixSockets = replace(sandbox.Network.AllowUnixSockets)
	if missing {
		return settings, errors.New("Runtime spec names a private temp the helper did not create")
	}
	settings.Sandbox = &sandbox
	return settings, nil
}

// checkSpec applies the fail-closed preconditions B8 (c), (a) and (b), in that order. They check
// the spec; they decide nothing.
func checkSpec(spec *Spec, launch Launch, settings *ClaudeSettings) error {
	own, err := ownRuntimeHome()
	if err != nil {
		return err
	}
	// (c) The spec denies exactly the home this helper runs under.
	if spec.RuntimeHome != own {
		return errors.New(refuseOtherHome)
	}
	home := spec.RuntimeHome
	var writes []string
	var denied func(string) bool
	if spec.Codex != nil {
		access := map[string]string{}
		for _, entry := range spec.Codex.Entries {
			if _, seen := access[entry[0]]; !seen {
				access[entry[0]] = entry[1]
			}
			if access[entry[0]] == "write" && entry[1] == "write" {
				writes = append(writes, entry[0])
			}
		}
		denied = func(path string) bool { return access[path] == "none" }
	} else {
		rules := map[string]bool{}
		for _, rule := range settings.Permissions.Deny {
			rules[rule] = true
		}
		var denyRead []string
		if settings.Sandbox != nil {
			denyRead = settings.Sandbox.Filesystem.DenyRead
			writes = settings.Sandbox.Filesystem.AllowWrite
		}
		// With a Bash sandbox the home must be in its own denyRead; the file tools' Read rules
		// count only for the form without a sandbox (legacy always lists it, claude.go:278, 445).
		sandboxed := settings.Sandbox != nil
		denied = func(path string) bool {
			if sandboxed {
				return containsString(denyRead, path)
			}
			return rules["Read(/"+path+")"]
		}
	}
	// (a) The home is denied whole, or, when it contains the workspace, by every one of its names.
	if !denied(home) {
		if !within(home, spec.Workspace.Root) || len(spec.HomeNames) == 0 {
			return errors.New(refuseHomeNotDenied)
		}
		for _, name := range spec.HomeNames {
			if !denied(filepath.Join(home, name)) {
				return errors.New(refuseHomeNotDenied)
			}
		}
	}
	// (b) Inside the home only this turn's own scratch and a Runtime-chosen root equal to the
	// launch's dest are written.
	for _, path := range writes {
		if !within(home, path) {
			continue
		}
		if launch.Scratch != "" && spec.Scratch == launch.Scratch && within(launch.Scratch, path) {
			continue
		}
		if spec.Workspace.Origin == "runtime_chosen" && spec.Workspace.Root == launch.Dest && within(spec.Workspace.Root, path) {
			continue
		}
		return errors.New(refuseHomeWrite)
	}
	return nil
}

func containsString(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}

// ownRuntimeHome is the home this helper runs under, resolved as deniedRuntimeHome resolves a
// turn without a scope home (host.go:641-658), without unsetting anything.
func ownRuntimeHome() (string, error) {
	home := os.Getenv("ATLAS_RUNTIME_HOME")
	if home == "" {
		user, err := homeDirectory()
		if err != nil {
			return "", err
		}
		home = filepath.Join(user, ".local", "state", "atlas-runtime")
	} else if !filepath.IsAbs(home) {
		return "", errors.New("ATLAS_RUNTIME_HOME must be an absolute path")
	}
	return resolvePath(home)
}

// renderCodexProfile renders one named profile as `-c default_permissions=… -c permissions={…}`
// plus the network proxy and web search overrides.
func renderCodexProfile(codex *CodexSpec) ([]string, error) {
	access := map[string]string{}
	var paths []string
	for _, entry := range codex.Entries {
		path, mode := entry[0], entry[1]
		if previous, seen := access[path]; seen {
			if previous != mode {
				return nil, errors.New("Materialized folder permission path " + path + " is both " + previous + " and " + mode)
			}
			continue
		}
		access[path] = mode
		key, err := json.Marshal(path)
		if err != nil {
			return nil, err
		}
		paths = append(paths, string(key)+`="`+mode+`"`)
	}
	network, err := renderCodexNetwork(codex.Network)
	if err != nil {
		return nil, err
	}
	profile := `permissions={` + codex.Profile + `={extends="` + codex.Base + `",filesystem={` + strings.Join(paths, ",") + `},` + network + `}}`
	arguments := []string{"-c", `default_permissions="` + codex.Profile + `"`, "-c", profile}
	if codex.NetworkProxy {
		arguments = append(arguments, "-c", "features.network_proxy=true")
	}
	if codex.WebSearch != "" {
		arguments = append(arguments, "-c", `web_search="`+codex.WebSearch+`"`)
	}
	return arguments, nil
}

func renderCodexNetwork(network CodexNetwork) (string, error) {
	if network.Mode == "none" {
		return "network={enabled=false}", nil
	}
	table := "network={enabled=true"
	if len(network.Domains) > 0 {
		var domains []string
		for _, domain := range network.Domains {
			key, err := json.Marshal(domain)
			if err != nil {
				return "", err
			}
			domains = append(domains, string(key)+`="allow"`)
		}
		table += ",domains={" + strings.Join(domains, ",") + "}"
	}
	if network.LocalBinding {
		table += ",allow_local_binding=true"
	}
	if len(network.UnixSockets) > 0 {
		var sockets []string
		for _, socket := range network.UnixSockets {
			key, err := json.Marshal(socket)
			if err != nil {
				return "", err
			}
			sockets = append(sockets, string(key)+`="allow"`)
		}
		table += ",unix_sockets={" + strings.Join(sockets, ",") + "}"
	}
	return table + "}", nil
}

// renderJSON is compact JSON without HTML escaping, as Claude reads its settings.
func renderJSON(value any) (string, error) {
	var encoded bytes.Buffer
	encoder := json.NewEncoder(&encoded)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return "", err
	}
	return strings.TrimSuffix(encoded.String(), "\n"), nil
}
