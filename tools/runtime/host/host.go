// Package host owns one native Codex or Claude CLI process group for the Elixir Runtime:
// launch, synchronous session confirmation, Claude question transport, stdin control and cleanup.
package host

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/eyra/atlas/tools/runtime/workspace"
)

var modelPattern = regexp.MustCompile(`\A[A-Za-z0-9][A-Za-z0-9._:/\[\]-]{0,199}\z`)

// Main runs `atlas-runtime native-host` and exits. Failures print the Native runner
// diagnostic; in the pre-exec child that stderr is the turn's stderr.log.
func Main(args []string) {
	// A panic still unwinds through run's group cleanup before this diagnostic.
	defer func() {
		if recovered := recover(); recovered != nil {
			fmt.Fprintf(os.Stderr, "Native runner: %v\n", recovered)
			os.Exit(1)
		}
	}()
	var err error
	if len(args) > 0 && args[0] == "--execute-assignment" {
		err = executeAssignment(args[1:])
	} else {
		err = run(args)
	}
	// A closed stdout means the parent disappeared; cleanup has already reaped the group.
	if err != nil && !errors.Is(err, syscall.EPIPE) {
		fmt.Fprintf(os.Stderr, "Native runner: %v\n", err)
		os.Exit(1)
	}
	os.Exit(0)
}

func argument(raw string) (value any, err error) {
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.UseNumber()
	if err = decoder.Decode(&value); err == nil {
		if _, extra := decoder.Token(); extra != io.EOF {
			err = errors.New("Native host argument must be one JSON value")
		}
	}
	return value, err
}

