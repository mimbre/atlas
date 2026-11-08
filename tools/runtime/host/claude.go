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

	"github.com/eyra/atlas/tools/runtime/workspace"
)

var canonicalUUID = regexp.MustCompile(`\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z`)

// platform is replaced in tests to cover the macOS-only trust service allowance.
var platform = runtime.GOOS

// claudeValidate keeps the Python check order, including uuid.UUID's own parse errors.
func claudeValidate(scope any, sandbox, session string, model, expectedContext any) error {
	if scope == nil && sandbox != "read-only" {
		return errors.New("Claude requires read-only, dedicated-repository or materialized-folder execution")
	}
	if fields, _ := scope.(map[string]any); scope != nil && fields["profile"] != "dedicated-repository" && fields["profile"] != "materialized-folder" {
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
}

type claudePermissions struct {
	Deny []string `json:"deny"`
}

type claudeSettings struct {
	Sandbox     claudeSandbox      `json:"sandbox"`
	Permissions *claudePermissions `json:"permissions,omitempty"`
}

// claudeRepositorySettings is the native sandbox for a dedicated repository plus its private temp.
func claudeRepositorySettings(scope any, temporary string) (string, error) {
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
	settings := claudeSettings{Sandbox: claudeSandbox{true, true, false, []string{},
		claudeFilesystem{AllowWrite: []string{root, temporary}, DenyWrite: deny},
		claudeNetwork{AllowedDomains: fields["network_hosts"]}}}
	if platform == "darwin" {
		settings.Sandbox.Network.AllowMachLookup = []string{"com.apple.trustd.agent"}
	}
	return encodeSettings(settings)
}

// claudeFolderSettings is the native sandbox and file-tool policy of a materialized folder:
// write only the folder and the private temp, read the snapshot record and baseline, deny
// Git metadata, the Runtime home, the Code token and user credentials under user, no network.
// Read deny rules cover the native Read/Glob/Grep tools; Claude also merges them into the
// sandbox's denyRead, which is listed explicitly for the Bash sandbox as well. Bash may
// read (and so execute) the inspector even inside a denied path.
func claudeFolderSettings(scope map[string]any, temporary, user, inspector string) (string, error) {
	root, _ := scope["root"].(string)
	home, _ := scope["home"].(string)
	record, _ := scope["record"].(string)
	baseline, _ := scope["baseline"].(string)
	repositories, _ := scope["repositories"].([]any)
	if root == "" || home == "" || record == "" || baseline == "" || len(repositories) == 0 || inspector == "" {
		return "", errors.New("Materialized folder scope is incomplete")
	}
	roots, err := claudeTemporaryRoots(root, temporary, "Claude materialized folders")
	if err != nil {
		return "", err
	}
	if err = writableInspector(inspector, root, temporary); err != nil {
		return "", err
	}
	protected := []string{home, filepath.Join(root, ".git")}
	for _, repository := range repositories {
		path, ok := repository.(string)
		if !ok {
			return "", errors.New("Materialized folder scope is incomplete")
		}
		protected = append(protected, filepath.Join(root, path, ".git"))
	}
	token, err := codeToken(home)
	if err != nil {
		return "", err
	}
	if token != "" {
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
		if !slices.Contains(protected, path) {
			protected = append(protected, path)
		}
	}
	// Claude's deny wins over its allow, so a protected path cannot contain a writable one.
	for _, path := range protected {
		for _, writable := range []string{root, temporary} {
			if writable == path || strings.HasPrefix(writable, path+"/") {
				return "", fmt.Errorf("Protected path %s contains %s", path, writable)
			}
		}
	}
	// shortcut: absolute paths go into rules unescaped; a path with glob characters or
	// parentheses would need Claude's rule escaping, add it if Runtime homes ever contain them.
	rules := make([]string, len(protected))
	for index, path := range protected {
		rules[index] = "Read(/" + path + ")" // `//` marks an absolute path in Claude rules.
	}
	// Claude's Bash sources its shell snapshot from the config dir; Claude itself re-opens
	// these two for blockReadsOutsideWorkingDirectories.
	resolved, err := resolvePath(configuration)
	if err != nil {
		return "", err
	}
	allowRead := []string{record, baseline, filepath.Join(resolved, "shell-snapshots"), filepath.Join(resolved, "session-env")}
	// The sandbox's allowRead wins over its denyRead; grant only the inspector itself.
	if slices.ContainsFunc(protected, func(path string) bool { return within(path, inspector) }) {
		allowRead = append(allowRead, inspector)
	}
	settings := claudeSettings{
		Sandbox: claudeSandbox{true, true, false, []string{},
			claudeFilesystem{AllowWrite: []string{root, temporary},
				DenyWrite: append(append(roots, protected...), record, baseline), DenyRead: protected, AllowRead: allowRead},
			claudeNetwork{AllowedDomains: []string{}, StrictAllowlist: true}},
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

func encodeSettings(settings claudeSettings) (string, error) {
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
