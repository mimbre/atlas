package host

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"math/rand/v2"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"

	"github.com/eyra/atlas/platform/atlas_runtime/host/snapshot"
	"github.com/eyra/atlas/platform/atlas_runtime/host/workspace"
)

var canonicalUUID = regexp.MustCompile(`\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z`)

// platform is replaced in tests to cover the macOS-only trust service allowance.
var platform = runtime.GOOS

// claudeValidate keeps the Python check order, including uuid.UUID's own parse errors.
func claudeValidate(scope any, sandbox, session string, model, expectedContext any) error {
	if scope == nil && sandbox != "read-only" {
		return errors.New("Claude requires read-only, dedicated-repository or materialized-folder execution")
	}
	if fields, _ := scope.(map[string]any); scope != nil && !slices.Contains([]string{"dedicated-repository", "materialized-folder"}, fmt.Sprint(fields["profile"])) {
		return errors.New("Claude supports only the dedicated-repository and materialized-folder permission profiles")
	}
	if session == "" {
		return nil
	}
	if !canonicalUUID.MatchString(session) {
		hex := strings.ReplaceAll(strings.ReplaceAll(session, "urn:", ""), "uuid:", "")
		hex = strings.ReplaceAll(strings.Trim(hex, "{}"), "-", "")
		if utf8.RuneCountInString(hex) != 32 {
			return errors.New("badly formed hexadecimal UUID string")
		}
		if !pythonHexInteger(hex) {
			return errors.New("invalid literal for int() with base 16: " + pythonRepr(hex))
		}
	}
	if _, saved := expectedContext.(map[string]any); !canonicalUUID.MatchString(session) || model == nil || !saved {
		return errors.New("Claude resume requires a confirmed UUID, model and saved execution context")
	}
	return nil
}

// pythonHexInteger accepts what int(text, 16) accepts.
// shortcut: ASCII digits only; Python also takes other Unicode digits, irrelevant for session IDs.
func pythonHexInteger(text string) bool {
	text = strings.TrimFunc(text, unicode.IsSpace)
	if strings.HasPrefix(text, "+") || strings.HasPrefix(text, "-") {
		text = text[1:]
	}
	if len(text) >= 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X') {
		text = text[2:]
		if strings.HasPrefix(text, "_") {
			text = text[1:]
		}
	}
	if text == "" || strings.HasPrefix(text, "_") || strings.HasSuffix(text, "_") || strings.Contains(text, "__") {
		return false
	}
	return strings.Trim(text, "0123456789abcdefABCDEF_") == ""
}