func run(args []string) (err error) {
	if len(args) != 12 {
		return errors.New("native-host requires command, workspace, folder, goal, sandbox, session, scope, repository, backend, model, resume context and questions")
	}
	executable, workspacePath, folder, goal, sandbox, session, backend := args[0], args[1], args[2], args[3], args[4], args[5], args[8]
	var values [5]any // scope, repository, model, resume context, questions
	for index, position := range []int{6, 7, 9, 10, 11} {
		if values[index], err = argument(args[position]); err != nil {
			return err
		}
	}
	scope, repository, model, resumeContext := values[0], values[1], values[2], values[3]
	enabled, ok := values[4].(bool)
	if !ok || (enabled && backend != "claude") {
		return errors.New("Questions require a boolean opt-in and the Claude backend")
	}
	modelName, _ := model.(string)
	if model != nil && !modelPattern.MatchString(modelName) {
		return errors.New("Model must be a nonempty identifier of at most 200 characters")
	}
	if backend != "codex" && backend != "claude" {
		return errors.New("Backend must be codex or claude")
	}
	if backend == "claude" {
		if err = claudeValidate(scope, sandbox, session, model, resumeContext); err != nil {
			return err
		}
	}
	if scope == nil && sandbox != "read-only" && sandbox != "workspace-write" {
		return errors.New("Sandbox must be read-only or workspace-write")
	}
	if repository != nil {
		fields, _ := repository.(map[string]any)
		_, saved := fields["base_sha"]
		if !workspace.JSONEqual(workspace.DedicatedScope(workspacePath), scope) || (session != "") != saved {
			return errors.New("Managed repository context does not match this start or continuation")
		}
	}
	if scope != nil && sandbox != "" {
		return errors.New("Dedicated repository permissions conflict with sandbox")
	}
	var command []string
	var protocol interface {
		event(map[string]any) error
		complete(stopped bool) error
	}
	questionSession := ""
	// A materialized-folder turn needs no pre-exec child: no Git and no repository preparation.
	folderScope, _ := scope.(map[string]any)
	folderProfile := folderScope["profile"] == "materialized-folder"
	runtimeHome, _ := folderScope["home"].(string)
	// Codex workers get an owned scratch under the Runtime home; Claude's is its private temp.
	scratch := ""
	if folderProfile && backend == "codex" {
		scratch = filepath.Join(runtimeHome, "scratch", filepath.Base(folder))
	}
	if backend == "codex" {
		permissions := []string{"--sandbox", sandbox}
		if scope != nil {
			if permissions, err = permissionArguments(scope, scratch); err != nil {
				return err
			}
		}
		command = codexCommand(executable, workspacePath, folder, goal, permissions, session, modelName)
		protocol = &codexProtocol{session: session}
	} else {
		if enabled {
			if questionSession = session; questionSession == "" {
				questionSession = uuidString(uuid4())
			}
		}
		command = claudeCommand(executable, goal, scope, session, modelName, questionSession)
		protocol = &claudeProtocol{session: session, model: modelName}
	}

	// EPIPE on stdout must reach cleanup instead of killing the host; children still get default SIGPIPE.
	signal.Notify(make(chan os.Signal, 1), syscall.SIGPIPE)
	interrupts := make(chan os.Signal, 1)
	if !signal.Ignored(syscall.SIGINT) {
		signal.Notify(interrupts, syscall.SIGINT)
	}

	errorsFile, err := os.Create(filepath.Join(folder, "stderr.log"))
	if err != nil {
		return err
	}
	defer errorsFile.Close()
	output, err := os.Create(filepath.Join(folder, "stream.jsonl"))
	if err != nil {
		return err
	}
	defer output.Close()

	var leader *process
	var lock *os.File
	var nativeTemporary *string
	var questions *questionHost
	groupKilled := false
	defer func() {
		if questions != nil {
			questions.cancel()
		}
		if leader != nil {
			// Signal every descendant once; a second kill can hit orphan zombies on macOS.
			if !groupKilled {
				if killErr := leader.signalGroup(syscall.SIGKILL); killErr != nil {
					err = killErr
					return
				}
			}
			leader.wait(-1)
		}
		if nativeTemporary != nil {
			if removeErr := os.RemoveAll(*nativeTemporary); removeErr != nil {
				err = removeErr
			}
		}
		// Keep ownership until the complete process group has been reaped, including on stop.
		if lock != nil {
			lock.Close()
		}
	}()

	created := false
	if _, statErr := os.Stat(filepath.Join(workspacePath, ".git/atlas-runtime-repository.json")); scope != nil || statErr == nil {
		if lock, created, err = workspace.Lock(workspacePath, repository != nil && session == ""); err != nil {
			errorsFile.WriteString(err.Error())
			return err
		}
	}
	var environment []string
	if folderProfile {
		current, err := workspace.FolderScope(workspacePath, runtimeHome)
		if err == nil && !workspace.JSONEqual(current, scope) {
			err = errors.New("Materialized folder permission scope changed")
		}
		if err == nil && backend == "codex" {
			if err = os.MkdirAll(filepath.Dir(scratch), 0700); err == nil {
				if err = os.Mkdir(scratch, 0700); err == nil {
					nativeTemporary = &scratch
				}
			}
		}
		if err != nil {
			errorsFile.WriteString(err.Error())
			return err
		}
	}
	if scope != nil && backend == "claude" {
		if repository == nil && !folderProfile {
			current, err := workspace.Scope(workspacePath)
			if err != nil {
				return err
			}
			if !workspace.JSONEqual(current, scope) {
				return errors.New("Dedicated repository permission scope changed")
			}
		}
		home, err := homeDirectory()
		if err != nil {
			return err
		}
		if home, err = resolvePath(home); err != nil {
			return err
		}
		temporary, err := makeTemporary(home)
		if err != nil {
			return err
		}
		nativeTemporary = &temporary
		var settings string
		if folderProfile {
			// HOME/scratch/<turn> would exceed Claude's 44-byte child-temp limit.
			scratch = temporary
			settings, err = claudeFolderSettings(folderScope, temporary, home)
		} else {
			settings, err = claudeRepositorySettings(scope, temporary)
		}
		if err != nil {
			return err
		}
		command = slices.Insert(command, 1, "--settings", settings)
		environment = append(os.Environ(), "CLAUDE_CODE_TMPDIR="+temporary)
	}
	if folderProfile {
		self, err := os.Executable()
		if err != nil {
			return err
		}
		if environment == nil {
			environment = os.Environ()
		}
		// Workers inspect their folder with this executable against this home's record and baseline.
		environment = append(environment, "PATH="+filepath.Dir(self)+":"+os.Getenv("PATH"), "ATLAS_RUNTIME_HOME="+runtimeHome)
		for _, cache := range [][2]string{{"TMPDIR", "tmp"}, {"GOCACHE", "go-build"}, {"GOTMPDIR", "go-tmp"},
			{"XDG_CACHE_HOME", "cache"}, {"npm_config_cache", "npm"}} {
			path := filepath.Join(scratch, cache[1])
			if err = os.Mkdir(path, 0700); err != nil {
				return err
			}
			environment = append(environment, cache[0]+"="+path)
		}
		if backend == "claude" {
			if err = saveContext(workspacePath, scope, folder, resumeContext); err != nil {
				errorsFile.WriteString(err.Error())
				return err
			}
		}
	}
	// Outside materialized folders Claude saves its context in the pre-exec child; Codex only needs it for a scope.
	if !folderProfile && (scope != nil || backend == "claude") {
		self, err := os.Executable()
		if err != nil {
			return err
		}
		command = append([]string{self, "native-host", "--execute-assignment", backend, workspacePath,
			args[6], args[7], strconv.FormatBool(created), folder, args[10]}, command...)
	}

	reader, writer, err := os.Pipe()
	if err != nil {
		return err
	}
	child := exec.Command(command[0], command[1:]...)
	child.Stdout, child.Stderr = writer, errorsFile
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if backend == "claude" {
		child.Dir, child.Env = workspacePath, environment
	} else if folderProfile {
		child.Env = environment
	}
	// Question answers go to native stdin through an explicit pipe the loop writes without blocking.
	var nativeInput, stdin *os.File
	if enabled {
		if nativeInput, stdin, err = os.Pipe(); err != nil {
			return err
		}
		child.Stdin = nativeInput
	}
	startedAt := time.Now()
	err = child.Start()
	writer.Close()
	if nativeInput != nil {
		nativeInput.Close()
	}
	if err != nil {
		if stdin != nil {
			stdin.Close()
		}
		return err
	}
	leader = &process{pid: child.Process.Pid}
	evidence, err := json.Marshal(struct {
		PID             int      `json:"pid"`
		Command         []string `json:"command"`
		NativeTemporary *string  `json:"native_temporary"`
	}{leader.pid, command, nativeTemporary})
	if err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(folder, "process.json"), evidence, 0666); err != nil {
		return err
	}
	started := map[string]any{
		"type": "runtime.process_started", "pid": leader.pid,
		"started_at": startedAt.UTC().Format("2006-01-02T15:04:05.000000-07:00"),
	}
	if backend == "codex" {
		// The Codex child inherits this environment; Runtime reads its rollout evidence.
		codexHome, present := os.LookupEnv("CODEX_HOME")
		if !present {
			home, err := homeDirectory()
			if err != nil {
				return err
			}
			codexHome = filepath.Join(home, ".codex")
		}
		started["workspace"], started["codex_home"] = workspacePath, codexHome
	}
	if err = emit(started); err != nil {
		return err
	}
	if enabled {
		resumeModel := ""
		if session != "" {
			resumeModel = modelName
		}
		questions = &questionHost{session: questionSession, goal: goal,
			tools: append(strings.Split(claudeTools(scope), ","), "AskUserQuestion"), resumeModel: resumeModel,
			nativePID: leader.pid, initializeID: "initialize-" + hex.EncodeToString(uuid4()),
			send:  func(record map[string]any) error { return writeNative(stdin, record) },
			close: func() { stdin.Close() }, emit: emit}
		if err = questions.start(); err != nil {
			return err
		}
	}

	// Readers only move bytes; this goroutine owns every state transition.
	type chunk struct {
		data []byte
		err  error
	}
	pump := func(file *os.File, size int, chunks chan<- chunk) {
		for {
			buffer := make([]byte, size)
			n, err := file.Read(buffer)
			chunks <- chunk{buffer[:n], err}
			if err != nil {
				return
			}
		}
	}
	outputs, controls := make(chan chunk), make(chan chunk)
	go pump(reader, 65536, outputs)
	go pump(os.Stdin, 4096, controls)

	stopped := false
	var deadline <-chan time.Time
	parse := func(line []byte) error {
		record, err := jsonRecord(line, recordLimit)
		if err != nil || stopped {
			return err
		}
		// Question checks run before provider confirmation; both precede forwarding.
		if questions != nil && record["type"] != "runtime.repository_prepared" {
			if err = questions.event(record); err != nil {
				return err
			}
			if questions.finished {
				deadline = time.After(3 * time.Second)
			}
			if record["type"] == "control_response" {
				return nil
			}
		}
		if err = protocol.event(record); err != nil {
			return err
		}
		if record["type"] == "runtime.repository_prepared" {
			return emitRaw("", line, "")
		}
		return emitRaw(`{"type":"runtime.event","event":`, line, "}")
	}
	var partial, controlPartial []byte
	for outputs != nil {
		select {
		case read := <-controls:
			if read.err != nil && read.err != io.EOF {
				return read.err
			}
			// EOF always stops; without questions so does any control byte.
			stop := read.err != nil || questions == nil
			if !stop {
				controlPartial = append(controlPartial, read.data...)
				for {
					index := bytes.IndexByte(controlPartial, '\n')
					if index < 0 {
						break
					}
					line := controlPartial[:index]
					controlPartial = controlPartial[index+1:]
					if string(line) == "stop" {
						stop = true
						break
					}
					command, err := jsonRecord(line, 32768)
					if err != nil {
						return err
					}
					if err = questions.answer(command); err != nil {
						return err
					}
				}
				if len(controlPartial) > 32768 {
					return errors.New("Runtime control record exceeds 32 KiB")
				}
			}
			if !stop {
				continue
			}
			controls = nil
			stopped = true
			if questions != nil {
				questions.cancel()
			}
			deadline = time.After(3 * time.Second)
			if err = leader.signalGroup(syscall.SIGINT); err != nil {
				return err
			}
		case read := <-outputs:
			if len(read.data) > 0 {
				if _, err = output.Write(read.data); err != nil {
					return err
				}
				partial = append(partial, read.data...)
				for {
					index := bytes.IndexByte(partial, '\n')
					if index < 0 {
						break
					}
					line := partial[:index]
					partial = partial[index+1:]
					if err = parse(line); err != nil {
						return err
					}
				}
				if len(partial) > recordLimit {
					return errors.New("Native event exceeds 1 MiB")
				}
			}
			if read.err == io.EOF {
				outputs = nil
			} else if read.err != nil {
				return read.err
			}
		case <-deadline:
			if err = leader.signalGroup(syscall.SIGKILL); err != nil {
				return err
			}
			groupKilled = true
			deadline = nil
		case <-interrupts:
			return errors.New("Native host interrupted")
		}
	}
	if len(bytes.Trim(partial, " \t\n\r\v\f")) > 0 {
		if err = parse(partial); err != nil {
			return err
		}
	}
	if questions != nil && !questions.finished && !stopped {
		return errors.New("Native question transport ended before its result")
	}
	// EOF can precede the leader's exit; do not turn a clean exit into SIGKILL.
	exited, err := leader.wait(3 * time.Second)
	if err != nil {
		return err
	}
	if !exited {
		if !groupKilled {
			if err = leader.signalGroup(syscall.SIGKILL); err != nil {
				return err
			}
			groupKilled = true
		}
		if _, err = leader.wait(-1); err != nil {
			return err
		}
	}
	if err = protocol.complete(stopped); err != nil {
		return err
	}
	return emit(map[string]any{"type": "runtime.process_ended", "exit_code": leader.code(), "stopped": stopped})
}

