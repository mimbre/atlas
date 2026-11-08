package host

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eyra/atlas/tools/runtime/workspace"
)

const claudeSession = "a1a1b578-c3b5-7972-9664-1d250bf64cdf"

// claudeArgs is the Native argv for a read-only Claude start without questions; tests override positions.
func claudeArgs(native, directory string) []string {
	return []string{native, directory, directory, "fixture goal", "read-only", "", "null", "null", "claude", "null", "null", "false"}
}

func encode(t *testing.T, value any) string {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// savedContext is what a previous start saved for this workspace and scope.
func savedContext(t *testing.T, directory string, scope any) any {
	t.Helper()
	context, err := workspace.Context(directory)
	if err != nil {
		t.Fatal(err)
	}
	context["permissions"] = scope
	value, err := argument(encode(t, context))
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func TestClaudeValidationKeepsPythonOrderAndMessages(t *testing.T) {
	context := `{"cwd":"/w","git":null,"permissions":null}`
	for _, test := range []struct {
		name    string
		change  map[int]string
		message string
	}{
		{"boolean opt-in precedes model", map[int]string{9: `""`, 11: "1"}, "Questions require a boolean opt-in and the Claude backend"},
		{"model precedes backend", map[int]string{8: "other", 9: `"--x"`}, "Model must be a nonempty identifier of at most 200 characters"},
		{"unknown backend", map[int]string{8: "other"}, "Backend must be codex or claude"},
		{"questions stay on Python", map[int]string{4: "workspace-write", 11: "true"}, "Claude questions are not supported by native-host"},
		{"write needs a scope", map[int]string{4: "workspace-write"}, "Claude requires read-only or dedicated-repository execution"},
		{"unparsable session", map[int]string{5: "not-a-uuid"}, "badly formed hexadecimal UUID string"},
		{"non-hex session", map[int]string{5: strings.Repeat("z", 32)}, "invalid literal for int() with base 16: '" + strings.Repeat("z", 32) + "'"},
		{"non-canonical session", map[int]string{5: strings.ToUpper(claudeSession), 9: `"m"`, 10: context}, "Claude resume requires a confirmed UUID, model and saved execution context"},
		{"resume without model", map[int]string{5: claudeSession, 10: context}, "Claude resume requires a confirmed UUID, model and saved execution context"},
		{"resume without context", map[int]string{5: claudeSession, 9: `"m"`}, "Claude resume requires a confirmed UUID, model and saved execution context"},
		{"scope conflicts with sandbox", map[int]string{6: `{"root":"/r"}`}, "Dedicated repository permissions conflict with sandbox"},
	} {
		t.Run(test.name, func(t *testing.T) {
			directory := t.TempDir()
			args := claudeArgs(filepath.Join(directory, "native"), directory)
			for position, value := range test.change {
				args[position] = value
			}
			if err := run(args); err == nil || err.Error() != test.message {
				t.Fatalf("wanted %q, got %v", test.message, err)
			}
			if _, err := os.Stat(filepath.Join(directory, "stderr.log")); err == nil {
				t.Fatal("validation must precede every artifact")
			}
		})
	}
}

func TestClaudeConfirmationRefusesBeforeForwarding(t *testing.T) {
	for _, test := range []struct {
		name, model, events, message string
		forwarded                    int
		hang                         bool
	}{
		{"wrong session", "claude-opus-5-5[1m]", `{"type":"system","subtype":"init","session_id":"other","model":"claude-opus-5-5[1m]"}`,
			"Claude did not confirm the requested session and model", 0, true},
		{"wrong init model", "claude-opus-5-5[1m]", `{"type":"system","subtype":"init","session_id":"` + claudeSession + `","model":"claude-opus-5-5"}`,
			"Claude did not confirm the requested session and model", 0, true},
		{"different assistant model", "claude-opus-5-5[1m]", `{"type":"system","subtype":"init","session_id":"` + claudeSession + `","model":"claude-opus-5-5[1m]"}
{"type":"assistant","message":{"model":"claude-sonnet-5-5"}}`, "Claude resumed with a different model", 1, true},
		{"unconfirmed resume", "m", `{"type":"result","result":"done"}`, "Claude resume ended without confirming its session", 1, false},
		{"confirmed resume", "claude-opus-5-5[1m]", `{"type":"system","subtype":"init","session_id":"` + claudeSession + `","model":"claude-opus-5-5[1m]"}
{"type":"assistant","message":{"model":"claude-opus-5-5"}}
{"type":"assistant","message":{"model":"<synthetic>"}}
{"type":"result","result":"done"}`, "", 4, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			directory := t.TempDir()
			// The context must be saved before the native CLI runs; refusals must not wait for it.
			body := "test -f claude-context.json || exit 9\ncat <<'EVENTS'\n" + test.events + "\nEVENTS\n"
			if test.hang {
				body += "sleep 60\n"
			}
			native := fixture(t, directory, body)
			args := claudeArgs(native, directory)
			args[5], args[9], args[10] = claudeSession, encode(t, test.model), encode(t, savedContext(t, directory, nil))
			started := time.Now()
			host := startHost(t, args)
			records, code := host.finish(t)
			if elapsed := time.Since(started); elapsed > 5*time.Second {
				t.Fatalf("refusal waited for the native process: %v", elapsed)
			}
			kinds := types(records)
			if test.message == "" {
				if code != 0 || len(kinds) != 6 || kinds[5] != "runtime.process_ended" || records[5]["exit_code"] != 0.0 {
					t.Fatalf("confirmed resume failed: code=%d records=%v stderr=%s", code, records, host.stderr.String())
				}
				return
			}
			want := []string{"runtime.process_started"}
			for range test.forwarded {
				want = append(want, "runtime.event")
			}
			if code != 1 || !slices.Equal(kinds, want) || host.stderr.String() != "Native runner: "+test.message+"\n" {
				t.Fatalf("code=%d records=%v stderr=%q", code, records, host.stderr.String())
			}
		})
	}
}

func TestClaudeStartReportsLaunchWithoutCodexEvidence(t *testing.T) {
	directory := t.TempDir()
	native := fixture(t, directory, `printf '%s\n' "$*" > "$0.argv"
pwd -P > "$0.cwd"
printf '%s\n' '{"type":"result","result":"done"}'
`)
	args := claudeArgs(native, directory)
	args[9] = `"claude-sonnet-4-6"`
	host := startHost(t, args)
	records, code := host.finish(t)
	if code != 0 || !slices.Equal(types(records), []string{"runtime.process_started", "runtime.event", "runtime.process_ended"}) {
		t.Fatalf("code=%d records=%v stderr=%s", code, records, host.stderr.String())
	}
	if _, present := records[0]["codex_home"]; present || records[0]["workspace"] != nil {
		t.Fatalf("Claude launch must not report Codex evidence: %v", records[0])
	}
	argv, _ := os.ReadFile(native + ".argv")
	want := "--print --output-format stream-json --verbose --restricted --safe-mode --strict-mcp-config --no-chrome " +
		"--tools Read,Glob,Grep --allowedTools Read,Glob,Grep --permission-mode dontAsk --permission-prompts none " +
		"--model claude-sonnet-4-6 -- fixture goal\n"
	if string(argv) != want {
		t.Fatalf("argv %q", argv)
	}
	resolved, _ := filepath.EvalSymlinks(directory)
	if cwd, _ := os.ReadFile(native + ".cwd"); string(cwd) != resolved+"\n" {
		t.Fatalf("native must run in the workspace: %q", cwd)
	}
	var evidence map[string]any
	data, _ := os.ReadFile(filepath.Join(directory, "process.json"))
	if json.Unmarshal(data, &evidence) != nil || evidence["native_temporary"] != nil {
		t.Fatalf("read-only process evidence %s", data)
	}
}

func testScope(root string) map[string]any {
	return map[string]any{"root": root, "network_hosts": []any{"github.com", "api.github.com"}}
}

func TestClaudeSettingsTempByteLimitAndTrustService(t *testing.T) {
	root := "/atlas-host-test/repo"
	suffix := len("/claude-" + strconv.Itoa(os.Getuid()))
	limit := "/" + strings.Repeat("x", 44-suffix-1)
	encoded, err := claudeRepositorySettings(testScope(root), limit)
	if err != nil {
		t.Fatalf("exactly 44 bytes refused: %v", err)
	}
	for _, temporary := range []string{limit + "x", "/" + strings.Repeat("é", 22)} {
		if _, err := claudeRepositorySettings(testScope(root), temporary); err == nil ||
			err.Error() != "Claude private native temp path exceeds the 44-byte child-temp limit" {
			t.Fatalf("%q: wanted the 44-byte refusal, got %v", temporary, err)
		}
	}
	var settings struct {
		Sandbox struct {
			Filesystem struct{ AllowWrite, DenyWrite []string }
			Network    map[string]any
		}
	}
	if err = json.Unmarshal([]byte(encoded), &settings); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(settings.Sandbox.Filesystem.AllowWrite, []string{root, limit}) {
		t.Fatalf("allowWrite %v", settings.Sandbox.Filesystem.AllowWrite)
	}
	deny := settings.Sandbox.Filesystem.DenyWrite
	protected := []string{root + "/.agents", root + "/.codex", root + "/.aws", root + "/.claude", root + "/.git/config", root + "/.git/hooks"}
	tmp, _ := resolvePath("/tmp")
	if len(deny) <= len(protected) || !slices.Equal(deny[len(deny)-len(protected):], protected) ||
		!slices.Contains(deny, tmp) || !slices.IsSorted(deny[:len(deny)-len(protected)]) {
		t.Fatalf("denyWrite %v", deny)
	}
	if !strings.HasPrefix(encoded, `{"sandbox":{"enabled":true,"failIfUnavailable":true,"allowUnsandboxedCommands":false,"excludedCommands":[],"filesystem":{"allowWrite":`) {
		t.Fatalf("settings order %s", encoded)
	}
	for _, name := range []string{"darwin", "linux"} {
		previous := platform
		platform = name
		encoded, err := claudeRepositorySettings(testScope(root), limit)
		platform = previous
		if err != nil {
			t.Fatal(err)
		}
		lookup := strings.Contains(encoded, `,"allowMachLookup":["com.apple.trustd.agent"]}}}`)
		if lookup != (name == "darwin") || !strings.Contains(encoded, `"allowedDomains":["github.com","api.github.com"]`) {
			t.Fatalf("%s network %s", name, encoded)
		}
	}
}

func TestClaudeRepositoryInsideSystemTempIsRefused(t *testing.T) {
	custom := t.TempDir()
	t.Setenv("TMPDIR", custom)
	resolved, _ := resolvePath(custom)
	tmp, _ := resolvePath("/tmp")
	for _, root := range []string{filepath.Join(resolved, "repo"), resolved, tmp, filepath.Join(tmp, "a/b")} {
		if _, err := claudeRepositorySettings(testScope(root), "/short"); err == nil ||
			err.Error() != "Claude dedicated repositories must be outside system temporary directories" {
			t.Fatalf("%s: wanted the temp-root refusal, got %v", root, err)
		}
	}
	if _, err := claudeRepositorySettings(testScope(tmp+"-sibling/repo"), "/short"); err != nil {
		t.Fatalf("a path sharing only a name prefix is not inside a temp root: %v", err)
	}
}

func TestTemporaryDirectoryFollowsPythonCandidates(t *testing.T) {
	first, second := t.TempDir(), t.TempDir()
	missing := filepath.Join(first, "missing")
	locked := filepath.Join(first, "locked")
	if err := os.Mkdir(locked, 0500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(locked, 0700) })
	relative := filepath.Join(second, "relative")
	if err := os.Mkdir(relative, 0700); err != nil {
		t.Fatal(err)
	}
	t.Chdir(second)
	// Python's os.getcwd() is the kernel path, with symlinks resolved.
	cwd, _ := filepath.EvalSymlinks(second)
	for _, test := range []struct {
		name, tmpdir, temp, tmp, want string
	}{
		{"TMPDIR first", second, first, "", second},
		{"empty TMPDIR skipped", "", first, second, first},
		{"TEMP before TMP", missing, second, first, second},
		{"missing skipped", missing, "", first, first},
		{"unwritable skipped", locked, "", second, second},
		{"relative made absolute", "relative", "", "", filepath.Join(cwd, "relative")},
		{"platform directory fallback", missing, "", "", "/tmp"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if test.name == "unwritable skipped" && os.Geteuid() == 0 {
				t.Skip("root can write any directory")
			}
			t.Setenv("TMPDIR", test.tmpdir)
			t.Setenv("TEMP", test.temp)
			t.Setenv("TMP", test.tmp)
			directory, err := temporaryDirectory()
			if err != nil || directory != test.want {
				t.Fatalf("wanted %s, got %s %v", test.want, directory, err)
			}
			if directory != "/tmp" {
				entries, _ := os.ReadDir(directory)
				for _, entry := range entries {
					if entry.Name() != "locked" && entry.Name() != "relative" {
						t.Fatalf("probe %s left behind", entry.Name())
					}
				}
			}
		})
	}
}

