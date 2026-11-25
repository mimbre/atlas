package host

// S6 package A2g: the spec table test/fixtures/s6/spec/ and the renderer in render.go.
//
// TestS6RenderParity runs every row of the decision tables through
//   - the legacy Go decision (permissionArguments, sandboxArguments, the claude*Settings, claudeCommand,
//     setupArguments and the codex-sandbox prefixes of prepare.go:161 and host.go:697-709),
//   - an instrumented builder that reads the legacy entry lists into a Spec (legacySpec* below; it
//     lives here, never in production code), and
//   - render.go on the row's checked-in expect.spec,
// and asserts legacy == expect.rendered, render(expect.spec) == expect.rendered and builder ==
// expect.spec. A row whose legacy and rendered results differ on purpose has `change` and keeps
// the legacy result in expect.legacy. With ATLAS_S6_WRITE=1 the expect values are rewritten (B2).
//
// TestS6RenderPreconditions runs the helper-only rows of spec/preconditions.json: the strict
// decoding and the B8 (a)-(d) refusals of hand-written specs.
//
// test/fixtures/s6/spec/README.md describes the row input, the expect shape and the defaults below.

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/eyra/atlas/platform/atlas_runtime/host/internal/s6fixture"
	"github.com/eyra/atlas/platform/atlas_runtime/host/snapshot"
)

// specTables are the decision tables of TestS6RenderParity; row ids are unique across them.
var specTables = []string{"codex.json", "claude.json", "codex_sandbox.json", "runtime_home.json"}

func TestS6RenderParity(t *testing.T) {
	runSpecTables(t, specTables, specParityRow)
}

func TestS6RenderPreconditions(t *testing.T) {
	runSpecTables(t, []string{"preconditions.json"}, specPreconditionRow)
}

func runSpecTables(t *testing.T, names []string, run func(*testing.T, s6fixture.Row) map[string]any) {
	dir := filepath.Join(s6fixture.Dir(t), "spec")
	seen := map[string]bool{}
	for _, name := range names {
		path := filepath.Join(dir, name)
		table := s6fixture.MustLoad(t, path)
		if len(table.Rows) == 0 {
			t.Fatalf("%s has no rows", path)
		}
		for index := range table.Rows {
			row := &table.Rows[index]
			if seen[row.ID] {
				t.Fatalf("%s: row id %s is used twice in the spec tables", path, row.ID)
			}
			seen[row.ID] = true
			t.Run(row.ID, func(t *testing.T) {
				got := run(t, *row)
				if s6fixture.Writing() {
					row.Expect = got
					return
				}
				compareSpecExpect(t, *row, got)
			})
		}
		if s6fixture.Writing() {
			if err := s6fixture.WriteJSON(path, table); err != nil {
				t.Fatal(err)
			}
		}
	}
}

// compareSpecExpect compares a row's computed expect with the checked-in one, part by part.
func compareSpecExpect(t *testing.T, row s6fixture.Row, got map[string]any) {
	t.Helper()
	want, _ := row.Expect.(map[string]any)
	if _, differs := got["legacy"]; differs != (row.Change != "") {
		t.Errorf("legacy and rendered results differ: %v, but the row's change is %q\nlegacy   %s\nrendered %s",
			differs, row.Change, mustCanonical(t, got["legacy"]), mustCanonical(t, got["rendered"]))
	}
	for _, part := range []string{"error", "spec", "legacy", "rendered"} {
		if a, b := mustCanonical(t, got[part]), mustCanonical(t, want[part]); a != b {
			t.Errorf("%s:\ngot  %s\nwant %s", part, a, b)
		}
	}
	for key := range want {
		if !slices.Contains([]string{"error", "spec", "legacy", "rendered"}, key) {
			t.Errorf("unknown expect field %s", key)
		}
	}
}

func mustCanonical(t *testing.T, value any) string {
	t.Helper()
	text, err := s6fixture.Canonical(value)
	if err != nil {
		t.Fatal(err)
	}
	return text
}

// specPlaces are one row's placeholders plus the two resolved system temp roots, which Claude's
// settings name and which differ by platform (/private/tmp on macOS).
type specPlaces struct {
	s6fixture.Places
	system [][2]string
	// hashes are [token, hex] pairs: "{sha256:<abstract path>}" stands for the sha256 hex of the
	// substituted path, which names a folder's rebind and preparation directories.
	hashes [][2]string
}