// homeDirectory follows Python's Path.home(): HOME when set, else the passwd entry.
func homeDirectory() (string, error) {
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

// executeAssignment runs as the new group leader: it prepares the managed repository,
// rechecks the scope, saves Claude's context and then becomes the native CLI,
// so Git and the native CLI stay in the owned group.
func executeAssignment(args []string) error {
	if len(args) < 8 {
		return errors.New("native-host --execute-assignment requires backend, workspace, scope, repository, created, folder, resume context and command")
	}
	backend, workspacePath, folder, command := args[0], args[1], args[5], args[7:]
	var values [4]any // scope, repository, created, resume context
	for index, position := range []int{2, 3, 4, 6} {
		var err error
		if values[index], err = argument(args[position]); err != nil {
			return err
		}
	}
	scope, _ := values[0].(map[string]any)
	if values[1] != nil {
		repository, _ := values[1].(map[string]any)
		created, _ := values[2].(bool)
		sandbox := command[0]
		if backend == "claude" {
			// Claude prepares through the installed Codex sandbox, as resolved from PATH.
			var err error
			if sandbox, err = exec.LookPath("codex"); err != nil && !errors.Is(err, exec.ErrDot) {
				return errors.New("Managed repository preparation requires the installed Codex sandbox")
			}
		}
		permissions, err := permissionArguments(scope, "")
		if err != nil {
			return err
		}
		prefix := append(append([]string{sandbox, "sandbox", "-P", "atlas_repository", "-C", workspacePath}, permissions...), "--")
		prepared, err := workspace.Prepare(scope, repository, created, prefix)
		if err != nil {
			return err
		}
		if err = emit(map[string]any{"type": "runtime.repository_prepared", "repository": prepared}); err != nil {
			return err
		}
	}
	if values[0] != nil {
		current, err := workspace.Scope(workspacePath)
		if err != nil {
			return err
		}
		if !workspace.JSONEqual(current, values[0]) {
			return errors.New("Dedicated repository permission scope changed")
		}
	}
	if backend == "claude" {
		if err := saveContext(workspacePath, values[0], folder, values[3]); err != nil {
			return err
		}
	}
	return syscall.Exec(command[0], command, os.Environ())
}

// process is the owned group leader. Like Popen it is reaped once and only on request,
// so the group can be signalled while an exited leader still holds its PID.
type process struct {
	pid    int
	exited bool
	status syscall.WaitStatus
}

// wait reaps the leader within timeout (negative waits forever) and reports whether it exited.
func (leader *process) wait(timeout time.Duration) (bool, error) {
	deadline := time.Now().Add(timeout)
	for !leader.exited {
		options := syscall.WNOHANG
		if timeout < 0 {
			options = 0
		}
		pid, err := syscall.Wait4(leader.pid, &leader.status, options, nil)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return false, err
		}
		if pid == leader.pid {
			leader.exited = true
		} else if time.Now().After(deadline) {
			return false, nil
		} else {
			time.Sleep(10 * time.Millisecond)
		}
	}
	return true, nil
}

// code keeps Python returncode semantics: a negative signal number for signalled exits.
func (leader *process) code() int {
	if leader.status.Signaled() {
		return -int(leader.status.Signal())
	}
	return leader.status.ExitStatus()
}

// kill is replaced in tests to inject a denial without signalling foreign processes.
var kill = syscall.Kill

func (leader *process) signalGroup(sig syscall.Signal) error {
	err := kill(-leader.pid, sig)
	if err == syscall.EPERM {
		// macOS can deny a group signal while its last member is exiting,
		// even before the leader can be reaped. Bound the wait for our own leader,
		// then still signal any surviving descendants in the same group.
		// A live leader or a second denial remains a real permission error.
		if exited, waitErr := leader.wait(3 * time.Second); waitErr != nil || !exited {
			return err
		}
		err = kill(-leader.pid, sig)
	}
	if err == syscall.ESRCH {
		return nil
	}
	return err
}