// claudeRepository is a dedicated repository outside every system temp root, beneath
// the real home whose private temp path fits the 44-byte limit.
func claudeRepository(t *testing.T) (string, string, map[string]any) {
	t.Helper()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	if home, err = filepath.EvalSymlinks(home); err != nil {
		t.Fatal(err)
	}
	if len(home+"/.ac-xxxxxxxx/claude-"+strconv.Itoa(os.Getuid())) > 44 {
		t.Skipf("home %s is too long for a Claude private temp", home)
	}
	root, err := os.MkdirTemp(home, ".atlas-host-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	for _, entry := range os.Environ() {
		if name, _, _ := strings.Cut(entry, "="); strings.HasPrefix(name, "GIT_") {
			t.Setenv(name, "")
			os.Unsetenv(name)
		}
	}
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_CONFIG_GLOBAL", os.DevNull)
	repository := filepath.Join(root, "repo")
	gitIn(t, root, "init", "-q", repository)
	scope, err := workspace.Scope(repository)
	if err != nil {
		t.Fatal(err)
	}
	return root, repository, scope
}

func claudeScopedArgs(t *testing.T, native, repository, folder string, scope map[string]any) []string {
	args := claudeArgs(native, repository)
	args[2], args[4], args[6] = folder, "", encode(t, scope)
	return args
}