func (p specPlaces) abstract(value any) any {
	return walkStrings(p.AbstractValue(value), func(s string) string {
		s = p.abstractRules(s)
		for _, pair := range p.hashes {
			s = strings.ReplaceAll(s, pair[1], pair[0])
		}
		for _, pair := range p.system {
			if s == pair[1] {
				return pair[0]
			}
			s = strings.ReplaceAll(s, `"`+pair[1]+`"`, `"`+pair[0]+`"`)
		}
		return s
	})
}

// abstractRules abstracts the paths of Claude rules, Tool(//path): Abstract leaves a path that
// follows a "/" alone, so here "(/" + a placeholder's path (longest first, ending at a non-name
// byte) becomes "(/{name}".
func (p specPlaces) abstractRules(s string) string {
	names := []string{"tmp", "home", "user", "temporary"}
	slices.SortStableFunc(names, func(a, b string) int { return len(p.Places[b]) - len(p.Places[a]) })
	var out strings.Builder
	for i := 0; i < len(s); {
		matched := false
		if strings.HasPrefix(s[i:], "(/") {
			for _, name := range names {
				value := p.Places[name]
				rest := s[i+2:]
				if value != "" && strings.HasPrefix(rest, value) && (len(rest) == len(value) || !specNameByte(rest[len(value)])) {
					out.WriteString("(/{" + name + "}")
					i += 2 + len(value)
					matched = true
					break
				}
			}
		}
		if !matched {
			out.WriteByte(s[i])
			i++
		}
	}
	return out.String()
}

func specNameByte(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' || b == '.' || b == '_' || b == '-'
}

func (p specPlaces) substitute(value any) any {
	return p.SubstituteValue(walkStrings(value, func(s string) string {
		for _, pair := range p.hashes {
			s = strings.ReplaceAll(s, pair[0], pair[1])
		}
		for _, pair := range p.system {
			if s == pair[0] {
				return pair[1]
			}
			s = strings.ReplaceAll(s, `"`+pair[0]+`"`, `"`+pair[1]+`"`)
		}
		return s
	}))
}

func walkStrings(value any, f func(string) string) any {
	switch v := value.(type) {
	case string:
		return f(v)
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = walkStrings(item, f)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(v))
		for key, item := range v {
			out[key] = walkStrings(item, f)
		}
		return out
	}
	return value
}

// generic is value as decoded JSON, numbers as json.Number.
func generic(t *testing.T, value any) any {
	t.Helper()
	text, err := s6fixture.Canonical(value)
	if err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	var out any
	if err = decoder.Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out
}

