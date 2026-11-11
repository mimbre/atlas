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
	// A materialized-folder or review-packet turn needs no pre-exec child: no Git and no repository preparation.
	folderScope, _ := scope.(map[string]any)
	review := folderScope["profile"] == "review-packet"
	folderProfile := folderScope["profile"] == "materialized-folder" || review
	runtimeHome, _ := folderScope["home"].(string)
	// Workers inspect their folder with exactly this host's executable: "$ATLAS_RUNTIME_EXECUTABLE".
	inspector := ""
	if folderProfile {
		if inspector, err = os.Executable(); err == nil {
			inspector, err = filepath.EvalSymlinks(inspector)
		}
		if err != nil {
			return err
		}
	}
	// Codex workers get an owned scratch under the Runtime home; Claude's is its private temp.
	scratch := ""
	if folderProfile && backend == "codex" {
		scratch = filepath.Join(runtimeHome, "scratch", filepath.Base(folder))
	}
	if backend == "codex" {
		permissions := []string{"--sandbox", sandbox}
		if scope != nil {
			if permissions, err = permissionArguments(scope, scratch, inspector); err != nil {
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
	// confirmed means the leader was reaped and no live member remained in its group.
	groupKilled, confirmed := false, false
	defer func() {
		if questions != nil {
			questions.cancel()
		}
		// Failure cleanup only; a confirmed end has nothing left to signal.
		if leader != nil && !confirmed {
			// Signal every descendant once; a second kill can hit orphan zombies on macOS.
			if !groupKilled {
				if killErr := leader.signalGroup(syscall.SIGKILL); killErr != nil {
					err = killErr
					return
				}
			}
			leader.wait(-1)
		}
		// A scratch that cannot be removed is a cleanup warning, never the turn's outcome: it is
		// appended to the turn's stderr.log and the host's stderr, and the exit status stays the turn's.
		if nativeTemporary != nil {
			if removeErr := removeScratch(*nativeTemporary); removeErr != nil {
				warning := "Native runner cleanup warning: " + removeErr.Error() + "\n"
				errorsFile.WriteString(warning)
				os.Stderr.WriteString(warning)
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
		current, changed := workspace.FolderScope, "Materialized folder permission scope changed"
		if review {
			current, changed = workspace.PacketScope, "Review packet permission scope changed"
		}
		recomputed, err := current(workspacePath, runtimeHome)
		if err == nil && !workspace.JSONEqual(recomputed, scope) {
			err = errors.New(changed)
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
			if review {
				settings, err = claudePacketSettings(folderScope, temporary, home, inspector)
			} else {
				settings, err = claudeFolderSettings(folderScope, temporary, home, inspector)
			}
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
		if environment == nil {
			environment = os.Environ()
		}
		// Workers inspect their folder with this executable against this home's record and baseline.
		environment = append(environment, "PATH="+filepath.Dir(inspector)+":"+os.Getenv("PATH"),
			"ATLAS_RUNTIME_HOME="+runtimeHome, "ATLAS_RUNTIME_EXECUTABLE="+inspector)
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

	// control is "" until the first stop, kill or parent loss. Stop interrupts the group once and
	// never escalates; kill wins over stop. Only natural-completion cleanup and parent loss, which
	// leave nobody to send a later kill, may still force the group after their 3 s window.
	control := ""
	interrupted := false
	var deadline, poll <-chan time.Time
	parse := func(line []byte) error {
		// An accepted control ends provider decoding; its bytes stay raw in stream.jsonl.
		if control != "" {
			return nil
		}
		record, err := jsonRecord(line, recordLimit)
		if err != nil {
			return err
		}
		// Question checks run before provider confirmation; both precede forwarding.
		if questions != nil && record["type"] != "runtime.repository_prepared" {
			if err = questions.event(record); err != nil {
				return err
			}
			if questions.finished && deadline == nil {
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
	// deliver signals the owned group for an operator control and reports the outcome; a refused
	// signal leaves the execution running and stays retryable by an explicit repeated control.
	deliver := func(name string, sig syscall.Signal) error {
		failure := leader.signalGroup(sig)
		record := map[string]any{"type": "runtime.signal", "control": name, "signal": map[syscall.Signal]string{
			syscall.SIGINT: "SIGINT", syscall.SIGKILL: "SIGKILL"}[sig], "error": nil}
		if failure != nil {
			record["error"] = failure.Error()
		} else if sig == syscall.SIGKILL {
			groupKilled = true
		} else {
			interrupted = true
		}
		return emit(record)
	}
	var partial, controlPartial []byte
	for !confirmed {
		select {
		case read := <-controls:
			if read.err != nil && read.err != io.EOF {
				return read.err
			}
			if read.err == io.EOF {
				// The owner is gone: nothing can follow this execution or kill it later.
				controls = nil
				if control != "kill" {
					if questions != nil {
						questions.cancel()
					}
					control = "parent_lost"
					if !interrupted {
						if err = leader.signalGroup(syscall.SIGINT); err != nil {
							return err
						}
						interrupted = true
					}
					deadline = time.After(3 * time.Second)
				}
				continue
			}
			controlPartial = append(controlPartial, read.data...)
			for {
				index := bytes.IndexByte(controlPartial, '\n')
				if index < 0 {
					break
				}
				line := controlPartial[:index]
				controlPartial = controlPartial[index+1:]
				switch string(line) {
				case "stop":
					// A repeated stop re-attempts only a refused interrupt; kill already won.
					if control == "" || (control == "stop" && !interrupted) {
						if control == "" && questions != nil {
							questions.cancel()
						}
						control, deadline = "stop", nil
						if err = deliver("stop", syscall.SIGINT); err != nil {
							return err
						}
					}
				case "kill":
					if !groupKilled {
						if control == "" && questions != nil {
							questions.cancel()
						}
						control, deadline = "kill", nil
						if err = deliver("kill", syscall.SIGKILL); err != nil {
							return err
						}
					}
				default:
					if questions == nil {
						return errors.New("Unknown Runtime control")
					}
					command, err := jsonRecord(line, 32768)
					if err != nil {
						return err
					}
					if err = questions.answer(command); err != nil {
						return err
					}
				}
			}
			if len(controlPartial) > 32768 {
				return errors.New("Runtime control record exceeds 32 KiB")
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
				if control != "" {
					partial = nil
				} else if len(partial) > recordLimit {
					return errors.New("Native event exceeds 1 MiB")
				}
			}
			if read.err == io.EOF {
				outputs = nil
				if len(bytes.Trim(partial, " \t\n\r\v\f")) > 0 {
					if err = parse(partial); err != nil {
						return err
					}
				}
				if questions != nil && !questions.finished && control == "" {
					return errors.New("Native question transport ended before its result")
				}
				// EOF can precede the leader's exit; do not turn a clean exit into SIGKILL.
				if control == "" && deadline == nil {
					deadline = time.After(3 * time.Second)
				}
				poll = time.After(0)
			} else if read.err != nil {
				return read.err
			}
		case <-deadline:
			deadline = nil
			if (control == "" || control == "parent_lost") && !groupKilled {
				if err = leader.signalGroup(syscall.SIGKILL); err != nil {
					return err
				}
				groupKilled = true
			}
		case <-poll:
			poll = time.After(20 * time.Millisecond)
			exited, err := leader.wait(0)
			if err != nil {
				return err
			}
			if !exited {
				continue
			}
			// Natural ends and parent loss still remove leftover descendants; a stop waits for them.
			if (control == "" || control == "parent_lost") && !groupKilled {
				if err = leader.signalGroup(syscall.SIGKILL); err != nil {
					return err
				}
				groupKilled = true
			}
			if confirmed, err = groupGone(leader.pid); err != nil {
				return err
			}
		case <-interrupts:
			return errors.New("Native host interrupted")
		}
	}
	if err = protocol.complete(control != ""); err != nil {
		return err
	}
	ended := map[string]any{"type": "runtime.process_ended", "exit_code": leader.code(), "stopped": control != "", "control": nil}
	if control != "" {
		ended["control"] = control
	}
	return emit(ended)
}

// groupGone probes the reaped leader's process group: no remaining member can receive signals.
// Descendants that left the group (setsid/setpgid) are outside this check and Runtime's reach.
func groupGone(pgid int) (bool, error) {
	err := kill(-pgid, 0)
	switch err {
	case syscall.ESRCH:
		return true, nil
	case nil, syscall.EPERM:
		// EPERM: macOS can refuse while the last member is exiting; probe again.
		return false, nil
	}
	return false, err
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
		permissions, err := permissionArguments(scope, "", "")
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