func TestClaudePrivateTempIsRemovedAfterReap(t *testing.T) {
	root, repository, scope := claudeRepository(t)
	home, _ := filepath.EvalSymlinks(os.Getenv("HOME"))
	for _, mode := range []string{"exit", "fail", "stop"} {
		t.Run(mode, func(t *testing.T) {
			folder := t.TempDir()
			native := fixture(t, folder, `temporary="$CLAUDE_CODE_TMPDIR"
while [ "$1" != --settings ]; do shift; done
printf '%s\n' "$temporary" "$2" "$(pwd -P)" > "$0.capture"
sleep 60 </dev/null >/dev/null 2>&1 &
echo $! > "$0.child"
printf '%s\n' '{"type":"ready"}'
case "`+mode+`" in fail) exit 7 ;; stop) exec sleep 60 ;; esac
`)
			host := startHost(t, claudeScopedArgs(t, native, repository, folder, scope))
			host.record(t)
			if event := host.record(t); event["type"] != "runtime.event" {
				t.Fatalf("native event not forwarded: %v", event)
			}
			capture, err := os.ReadFile(native + ".capture")
			if err != nil {
				t.Fatal(err)
			}
			lines := strings.SplitN(strings.TrimSuffix(string(capture), "\n"), "\n", 3)
			temporary := lines[0]
			if filepath.Dir(temporary) != home || !strings.HasPrefix(filepath.Base(temporary), ".ac-") ||
				len(filepath.Base(temporary)) != 12 || lines[2] != repository {
				t.Fatalf("private temp %q cwd %q", temporary, lines[2])
			}
			var settings struct {
				Sandbox struct{ Filesystem struct{ AllowWrite []string } }
			}
			if json.Unmarshal([]byte(lines[1]), &settings) != nil ||
				!slices.Equal(settings.Sandbox.Filesystem.AllowWrite, []string{repository, temporary}) {
				t.Fatalf("settings %s", lines[1])
			}
			var evidence struct {
				NativeTemporary string `json:"native_temporary"`
			}
			data, _ := os.ReadFile(filepath.Join(folder, "process.json"))
			if json.Unmarshal(data, &evidence) != nil || evidence.NativeTemporary != temporary {
				t.Fatalf("process evidence %s", data)
			}
			if mode == "stop" {
				if info, err := os.Stat(temporary); err != nil || info.Mode().Perm() != 0700 {
					t.Fatalf("private temp must be an owner-only directory: %v %v", info, err)
				}
				host.stdin.Write([]byte("stop\n"))
			}
			records, code := host.finish(t)
			ended := records[len(records)-1]
			if code != 0 || ended["type"] != "runtime.process_ended" || ended["exit_code"] != map[string]float64{"exit": 0, "fail": 7, "stop": -2}[mode] {
				t.Fatalf("code=%d records=%v stderr=%s", code, records, host.stderr.String())
			}
			assertDead(t, readPID(t, native+".child"))
			if _, err := os.Stat(temporary); !os.IsNotExist(err) {
				t.Fatalf("private temp survived the reaped group: %v", err)
			}
			lock, _, err := workspace.Lock(repository, false)
			if err != nil {
				t.Fatalf("lock not released: %v", err)
			}
			lock.Close()
		})
	}
	if entries, _ := filepath.Glob(filepath.Join(root, ".ac-*")); len(entries) != 0 {
		t.Fatalf("private temps left: %v", entries)
	}
}