// setUpSpecRow builds the row's tree under a root outside every system temp root (Claude refuses
// projects inside them), applies the default environment and then the row's, and returns the
// substituted input. Defaults: HOME={user}, ATLAS_RUNTIME_HOME={home}, PATH={tmp}/bin,
// TMPDIR={tmp}/systmp, CODEX_HOME and CLAUDE_CONFIG_DIR empty (unset); the directories {home},
// {user}, {tmp}/bin and {tmp}/systmp exist. {temporary} is a short path outside the root whose
// child-temp path ({temporary}/claude-<uid>) is input.temporary_bytes long (default 40).
func setUpSpecRow(t *testing.T, row s6fixture.Row) (specPlaces, map[string]any) {
	t.Helper()
	root, err := filepath.EvalSymlinks(outsideSystemTemp(t))
	if err != nil {
		t.Fatal(err)
	}
	places := s6fixture.DefaultPlaces(root)
	raw, _ := row.Input.(map[string]any)
	length := 40
	if value, ok := raw["temporary_bytes"].(json.Number); ok {
		n, err := value.Int64()
		if err != nil {
			t.Fatal(err)
		}
		length = int(n)
	}
	suffix := len("/claude-" + strconv.Itoa(os.Getuid()))
	if length < suffix+2 {
		t.Fatalf("temporary_bytes %d is too short", length)
	}
	places["temporary"] = "/" + strings.Repeat("t", length-suffix-1)
	if err = s6fixture.Build(root, places, row.FS); err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{places["home"], places["user"], filepath.Join(root, "bin"), filepath.Join(root, "systmp")} {
		if _, err := os.Lstat(dir); errors.Is(err, os.ErrNotExist) {
			if err = os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
		}
	}
	environment := map[string]string{"HOME": "{user}", "ATLAS_RUNTIME_HOME": "{home}", "PATH": "{tmp}/bin",
		"TMPDIR": "{tmp}/systmp", "CODEX_HOME": "", "CLAUDE_CONFIG_DIR": ""}
	for name, value := range row.Env {
		environment[name] = value
	}
	for name, value := range environment {
		t.Setenv(name, places.Substitute(value))
	}
	previous := platform
	t.Cleanup(func() { platform = previous })
	if name, ok := raw["platform"].(string); ok {
		platform = name
	}
	var system [][2]string
	for _, path := range []string{"/tmp", "/var/tmp"} {
		resolved, err := resolvePath(path)
		if err != nil {
			t.Fatal(err)
		}
		system = append(system, [2]string{"{" + path + "}", resolved})
	}
	p := specPlaces{Places: places, system: system}
	input, _ := p.substitute(row.Input).(map[string]any)
	if input == nil {
		t.Fatal("row has no input object")
	}
	if _, ok := input["temporary"]; !ok {
		input["temporary"] = places["temporary"]
	}
	// input.code_json is written as {home}/code.json after substitution (an fs file's content is
	// written verbatim).
	if config, ok := input["code_json"]; ok {
		data, err := json.Marshal(config)
		if err == nil {
			err = os.WriteFile(filepath.Join(places["home"], "code.json"), data, 0o600)
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	// The rebind marker and preparation result of a folder are named by the hash of its path, which
	// an fs spec cannot write: input.create_markers names the ones to create.
	scope, _ := input["scope"].(map[string]any)
	if markers := texts(input["create_markers"]); len(markers) > 0 {
		root := text(scope["root"])
		p.hashes = append(p.hashes, [2]string{"{sha256:" + places.Abstract(root) + "}", fmt.Sprintf("%x", sha256.Sum256([]byte(root)))})
	}
	for _, marker := range texts(input["create_markers"]) {
		path := map[string]string{"rebind": snapshot.RebindMarker(text(scope["home"]), text(scope["root"])),
			"preparation": snapshot.PreparationResult(text(scope["home"]), text(scope["root"]))}[marker]
		if path == "" {
			t.Fatalf("unknown marker %q", marker)
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("{}\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return p, input
}

// specCase is one decision, computed both ways: the legacy result, and the instrumented spec
// with the launch facts render needs and the dir and argv of a codex-sandbox run.
type specCase struct {
	legacy     any
	legacyErr  error
	spec       *Spec
	builderErr error
	launch     Launch
	dir        string
	argv       []string
}

func specParityRow(t *testing.T, row s6fixture.Row) map[string]any {
	places, input := setUpSpecRow(t, row)
	var c specCase
	switch input["decision"] {
	case "agent":
		c = agentCase(t, input)
	case "codex_sandbox":
		c = codexSandboxCase(t, input)
	default:
		t.Fatalf("unknown decision %v", input["decision"])
	}
	got := map[string]any{}
	if c.builderErr != nil {
		// The decision itself refuses: there is no spec, and legacy must refuse identically.
		if c.legacyErr == nil || c.legacyErr.Error() != c.builderErr.Error() {
			t.Fatalf("builder refuses %q, legacy %v", c.builderErr, c.legacyErr)
		}
		got["error"] = places.abstract(c.builderErr.Error())
		return got
	}
	normalizeSpec(c.spec)
	built := places.abstract(generic(t, c.spec))
	got["spec"] = built
	toRender := built
	if !s6fixture.Writing() {
		want, _ := row.Expect.(map[string]any)
		toRender = want["spec"]
	}
	legacy := places.abstract(generic(t, result(c.legacy, c.legacyErr)))
	rendered := places.abstract(generic(t, renderRow(t, places, input, toRender, c)))
	if mustCanonical(t, legacy) == mustCanonical(t, rendered) {
		got["rendered"] = rendered
	} else {
		got["legacy"], got["rendered"] = legacy, rendered
	}
	return got
}

func result(value any, err error) any {
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	return value
}

// renderRow decodes the (abstract) spec strictly and renders it with the case's launch facts.
func renderRow(t *testing.T, places specPlaces, input map[string]any, abstractSpec any, c specCase) any {
	t.Helper()
	if abstractSpec == nil {
		t.Fatal("row has no expect.spec to render")
	}
	data, err := json.Marshal(places.substitute(abstractSpec))
	if err != nil {
		t.Fatal(err)
	}
	spec, err := DecodeSpec(data)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	return renderSpec(spec, c.launch, c.dir, c.argv)
}

func renderSpec(spec *Spec, launch Launch, dir string, argv []string) any {
	switch {
	case spec.Runner == "codex-sandbox":
		command, err := RenderCodexSandbox(spec, launch, dir, argv)
		return result(map[string]any{"codex_sandbox": command}, err)
	case spec.Harness == "codex":
		arguments, err := RenderCodex(spec, launch)
		return result(map[string]any{"codex": arguments}, err)
	default:
		args, settings, err := RenderClaude(spec, launch)
		return result(map[string]any{"claude": map[string]any{"args": args, "settings": settings}}, err)
	}
}

func text(value any) string { s, _ := value.(string); return s }

func texts(value any) []string {
	var out []string
	for _, item := range anyList(value) {
		out = append(out, text(item))
	}
	return out
}

func anyList(value any) []any { list, _ := value.([]any); return list }

// legacyRuntimeHome is deniedRuntimeHome as run() calls it; it unsets ATLAS_RUNTIME_HOME, which
// is restored for the renderer's own-home check.
func legacyRuntimeHome(t *testing.T, scopeHome string) (string, error) {
	value := os.Getenv("ATLAS_RUNTIME_HOME")
	home, err := deniedRuntimeHome(scopeHome)
	t.Setenv("ATLAS_RUNTIME_HOME", value)
	return home, err
}

// agentCase is run()'s agent decision (host.go:110-155, 250-322) for one backend.
func agentCase(t *testing.T, input map[string]any) (c specCase) {
	harness := text(input["harness"])
	scopeValue := input["scope"]
	scope, _ := scopeValue.(map[string]any)
	sandbox, workspacePath, folder, inspector := text(input["sandbox"]), text(input["workspace"]), text(input["folder"]), text(input["inspector"])
	origin := text(input["origin"])
	questions, _ := input["questions"].(bool)
	profile := text(scope["profile"])
	folderProfile := profile == "materialized-folder"
	scopeHome := text(scope["home"])
	home, err := legacyRuntimeHome(t, scopeHome)
	if err != nil {
		c.legacyErr, c.builderErr = err, err
		return c
	}
	spec := &Spec{Version: 1, Harness: harness, RuntimeHome: home, Env: SpecEnv{Unset: []string{"ATLAS_RUNTIME_HOME"}}}
	if harness == "codex" {
		scratch := ""
		if folderProfile {
			scratch = filepath.Join(scopeHome, "scratch", filepath.Base(folder))
		}
		var arguments []string
		if scopeValue != nil {
			arguments, c.legacyErr = permissionArguments(scope, scratch, inspector, home)
		} else {
			arguments, c.legacyErr = sandboxArguments(sandbox, workspacePath, home)
		}
		c.legacy = map[string]any{"codex": arguments}
		spec.Scratch = scratch
		spec.Codex, spec.Workspace, spec.HomeNames, c.builderErr = legacyCodexSpec(scope, scopeValue != nil, sandbox, workspacePath, scratch, inspector, home)
		spec.Workspace.Origin = origin
		if folderProfile {
			spec.Env = folderEnv(spec.Env, scopeHome, inspector, scratch)
		}
		c.launch = Launch{Dest: spec.Workspace.Root, Scratch: scratch}
		c.spec = spec
		return c
	}
	// Claude: the question session id is generated per launch (row 3a) and is not part of the spec.
	questionSession := ""
	if questions {
		questionSession = "s6-question-session"
	}
	command := claudeCommand("claude", "goal", scopeValue, "", "", questionSession)
	args := claudeFlags(command)
	temporary := ""
	var settings string
	var root string
	if scopeValue != nil {
		user, err := homeDirectory()
		if err == nil {
			user, err = resolvePath(user)
		}
		if err != nil {
			t.Fatal(err)
		}
		temporary = text(input["temporary"])
		spec.Temporary = &SpecTemporary{Parent: user}
		spec.Env.Set = append(spec.Env.Set, []string{"CLAUDE_CODE_TMPDIR", TemporaryToken})
		root = filepath.Clean(text(scope["root"]))
		switch profile {
		case "materialized-folder":
			settings, c.legacyErr = claudeFolderSettings(scope, temporary, user, inspector)
		default:
			settings, c.legacyErr = claudeRepositorySettings(scopeValue, temporary, home)
		}
		if folderProfile {
			spec.Scratch = TemporaryToken
			spec.Env = folderEnv(spec.Env, scopeHome, inspector, TemporaryToken)
		}
	} else {
		settings, c.legacyErr = claudeReadOnlySettings(workspacePath, home)
		if root, err = resolvePath(workspacePath); err != nil {
			t.Fatal(err)
		}
		if within(home, root) {
			// The file tools' Read rules cannot deny a home containing the workspace (claude.go:483-486).
			spec.HomeNames = slices.Clone(runtimeSockets)
		}
	}
	c.legacy = map[string]any{"claude": map[string]any{"args": args, "settings": settings}}
	if c.legacyErr != nil {
		c.builderErr = c.legacyErr
		return c
	}
	// Instrumentation: the Claude decision's output is its settings object; the spec holds it as
	// decoded, with the private temp named by TemporaryToken.
	var decoded ClaudeSettings
	decoder := json.NewDecoder(strings.NewReader(settings))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&decoded); err != nil {
		t.Fatalf("legacy settings do not decode as ClaudeSettings: %v", err)
	}
	if temporary != "" {
		decoded = tokenizeTemporary(decoded, temporary)
	}
	tools := strings.Split(claudeTools(scopeValue), ",")
	spec.Claude = &ClaudeSpec{Tools: tools, AllowedTools: slices.Clone(tools), PermissionMode: "dontAsk", Settings: decoded}
	if questions {
		spec.Claude.Tools, spec.Claude.PermissionMode = append(slices.Clone(tools), "AskUserQuestion"), "manual"
	}
	spec.Workspace = SpecWorkspace{Root: root, Origin: origin}
	c.launch = Launch{Dest: root, Temporary: temporary}
	c.spec = spec
	return c
}

// claudeFlags is claudeCommand's tool and permission part: from --tools up to the session,
// model or goal.
func claudeFlags(command []string) []string {
	start := slices.Index(command, "--tools")
	end := len(command)
	for index := start; index < len(command); index++ {
		if slices.Contains([]string{"--resume", "--session-id", "--model", "--"}, command[index]) {
			end = index
			break
		}
	}
	return slices.Clone(command[start:end])
}

func tokenizeTemporary(settings ClaudeSettings, temporary string) ClaudeSettings {
	if settings.Sandbox == nil {
		return settings
	}
	replace := func(paths []string) []string {
		for index, path := range paths {
			if path == temporary || strings.HasPrefix(path, temporary+"/") {
				paths[index] = TemporaryToken + strings.TrimPrefix(path, temporary)
			}
		}
		return paths
	}
	filesystem := &settings.Sandbox.Filesystem
	filesystem.AllowWrite, filesystem.DenyWrite = replace(filesystem.AllowWrite), replace(filesystem.DenyWrite)
	filesystem.DenyRead, filesystem.AllowRead = replace(filesystem.DenyRead), replace(filesystem.AllowRead)
	settings.Sandbox.Network.AllowUnixSockets = replace(settings.Sandbox.Network.AllowUnixSockets)
	return settings
}

// folderEnv is a folder worker's environment (host.go:287-301): the inspector first on PATH, this
// home and inspector, and temp and caches in the scratch.
func folderEnv(env SpecEnv, home, inspector, scratch string) SpecEnv {
	env.PrefixPath = filepath.Dir(inspector)
	env.Set = append(env.Set, []string{"ATLAS_RUNTIME_HOME", home}, []string{"ATLAS_RUNTIME_EXECUTABLE", inspector},
		[]string{"GIT_CONFIG_GLOBAL", "/dev/null"}, []string{"GIT_CONFIG_NOSYSTEM", "1"}, []string{"GIT_CONFIG_COUNT", "1"},
		[]string{"GIT_CONFIG_KEY_0", "core.excludesFile"}, []string{"GIT_CONFIG_VALUE_0", "/dev/null"})
	for _, cache := range [][2]string{{"TMPDIR", "tmp"}, {"GOCACHE", "go-build"}, {"GOTMPDIR", "go-tmp"},
		{"XDG_CACHE_HOME", "cache"}, {"npm_config_cache", "npm"}} {
		path := scratch + "/" + cache[1]
		env.Set = append(env.Set, []string{cache[0], path})
		env.Mkdirs = append(env.Mkdirs, path)
	}
	return env
}

// legacyCodexSpec reads the entry lists of permissionArguments/sandboxArguments into a CodexSpec.
func legacyCodexSpec(scope map[string]any, scoped bool, sandbox, workspacePath, scratch, inspector, home string) (*CodexSpec, SpecWorkspace, []string, error) {
	var workspace SpecWorkspace
	if !scoped {
		base, name, access := ":read-only", "atlas_read_only", "read"
		if sandbox == "workspace-write" {
			base, name, access = ":workspace", "atlas_workspace_write", "write"
		}
		resolved, err := resolvePath(workspacePath)
		if err != nil {
			return nil, workspace, nil, err
		}
		denied, err := runtimeEntries(home, resolved)
		if err != nil {
			return nil, workspace, nil, err
		}
		if within(home, resolved) {
			denied = append([][2]string{{resolved, access}}, denied...)
		}
		return &CodexSpec{Profile: name, Base: base, Entries: entryList(denied), Network: CodexNetwork{Mode: "none"}},
			SpecWorkspace{Root: resolved}, nil, nil
	}
	switch scope["profile"] {
	case "dedicated-repository":
		spec, root, names, err := legacyRepositorySpec(scope, home)
		return spec, SpecWorkspace{Root: root}, names, err
	case "materialized-folder":
		user, err := homeDirectory()
		if err != nil {
			return nil, workspace, nil, err
		}
		root := text(scope["root"])
		entries, err := legacyWorkerEntries(scope, [][2]string{{root, "write"}}, scratch, user, inspector)
		if err != nil {
			return nil, workspace, nil, err
		}
		return &CodexSpec{Profile: "atlas_folder", Base: ":read-only", Entries: entryList(entries),
			Network:      CodexNetwork{Mode: "loopback", UnixSockets: []string{scratch}, LocalBinding: true},
			NetworkProxy: true, WebSearch: "disabled"}, SpecWorkspace{Root: root}, nil, nil
	}
	return nil, workspace, nil, errors.New("Unknown permission profile")
}

// legacyRepositorySpec reads repositoryArguments (codex.go:63-83).
func legacyRepositorySpec(fields map[string]any, home string) (*CodexSpec, string, []string, error) {
	root, ok := fields["root"].(string)
	if !ok {
		return nil, "", nil, errors.New("Dedicated repository scope requires a root path")
	}
	root = filepath.Clean(root)
	entries := [][2]string{
		{root, "write"}, {filepath.Join(root, ".git"), "write"},
		{filepath.Join(root, ".agents"), "read"}, {filepath.Join(root, ".codex"), "read"}, {filepath.Join(root, ".aws"), "read"},
	}
	denied, err := repositoryRuntimeEntries(home, root)
	if err != nil {
		return nil, "", nil, err
	}
	var names []string
	if within(home, root) {
		names, denied = withAtomicTemps(home, denied)
	}
	return &CodexSpec{Profile: "atlas_repository", Base: ":read-only", Entries: entryList(append(entries, denied...)),
		Network:      CodexNetwork{Mode: "domains", Domains: []string{"github.com", "api.github.com"}},
		NetworkProxy: true, WebSearch: "live"}, root, names, nil
}

// atomicHomeTemps are the atomic-write temps of the denied home files: the .tmp siblings that the
// fixed P0 lists at the end of sensitiveHomeNames (codex.go:177-182) and that the census ties to
// their writers (runtime_home_census_test.go). By the P0 fix decision a managed repository denies
// them, so a spec holds them whatever the legacy list says: if one leaves sensitiveHomeNames, the
// managed rows go red until they carry a change.
var atomicHomeTemps = []string{"code.json.tmp", "server.json.tmp", "backends.json.tmp", "policy.json.tmp",
	"availability.json.tmp", "execution-events.json.tmp", "mode.json.tmp", "clients.json.tmp",
	"update.json.tmp", "update.lock.tmp", "update.log.tmp"}

// withAtomicTemps is a managed repository's home_names (sensitiveHomeNames plus every atomicHomeTemps
// entry it lacks) and its entry list with a none entry for each added temp, placed right after the
// last sensitiveHomeNames entry, where a name appended to that list renders. With the fixed P0,
// which lists every temp, this adds nothing; a temp missing from legacy would make the row's argv
// differ from legacy, so the row would need a change and its expect.legacy.
func withAtomicTemps(home string, denied [][2]string) ([]string, [][2]string) {
	names := slices.Clone(sensitiveHomeNames)
	var added [][2]string
	for _, name := range atomicHomeTemps {
		if !slices.Contains(names, name) {
			names = append(names, name)
			added = append(added, [2]string{filepath.Join(home, name), "none"})
		}
	}
	last := filepath.Join(home, sensitiveHomeNames[len(sensitiveHomeNames)-1])
	at := slices.IndexFunc(denied, func(entry [2]string) bool { return entry == [2]string{last, "none"} })
	if len(added) == 0 || at < 0 {
		return names, denied
	}
	return names, slices.Concat(denied[:at+1], added, denied[at+1:])
}

// legacyWorkerEntries reads workerArguments' entry list (codex.go:347-415).
func legacyWorkerEntries(scope map[string]any, project [][2]string, scratch, user, inspector string) ([][2]string, error) {
	root, _ := scope["root"].(string)
	home, _ := scope["home"].(string)
	record, _ := scope["record"].(string)
	baseline, _ := scope["baseline"].(string)
	repositories, _ := scope["repositories"].([]any)
	if root == "" || home == "" || record == "" || baseline == "" || len(repositories) == 0 || scratch == "" || inspector == "" {
		return nil, errors.New("Materialized folder scope is incomplete")
	}
	var paths, writable []string
	for _, entry := range project {
		if paths = append(paths, entry[0]); entry[1] == "write" {
			writable = append(writable, entry[0])
		}
	}
	if err := writableInspector(inspector, append(writable, scratch)...); err != nil {
		return nil, err
	}
	user, err := resolvePath(user)
	if err != nil {
		return nil, err
	}
	socketDenies, err := socketEntries(home, append(slices.Clone(paths), scratch)...)
	if err != nil {
		return nil, err
	}
	entries := slices.Concat(project, [][2]string{{scratch, "write"}, {user, "none"}, {home, "none"}}, socketDenies,
		[][2]string{{record, "read"}, {baseline, "read"}, {filepath.Join(root, ".git"), "none"}})
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
		entries = append(entries, repositoryGitEntries(root, path)...)
	}
	denied, err := deniedEntries(home, user, nil, append(slices.Clone(paths), scratch)...)
	if err != nil {
		return nil, err
	}
	var none []string
	for _, entry := range append(slices.Clone(entries), denied...) {
		if entry[1] == "none" && entry[0] != user {
			none = append(none, entry[0])
		}
	}
	readable, err := homeReadable(user, none, append(slices.Clone(paths), scratch))
	if err != nil {
		return nil, err
	}
	for _, path := range readable {
		entries = append(entries, [2]string{path, "read"})
	}
	entries = append(entries, denied...)
	for _, entry := range entries {
		if entry[1] == "none" && within(entry[0], inspector) {
			entries = append(entries, [2]string{inspector, "read"})
			break
		}
	}
	return entries, nil
}

// legacySetupEntries reads setupArguments' entry list (codex.go:438-472).
func legacySetupEntries(scope map[string]any, writable []string, scratch, user string) ([][2]string, error) {
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
	return append(entries, denied...), nil
}

func entryList(entries [][2]string) [][]string {
	out := make([][]string, len(entries))
	for index, entry := range entries {
		out[index] = []string{entry[0], entry[1]}
	}
	return out
}

// codexSandboxCase is the `codex sandbox` run of a preparation step (prepare.go:107-166) or of a
// Claude worker's managed-repository preparation (host.go:690-709).
func codexSandboxCase(t *testing.T, input map[string]any) (c specCase) {
	kind, origin := text(input["kind"]), text(input["origin"])
	scope, _ := input["scope"].(map[string]any)
	c.argv, c.dir = texts(input["argv"]), text(input["dir"])
	spec := &Spec{Version: 1, Harness: "codex", Runner: "codex-sandbox", Kind: kind, Env: SpecEnv{Unset: []string{"ATLAS_RUNTIME_HOME"}}}
	switch kind {
	case "setup":
		writable, scratch := texts(input["writable"]), text(input["scratch"])
		network := text(input["step"]) == "npm-ci"
		user, err := homeDirectory()
		if err == nil {
			user, err = resolvePath(user)
		}
		if err != nil {
			t.Fatal(err)
		}
		// Legacy: the tool lookups, then the profile, then the command (prepare.go:107-166).
		c.legacyErr = func() error {
			tools := map[string]string{}
			for _, tool := range [][2]string{{"codex", "Preparation requires the installed Codex sandbox (codex on PATH)"}, {"npm", "Preparation requires npm on PATH"}} {
				found, err := exec.LookPath(tool[0])
				if err != nil || !filepath.IsAbs(found) {
					return errors.New(tool[1])
				}
				tools[tool[0]] = found
			}
			arguments, err := setupArguments(scope, writable, scratch, user, network)
			if err != nil {
				return err
			}
			command := append(append([]string{tools["codex"], "sandbox", "-P", setupProfile, "-C", c.dir}, arguments...), "--", tools["npm"])
			if network {
				command = append(command, npmArguments...)
			} else {
				command = append(append(command, runArguments...), text(input["script"]))
			}
			c.legacy = map[string]any{"codex_sandbox": command}
			return nil
		}()
		entries, err := legacySetupEntries(scope, writable, scratch, user)
		if err != nil {
			c.builderErr = err
			return c
		}
		spec.Codex = &CodexSpec{Profile: setupProfile, Base: ":read-only", Entries: entryList(entries), Network: CodexNetwork{Mode: "none"}}
		if network {
			spec.Codex.Network, spec.Codex.NetworkProxy = CodexNetwork{Mode: "domains", Domains: []string{snapshot.NPMRegistry}}, true
		}
		spec.RuntimeHome, spec.Scratch = text(scope["home"]), scratch
		spec.Workspace = SpecWorkspace{Root: text(scope["root"]), Origin: origin}
		c.launch = Launch{Dest: spec.Workspace.Root, Scratch: scratch}
	case "pre_exec":
		workspacePath := text(input["workspace"])
		home, err := legacyRuntimeHome(t, "")
		if err != nil {
			c.legacyErr, c.builderErr = err, err
			return c
		}
		c.legacyErr = func() error {
			sandbox, err := exec.LookPath("codex")
			if err != nil && !errors.Is(err, exec.ErrDot) {
				return errors.New("Managed repository preparation requires the installed Codex sandbox")
			}
			permissions, err := permissionArguments(scope, "", "", home)
			if err != nil {
				return err
			}
			c.legacy = map[string]any{"codex_sandbox": append(append([]string{sandbox, "sandbox", "-P", "atlas_repository", "-C", workspacePath}, permissions...), "--")}
			return nil
		}()
		codex, root, names, err := legacyRepositorySpec(scope, home)
		if err != nil {
			c.builderErr = err
			return c
		}
		spec.Codex, spec.HomeNames, spec.RuntimeHome = codex, names, home
		spec.Workspace = SpecWorkspace{Root: root, Origin: origin}
		c.launch, c.dir = Launch{Dest: workspacePath}, workspacePath
	default:
		t.Fatalf("unknown codex-sandbox kind %q", kind)
	}
	c.spec = spec
	return c
}

// normalizeSpec writes absent lists as empty ones, so the table holds one form.
func normalizeSpec(spec *Spec) {
	empty := func(list *[]string) {
		if *list == nil {
			*list = []string{}
		}
	}
	if spec.Env.Set == nil {
		spec.Env.Set = [][]string{}
	}
	empty(&spec.Env.Unset)
	empty(&spec.Env.Mkdirs)
	if spec.Codex != nil {
		if spec.Codex.Entries == nil {
			spec.Codex.Entries = [][]string{}
		}
		empty(&spec.Codex.Network.Domains)
		empty(&spec.Codex.Network.UnixSockets)
	}
}

// specPreconditionRow renders a hand-written spec (or decodes a raw one) with the row's launch.
func specPreconditionRow(t *testing.T, row s6fixture.Row) map[string]any {
	places, input := setUpSpecRow(t, row)
	if raw, ok := input["decode"].(string); ok {
		_, err := DecodeSpec([]byte(raw))
		if err == nil {
			t.Fatal("a decode row must be refused")
		}
		return map[string]any{"rendered": places.abstract(map[string]any{"error": err.Error()})}
	}
	data, err := json.Marshal(input["spec"])
	if err != nil {
		t.Fatal(err)
	}
	spec, err := DecodeSpec(data)
	if err != nil {
		t.Fatalf("precondition spec does not decode: %v", err)
	}
	launch, _ := input["launch"].(map[string]any)
	at := Launch{Dest: text(launch["dest"]), Scratch: text(launch["scratch"]), Temporary: text(launch["temporary"])}
	var rendered any
	switch input["render"] {
	case "codex":
		arguments, err := RenderCodex(spec, at)
		rendered = result(map[string]any{"codex": arguments}, err)
	case "codex_sandbox":
		command, err := RenderCodexSandbox(spec, at, text(input["dir"]), texts(input["argv"]))
		rendered = result(map[string]any{"codex_sandbox": command}, err)
	case "claude":
		args, settings, err := RenderClaude(spec, at)
		rendered = result(map[string]any{"claude": map[string]any{"args": args, "settings": settings}}, err)
	default:
		t.Fatalf("unknown render %v", input["render"])
	}
	return map[string]any{"rendered": places.abstract(generic(t, rendered))}
}