// pythonRepr quotes like Python's str repr for diagnostics copied from Python.
func pythonRepr(text string) string {
	quote := "'"
	if strings.Contains(text, "'") && !strings.Contains(text, `"`) {
		quote = `"`
	}
	var builder strings.Builder
	builder.WriteString(quote)
	for _, char := range text {
		switch {
		case char == '\\' || string(char) == quote:
			builder.WriteString(`\` + string(char))
		case char == '\n':
			builder.WriteString(`\n`)
		case char == '\r':
			builder.WriteString(`\r`)
		case char == '\t':
			builder.WriteString(`\t`)
		case char < 0x20 || char == 0x7f:
			fmt.Fprintf(&builder, `\x%02x`, char)
		default:
			builder.WriteRune(char)
		}
	}
	return builder.String() + quote
}

// claudeTools are the native tools Claude may use without asking.
func claudeTools(scope any) string {
	if scope != nil {
		return "Bash,Read,Glob,Grep"
	}
	return "Read,Glob,Grep"
}

// claudeCommand builds the official Claude CLI argv; an empty model keeps Claude's default.
// A question session selects the host-answered stream-json query, whose goal goes over stdin.
func claudeCommand(executable, goal string, scope any, session, model, questionSession string) []string {
	tools := claudeTools(scope)
	command := []string{executable, "--print", "--output-format", "stream-json", "--verbose",
		"--restricted", "--safe-mode", "--strict-mcp-config", "--no-chrome"}
	if questionSession != "" {
		command = append(command, "--tools", tools+",AskUserQuestion", "--allowedTools", tools,
			"--input-format", "stream-json", "--permission-mode", "manual",
			"--permission-prompts", "host", "--permission-prompt-tool", "stdio")
	} else {
		command = append(command, "--tools", tools, "--allowedTools", tools,
			"--permission-mode", "dontAsk", "--permission-prompts", "none")
	}
	if session != "" {
		command = append(command, "--resume", session)
	} else if questionSession != "" {
		command = append(command, "--session-id", questionSession)
	}
	if model != "" {
		command = append(command, "--model", model)
	}
	if questionSession != "" {
		return command
	}
	return append(command, "--", goal)
}

// claudeProtocol confirms a resumed session and model before any native record is forwarded.
type claudeProtocol struct {
	session, model string
	seen           bool
}

func (protocol *claudeProtocol) event(record map[string]any) error {
	if protocol.session == "" {
		return nil
	}
	if record["type"] == "system" && record["subtype"] == "init" {
		if record["session_id"] != protocol.session || record["model"] != protocol.model {
			return errors.New("Claude did not confirm the requested session and model")
		}
		protocol.seen = true
	}
	if record["type"] == "assistant" {
		var actual any
		if message, present := record["message"]; present {
			fields, ok := message.(map[string]any)
			if !ok {
				return fmt.Errorf("'%s' object has no attribute 'get'", pythonType(message))
			}
			actual = fields["model"]
		}
		if truthy(actual) && actual != "<synthetic>" && !assistantModelMatches(protocol.model, actual) {
			return errors.New("Claude resumed with a different model")
		}
	}
	return nil
}

func (protocol *claudeProtocol) complete(stopped bool) error {
	if protocol.session != "" && !protocol.seen && !stopped {
		return errors.New("Claude resume ended without confirming its session")
	}
	return nil
}

func pythonType(value any) string {
	switch value := value.(type) {
	case nil:
		return "NoneType"
	case string:
		return "str"
	case bool:
		return "bool"
	case []any:
		return "list"
	case json.Number:
		if strings.ContainsAny(string(value), ".eE") {
			return "float"
		}
		return "int"
	}
	return "dict"
}

func truthy(value any) bool {
	switch value := value.(type) {
	case nil:
		return false
	case bool:
		return value
	case string:
		return value != ""
	case json.Number:
		number, err := value.Float64()
		return err != nil || number != 0
	case []any:
		return len(value) > 0
	case map[string]any:
		return len(value) > 0
	}
	return true
}

// claudeNetwork, claudeFilesystem and claudeSandbox are Claude's `--settings` sandbox keys.
type claudeNetwork struct {
	AllowedDomains      any      `json:"allowedDomains"`
	StrictAllowlist     bool     `json:"strictAllowlist,omitempty"`
	AllowUnixSockets    []string `json:"allowUnixSockets,omitempty"`
	AllowAllUnixSockets bool     `json:"allowAllUnixSockets"`
	AllowLocalBinding   bool     `json:"allowLocalBinding"`
	AllowMachLookup     []string `json:"allowMachLookup,omitempty"`
}

type claudeFilesystem struct {
	AllowWrite []string `json:"allowWrite"`
	DenyWrite  []string `json:"denyWrite"`
	DenyRead   []string `json:"denyRead,omitempty"`
	AllowRead  []string `json:"allowRead,omitempty"`
}

type claudeSandbox struct {
	Enabled                  bool             `json:"enabled"`
	FailIfUnavailable        bool             `json:"failIfUnavailable"`
	AllowUnsandboxedCommands bool             `json:"allowUnsandboxedCommands"`
	ExcludedCommands         []string         `json:"excludedCommands"`
	Filesystem               claudeFilesystem `json:"filesystem"`
	Network                  claudeNetwork    `json:"network"`
	// AllowPty lets sandboxed commands open pseudo-terminals (/dev/ptmx); Claude honours it on macOS only.
	AllowPty bool `json:"allowPty,omitempty"`
}

type claudePermissions struct {
	Deny []string `json:"deny"`
}

type claudeSettings struct {
	Sandbox     claudeSandbox      `json:"sandbox"`
	Permissions *claudePermissions `json:"permissions,omitempty"`
}

// claudeRepositorySettings is the native sandbox for a dedicated repository plus its private temp.
// The Runtime home and the Code token with its directory are denied to Bash reads and writes and to
// the file tools' Read rules. Claude's denies win over its allows, so a home containing the repository
// (a managed one) is denied to Bash reads only, with the repository re-allowed there; Bash writes stay
// limited to allowWrite and --restricted confines the file tools to the repository.
func claudeRepositorySettings(scope any, temporary, home string) (string, error) {
	fields, _ := scope.(map[string]any)
	root, ok := fields["root"].(string)
	if !ok {
		return "", errors.New("Dedicated repository scope requires a root path")
	}
	root = filepath.Clean(root)
	deny, err := claudeTemporaryRoots(root, temporary, "Claude dedicated repositories")
	if err != nil {
		return "", err
	}
	for _, name := range []string{".agents", ".codex", ".aws", ".claude", ".git/config", ".git/hooks"} {
		deny = append(deny, filepath.Join(root, name))
	}
	denied, err := runtimeEntries(home, root)
	if err != nil {
		return "", err
	}
	var denyRead, allowRead, rules []string
	for _, entry := range denied {
		denyRead = append(denyRead, entry[0])
		if contained := slices.DeleteFunc([]string{root, temporary}, func(path string) bool { return !within(entry[0], path) }); len(contained) > 0 {
			allowRead = append(allowRead, contained...)
			continue
		}
		deny = append(deny, entry[0])
		rules = append(rules, "Read(/"+entry[0]+")") // `//` marks an absolute path in Claude rules.
	}
	settings := claudeSettings{Sandbox: claudeSandbox{true, true, false, []string{},
		claudeFilesystem{AllowWrite: []string{root, temporary}, DenyWrite: deny, DenyRead: denyRead, AllowRead: allowRead},
		claudeNetwork{AllowedDomains: fields["network_hosts"]}, false},
		Permissions: &claudePermissions{rules}}
	if platform == "darwin" {
		settings.Sandbox.Network.AllowMachLookup = []string{"com.apple.trustd.agent"}
	}
	return encodeSettings(settings)
}

// claudeFolderSettings is the native sandbox and file-tool policy of a materialized folder:
// write only the folder and the private temp, deny Bash reads of the user home except the folder,
// the private temp and the homeReadable toolchain paths, read the snapshot record and baseline and, once
// the folder was rebound, the rebind's done marker but not its journal, deny Git metadata, the Runtime home, the Code token and user credentials under user,
// loopback networking only: local binding with an empty strict domain allowlist, and Unix-domain
// sockets only inside the private temp (Claude scopes them on macOS only; Linux still blocks them).
// Read deny rules cover the native Read/Glob/Grep tools; Claude also merges them into the
// sandbox's denyRead, which is listed explicitly for the Bash sandbox as well. Bash may
// read (and so execute) the inspector even inside a denied path. Bash may open pseudo-terminals,
// so tmux panes (the e2e TUIs) run in the worker.
//
// A read-only folder (ReadOnlyFolder, IS-Atlas-20: a job's review) is the same policy with the
// folder frozen: Bash reads it, Git included, but writes only the private temp, where its build
// goes (MIX_BUILD_ROOT, folderEnvironment); a write in the folder is refused by the sandbox.
func claudeFolderSettings(scope map[string]any, temporary, user, inspector string) (string, error) {
	root, _ := scope["root"].(string)
	if ReadOnlyFolder(scope) {
		return claudeWorkerSettings(scope, temporary, user, inspector, nil, []string{root}, true)
	}
	return claudeWorkerSettings(scope, temporary, user, inspector, []string{root}, nil, true)
}

// ReadOnlyFolder reports whether a materialized-folder scope is read-only (`read_only`: true): the
// worker reads the folder and writes only its scratch. The Runtime sets it on a read-only work whose
// folder is a Git checkout (a job's review); it is not part of the folder's own scope
// (workspace.FolderScope), which the host recomputes without it.
func ReadOnlyFolder(scope map[string]any) bool {
	readOnly, _ := scope["read_only"].(bool)
	return readOnly
}

// runtimeWorkName is the name of a Runtime-chosen folder below <home>/workers: "work-" and a
// worker-id-shaped name (the work folder of §3.9 is work-<work_id>, so work-work-<hex>).
var runtimeWorkName = regexp.MustCompile(`\Awork-[a-z][a-z0-9_-]{0,63}\z`)

// runtimeWorkFolder reports whether root is exactly <home>/workers/work-<name>, the one place below the
// Runtime home where a materialized-folder worker may run.
func runtimeWorkFolder(home, root string) bool {
	name := filepath.Base(root)
	return home != "" && root == filepath.Join(home, "workers", name) && runtimeWorkName.MatchString(name)
}

// claudeHomeTopPatterns are the Read-rule patterns (gitignore syntax: `*` stays inside one directory)
// for names directly in the Runtime home that a work folder's file tools are denied even when they are
// created after launch: every dot name (the snapshot store's .record-*/.claim- temps), the atomic
// <name>.tmp temps (mode.json.tmp, availability.json.tmp, policy.json.tmp, …), and every JSON record,
// socket, lock and log. None matches workers, the one home entry on the chain to the folder, so these
// Claude denies (which win over allows) never deny the folder. Claude has no complement pattern, so a
// later top-level name of another shape (a new store directory such as submissions/) is covered only by
// the home's Bash read deny (claudeWorkerSettings) and, for the file tools, by --restricted.
var claudeHomeTopPatterns = []string{".*", "*.tmp", "*.json", "*.sock", "*.lock", "*.log"}

// claudeHomeTopRules are the claudeHomeTopPatterns of home as Read rules.
func claudeHomeTopRules(home string) []string {
	var rules []string
	for _, pattern := range claudeHomeTopPatterns {
		rules = append(rules, "Read(/"+filepath.Join(home, pattern)+")")
	}
	return rules
}

// workerHomeNames are the Runtime home entries a worker in a Runtime-chosen folder is denied by path,
// even when they are absent at launch: the workFolderHomeNames of the Codex profiles (the
// sensitiveHomeNames, the frozen results, the bases and the work store).
var workerHomeNames = workFolderHomeNames

// claudeWorkerSettings is the policy described at claudeFolderSettings with writable as the written
// project paths, frozen as project paths that are read but never written, and pty whether Bash may
// open pseudo-terminals. A root that is exactly <home>/workers/work-<name> lies below the Runtime home:
// as in claudeRepositorySettings, the home is then denied to Bash reads only (a denyWrite or Read rule
// on it would deny the folder), and every entry of the home and of <home>/workers off the chain to the
// folder, the workerHomeNames, the sockets and the Code token are denied by path to Bash reads and
// writes and to the file tools. Any other project path inside the home stays refused.
func claudeWorkerSettings(scope map[string]any, temporary, user, inspector string, writable, frozen []string, pty bool) (string, error) {
	root, _ := scope["root"].(string)
	home, _ := scope["home"].(string)
	record, _ := scope["record"].(string)
	baseline, _ := scope["baseline"].(string)
	repositories, _ := scope["repositories"].([]any)
	if root == "" || home == "" || record == "" || baseline == "" || len(repositories) == 0 || inspector == "" {
		return "", errors.New("Materialized folder scope is incomplete")
	}
	// The project paths, written or read, lie outside every system temp root, whose writes Claude denies.
	project := append(slices.Clone(frozen), writable...)
	var roots []string
	var err error
	for _, path := range project {
		if roots, err = claudeTemporaryRoots(path, temporary, "Claude materialized folders"); err != nil {
			return "", err
		}
	}
	if err = writableInspector(inspector, append(slices.Clone(writable), temporary)...); err != nil {
		return "", err
	}
	worker := runtimeWorkFolder(home, root)
	protected := []string{home}
	if worker {
		protected = nil
	}
	sockets, err := socketEntries(home, append(slices.Clone(project), temporary)...)
	if err != nil {
		return "", err
	}
	for _, socket := range sockets {
		protected = append(protected, socket[0])
	}
	// Each other worker existing at launch is denied by path; one created later stays under the home's
	// Bash read deny and outside --restricted.
	protect := func(path string) {
		if !slices.Contains(protected, path) {
			protected = append(protected, path)
		}
	}
	if worker {
		entries, err := offChainEntries(home, root)
		if err != nil {
			return "", err
		}
		for _, name := range workerHomeNames {
			entries = append(entries, [2]string{filepath.Join(home, name), "none"})
		}
		for _, entry := range entries {
			protect(entry[0])
		}
	}
	// A repository's own .git is the agent's: a job's folder is a Git checkout it may stage and commit in
	// (the Runtime commits the result from its own Git directory, never from this one); its configuration
	// and hooks are read-only below.
	protected = append(protected, filepath.Join(root, ".git"))
	token, err := codeToken(home)
	if err != nil {
		return "", err
	}
	if token != "" && worker {
		protect(token)
		protect(filepath.Dir(token))
	} else if token != "" {
		protected = append(protected, token, filepath.Dir(token))
	}
	configuration := os.Getenv("CLAUDE_CONFIG_DIR")
	if configuration == "" {
		configuration = filepath.Join(user, ".claude")
	}
	credentials := []string{configuration}
	for _, name := range credentialPaths {
		credentials = append(credentials, filepath.Join(user, name))
	}
	if codexHome := os.Getenv("CODEX_HOME"); codexHome != "" {
		credentials = append(credentials, codexHome)
	}
	for _, credential := range credentials {
		path, err := resolvePath(credential)
		if err != nil {
			return "", err
		}
		// A credential location that is the home itself (the default ~/.local/state/atlas-runtime) is the
		// home's Bash read deny.
		if worker && path == home {
			continue
		}
		if !slices.Contains(protected, path) {
			protected = append(protected, path)
		}
	}
	// Claude's deny wins over its allow, so a protected path cannot contain a project path or the private temp.
	for _, path := range protected {
		for _, allowed := range append(slices.Clone(project), temporary) {
			if allowed == path || strings.HasPrefix(allowed, path+"/") {
				return "", fmt.Errorf("Protected path %s contains %s", path, allowed)
			}
		}
	}
	// The home denies Bash reads only, and that only around the work folder: no other path below it is allowed.
	denied := protected
	if worker {
		for _, allowed := range append(slices.Clone(project), temporary) {
			if within(home, allowed) && !within(root, allowed) {
				return "", fmt.Errorf("Protected path %s contains %s", home, allowed)
			}
		}
		denied = append(slices.Clone(protected), home)
	}
	// shortcut: absolute paths go into rules unescaped; a path with glob characters or
	// parentheses would need Claude's rule escaping, add it if Runtime homes ever contain them.
	var rules []string
	for _, path := range protected {
		rules = append(rules, "Read(/"+path+")") // `//` marks an absolute path in Claude rules.
	}
	if worker {
		rules = append(rules, claudeHomeTopRules(home)...)
	}
	// The file-editing tools may not touch a frozen path, whatever tools a later Runtime enables.
	for _, tool := range []string{"Edit", "Write"} {
		for _, path := range frozen {
			rules = append(rules, tool+"(/"+path+")")
		}
	}
	// Claude's Bash sources its shell snapshot from the config dir; Claude itself re-opens
	// these two for blockReadsOutsideWorkingDirectories.
	resolved, err := resolvePath(configuration)
	if err != nil {
		return "", err
	}
	allowRead := []string{record, baseline, filepath.Join(resolved, "shell-snapshots"), filepath.Join(resolved, "session-env")}
	readOnly := append(slices.Clone(frozen), record, baseline)
	// Status and diff of a rebound folder need its done marker, which a rebind never removes, and
	// of a prepared folder its minimal result, never the diagnostics beside it.
	for _, file := range []string{snapshot.RebindMarker(home, root), snapshot.PreparationResult(home, root)} {
		if _, err = os.Lstat(file); err == nil {
			allowRead, readOnly = append(allowRead, file), append(readOnly, file)
		} else if !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
	}
	// A repository's own .git is writable with the folder, its configuration and hooks are not
	// (repositoryGitEntries).
	for _, repository := range repositories {
		path, ok := repository.(string)
		if !ok {
			return "", errors.New("Materialized folder scope is incomplete")
		}
		for _, entry := range repositoryGitEntries(root, path) {
			if entry[1] == "read" {
				readOnly = append(readOnly, entry[0])
			}
		}
	}
	// The home is denied to the Bash sandbox only: a Read rule or denyWrite on it would also deny the
	// folder below it. The file tools stay confined to the folder by --restricted. A protected path
	// inside a re-allowed one stays denied: the sandbox re-applies a nested deny after its allows.
	readable, err := homeReadable(user, denied, append(slices.Clone(project), temporary))
	if err != nil {
		return "", err
	}
	allowRead = append(append(append(allowRead, project...), temporary), readable...)
	// The sandbox's allowRead wins over its denyRead; grant only the inspector itself.
	if within(user, inspector) || slices.ContainsFunc(denied, func(path string) bool { return within(path, inspector) }) {
		allowRead = append(allowRead, inspector)
	}
	denyRead := append([]string{user}, protected...)
	if worker {
		denyRead = append([]string{user, home}, protected...)
	}
	settings := claudeSettings{
		Sandbox: claudeSandbox{true, true, false, []string{},
			claudeFilesystem{AllowWrite: append(slices.Clone(writable), temporary),
				DenyWrite: append(append(roots, protected...), readOnly...), DenyRead: denyRead, AllowRead: allowRead},
			claudeNetwork{AllowedDomains: []string{}, StrictAllowlist: true, AllowUnixSockets: []string{temporary},
				AllowLocalBinding: true}, pty},
		Permissions: &claudePermissions{rules},
	}
	return encodeSettings(settings)
}

// claudeTemporaryRoots are the sorted system temp roots whose writes Claude's sandbox denies;
// root must lie outside them and the private temp must fit Claude's child-temp limit.
func claudeTemporaryRoots(root, temporary, subject string) ([]string, error) {
	system, err := temporaryDirectory()
	if err != nil {
		return nil, err
	}
	var roots []string
	for _, path := range []string{"/tmp", "/var/tmp", system} {
		resolved, err := resolvePath(path)
		if err != nil {
			return nil, err
		}
		if !slices.Contains(roots, resolved) {
			roots = append(roots, resolved)
		}
	}
	slices.Sort(roots)
	for _, path := range roots {
		if root == path || strings.HasPrefix(root, strings.TrimSuffix(path, "/")+"/") {
			return nil, errors.New(subject + " must be outside system temporary directories")
		}
	}
	// Claude 2.1.280 redirects longer child-temp paths to shared /tmp/claude-<uid>.
	if len(filepath.Join(temporary, "claude-"+strconv.Itoa(os.Getuid()))) > 44 {
		return nil, errors.New("Claude private native temp path exceeds the 44-byte child-temp limit")
	}
	return roots, nil
}

// claudeReadOnlySettings denies a plain read-only turn's file tools (it has no Bash) the Runtime home
// (for the work folder, every home entry off the chain to it) and the Code token with its directory. A Read rule on a home containing the workspace (resolved
// through symlinks) would also deny the workspace, so there only --restricted, which confines the file
// tools to the workspace, keeps them out of the rest of the home.
func claudeReadOnlySettings(project, home string) (string, error) {
	project, err := resolvePath(project)
	if err != nil {
		return "", err
	}
	// The work folder <home>/workers/work-<work_id> gets the chain and sibling denies (homeEntries) as
	// paths, never the home itself, plus the claudeHomeTopRules for names created later at the home's top
	// level. Claude rules have no complement pattern, so a sibling worker created later stays outside
	// --restricted only.
	denied, err := homeEntries(home, project)
	if err != nil {
		return "", err
	}
	globs, err := siblingWorkerGlobs(home, project)
	if err != nil {
		return "", err
	}
	rules := []string{}
	for _, entry := range denied {
		if !within(entry[0], project) && !slices.Contains(globs, entry) {
			rules = append(rules, "Read(/"+entry[0]+")")
		}
	}
	if workspace.RuntimeWorkFolder(home, project) {
		rules = append(rules, claudeHomeTopRules(home)...)
	}
	return encodeSettings(struct {
		Permissions claudePermissions `json:"permissions"`
	}{claudePermissions{rules}})
}

func encodeSettings(settings any) (string, error) {
	var encoded bytes.Buffer
	encoder := json.NewEncoder(&encoded)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(settings); err != nil {
		return "", err
	}
	return strings.TrimSuffix(encoded.String(), "\n"), nil
}

const temporaryCharacters = "abcdefghijklmnopqrstuvwxyz0123456789_"

// temporaryName is tempfile's eight-character random name; its length is part of the 44-byte budget.
func temporaryName() string {
	name := make([]byte, 8)
	for index := range name {
		name[index] = temporaryCharacters[rand.N(len(temporaryCharacters))]
	}
	return string(name)
}

// temporaryDirectory follows Python's tempfile.gettempdir(): the first candidate
// where a probe file can be created, written and removed.
func temporaryDirectory() (string, error) {
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
	for _, directory := range candidates {
		if directory != "." {
			var err error
			if directory, err = pythonAbsolute(directory); err != nil {
				return "", err
			}
		}
		for range 100 {
			name := filepath.Join(directory, temporaryName())
			file, err := os.OpenFile(name, os.O_RDWR|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0600)
			if errors.Is(err, fs.ErrExist) {
				continue
			}
			if err != nil {
				break
			}
			_, writeErr := file.Write([]byte("blat"))
			closeErr := file.Close()
			if removeErr := os.Remove(name); writeErr == nil && closeErr == nil && removeErr == nil {
				return directory, nil
			}
			break
		}
	}
	quoted := make([]string, len(candidates))
	for index, candidate := range candidates {
		quoted[index] = pythonRepr(candidate)
	}
	return "", errors.New("[Errno 2] No usable temporary directory found in [" + strings.Join(quoted, ", ") + "]")
}

// resolvePath follows Python's non-strict Path.resolve(): symlinks in the existing prefix are resolved.
func resolvePath(path string) (string, error) {
	absolute, err := pythonAbsolute(path)
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

// pythonAbsolute is os.path.abspath: os.getcwd() is the kernel path, unlike os.Getwd's $PWD.
func pythonAbsolute(path string) (string, error) {
	if !filepath.IsAbs(path) {
		cwd, err := syscall.Getwd()
		if err != nil {
			return "", err
		}
		path = filepath.Join(cwd, path)
	}
	return filepath.Clean(path), nil
}

// makeTemporary follows tempfile.mkdtemp(prefix='.ac-', dir=directory): an owner-only new directory.
func makeTemporary(directory string) (string, error) {
	for range 308915776 { // os.TMP_MAX
		path := filepath.Join(directory, ".ac-"+temporaryName())
		err := os.Mkdir(path, 0700)
		if errors.Is(err, fs.ErrExist) {
			continue
		}
		return path, err
	}
	return "", errors.New("[Errno 17] No usable temporary directory name found")
}

// saveContext records the working directory, repository identity and permission scope,
// refusing a continuation whose saved context drifted; it never writes on failure.
// A materialized folder runs no Git: its verified scope is its whole identity.
func saveContext(workspacePath string, scope any, folder string, expected any) error {
	actual := map[string]any{"cwd": workspacePath, "git": nil}
	if fields, _ := scope.(map[string]any); fields["profile"] != "materialized-folder" {
		var err error
		if actual, err = workspace.Context(workspacePath); err != nil {
			return err
		}
	}
	actual["permissions"] = scope
	encoded, err := json.Marshal(actual)
	if err != nil {
		return err
	}
	saved, err := argument(string(encoded))
	if err != nil {
		return err
	}
	if expected != nil && !workspace.JSONEqual(saved, expected) {
		return errors.New("Saved Claude working directory, repository identity or permission scope changed")
	}
	return os.WriteFile(filepath.Join(folder, "claude-context.json"), encoded, 0666)
}