func TestClaudeLongHomeRefusesAndRemovesCreatedTemp(t *testing.T) {
	root, repository, scope := claudeRepository(t)
	// The user's Codex home stays the Codex home, not a project config above the repository.
	if _, present := os.LookupEnv("CODEX_HOME"); !present {
		t.Setenv("CODEX_HOME", filepath.Join(os.Getenv("HOME"), ".codex"))
	}
	t.Setenv("HOME", root)
	folder := t.TempDir()
	native := fixture(t, folder, "touch \"$0.executed\"\n")
	host := startHost(t, claudeScopedArgs(t, native, repository, folder, scope))
	records, code := host.finish(t)
	if code != 1 || len(records) != 0 ||
		host.stderr.String() != "Native runner: Claude private native temp path exceeds the 44-byte child-temp limit\n" {
		t.Fatalf("code=%d records=%v stderr=%q", code, records, host.stderr.String())
	}
	if entries, _ := filepath.Glob(filepath.Join(root, ".ac-*")); len(entries) != 0 {
		t.Fatalf("created private temp not removed: %v", entries)
	}
	if _, err := os.Stat(native + ".executed"); err == nil {
		t.Fatal("native CLI executed despite the refusal")
	}
	lock, _, err := workspace.Lock(repository, false)
	if err != nil {
		t.Fatalf("lock not released: %v", err)
	}
	lock.Close()
}

func TestSaveContextMatchesDriftAndNeverWritesOnFailure(t *testing.T) {
	repository, scope := dedicatedRepository(t)
	decoded, err := argument(encode(t, scope))
	if err != nil {
		t.Fatal(err)
	}
	folder := t.TempDir()
	path := filepath.Join(folder, "claude-context.json")
	if err = saveContext(repository, decoded, folder, nil); err != nil {
		t.Fatal(err)
	}
	saved, _ := os.ReadFile(path)
	expected, err := argument(string(saved))
	if err != nil {
		t.Fatal(err)
	}
	fields := expected.(map[string]any)
	if len(fields) != 3 || fields["cwd"] != repository || !workspace.JSONEqual(fields["permissions"], decoded) ||
		fields["git"].(map[string]any)["root"] != repository {
		t.Fatalf("saved context %s", saved)
	}
	if err = saveContext(repository, decoded, folder, expected); err != nil {
		t.Fatalf("matching context refused: %v", err)
	}

	for _, drift := range []struct {
		name  string
		scope any
		git   []string
	}{
		{"scope", nil, nil},
		{"origin", decoded, []string{"remote", "add", "origin", "https://github.com/other/repo.git"}},
		{"branch", decoded, []string{"symbolic-ref", "HEAD", "refs/heads/other"}},
	} {
		if drift.git != nil {
			gitIn(t, repository, drift.git...)
		}
		err := saveContext(repository, drift.scope, folder, expected)
		if err == nil || err.Error() != "Saved Claude working directory, repository identity or permission scope changed" {
			t.Fatalf("%s drift: %v", drift.name, err)
		}
		if after, _ := os.ReadFile(path); !bytes.Equal(after, saved) {
			t.Fatalf("%s drift rewrote the saved context", drift.name)
		}
	}

	if err = os.WriteFile(filepath.Join(repository, ".git/config"), []byte("invalid git configuration\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, previous := range []any{expected, nil} {
		if previous == nil {
			os.Remove(path)
		}
		if err := saveContext(repository, nil, folder, previous); err == nil || err.Error() != "Cannot inspect Claude working directory" {
			t.Fatalf("failed discovery: %v", err)
		}
		after, readErr := os.ReadFile(path)
		if previous == nil && readErr == nil || previous != nil && !bytes.Equal(after, saved) {
			t.Fatalf("failed discovery wrote the context: %q %v", after, readErr)
		}
	}
}

func TestClaudeManagedPreparationRequiresInstalledCodexSandbox(t *testing.T) {
	repository, scope := dedicatedRepository(t)
	head := gitIn(t, repository, "symbolic-ref", "HEAD")
	folder := t.TempDir()
	path := os.Getenv("PATH")
	t.Setenv("PATH", t.TempDir())
	err := executeAssignment([]string{"claude", repository, encode(t, scope),
		`{"version":1,"url":"https://github.com/test/fixture.git","branch":"task/first"}`, "false", folder, "null", "/missing-claude"})
	os.Setenv("PATH", path)
	if err == nil || err.Error() != "Managed repository preparation requires the installed Codex sandbox" {
		t.Fatalf("wanted the Codex sandbox refusal, got %v", err)
	}
	if gitIn(t, repository, "symbolic-ref", "HEAD") != head {
		t.Fatal("refused preparation changed the repository")
	}
	if _, err = os.Stat(filepath.Join(folder, "claude-context.json")); err == nil {
		t.Fatal("refused preparation saved a context")
	}
}
