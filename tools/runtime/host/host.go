// Package host owns one native Codex CLI process group for the Elixir Runtime:
// launch, synchronous session confirmation, stdin stop control and cleanup.
package host

import (
	"bytes"
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
	scope, repository, model, questions := values[0], values[1], values[2], values[4]
	if enabled, ok := questions.(bool); !ok || (enabled && backend != "claude") {
		return errors.New("Questions require a boolean opt-in and the Claude backend")
	}
	modelName, _ := model.(string)
	if model != nil && !modelPattern.MatchString(modelName) {
		return errors.New("Model must be a nonempty identifier of at most 200 characters")
	}
	if backend != "codex" {
		return errors.New("Backend must be codex")
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
	permissions := []string{"--sandbox", sandbox}
	if scope != nil {
		if sandbox != "" {
			return errors.New("Dedicated repository permissions conflict with sandbox")
		}
		if permissions, err = permissionArguments(scope); err != nil {
			return err
		}
	}
	command := codexCommand(executable, workspacePath, folder, goal, permissions, session, modelName)
	protocol := codexProtocol{session: session}

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
	groupKilled := false
	defer func() {
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
	if scope != nil {
		self, err := os.Executable()
		if err != nil {
			return err
		}
		command = append([]string{self, "native-host", "--execute-assignment", workspacePath,
			args[6], args[7], strconv.FormatBool(created)}, command...)
	}

	reader, writer, err := os.Pipe()
	if err != nil {
		return err
	}
	child := exec.Command(command[0], command[1:]...)
	child.Stdout, child.Stderr = writer, errorsFile
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	startedAt := time.Now()
	err = child.Start()
	writer.Close()
	if err != nil {
		return err
	}
	leader = &process{pid: child.Process.Pid}
	evidence, err := json.Marshal(struct {
		PID             int      `json:"pid"`
		Command         []string `json:"command"`
		NativeTemporary *string  `json:"native_temporary"`
	}{leader.pid, command, nil})
	if err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(folder, "process.json"), evidence, 0666); err != nil {
		return err
	}
	// The Codex child inherits this environment; Runtime reads its rollout evidence.
	codexHome, present := os.LookupEnv("CODEX_HOME")
	if !present {
		home, err := homeDirectory()
		if err != nil {
			return err
		}
		codexHome = filepath.Join(home, ".codex")
	}
	if err = emit(map[string]any{
		"type": "runtime.process_started", "pid": leader.pid,
		"started_at": startedAt.UTC().Format("2006-01-02T15:04:05.000000-07:00"),
		"workspace":  workspacePath, "codex_home": codexHome,
	}); err != nil {
		return err
	}

	// Readers only move bytes; this goroutine owns every state transition.
	type chunk struct {
		data []byte
		err  error
	}
	outputs := make(chan chunk)
	go func() {
		for {
			buffer := make([]byte, 65536)
			n, err := reader.Read(buffer)
			outputs <- chunk{buffer[:n], err}
			if err != nil {
				return
			}
		}
	}()
	control := make(chan error, 1)
	go func() {
		_, err := os.Stdin.Read(make([]byte, 4096))
		control <- err
	}()

	stopped := false
	parse := func(line []byte) error {
		record, err := jsonRecord(line, recordLimit)
		if err != nil || stopped {
			return err
		}
		if err = protocol.event(record); err != nil {
			return err
		}
		if record["type"] == "runtime.repository_prepared" {
			return emitRaw("", line, "")
		}
		return emitRaw(`{"type":"runtime.event","event":`, line, "}")
	}
	var deadline <-chan time.Time
	var partial []byte
	for outputs != nil {
		select {
		case err = <-control:
			// Codex has no questions: any control byte or EOF stops the turn.
			control = nil
			if err != nil && err != io.EOF {
				return err
			}
			stopped = true
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
// rechecks the scope and then becomes Codex, so Git and Codex stay in the owned group.
func executeAssignment(args []string) error {
	if len(args) < 5 {
		return errors.New("native-host --execute-assignment requires workspace, scope, repository, created and command")
	}
	workspacePath, command := args[0], args[4:]
	var values [3]any // scope, repository, created
	for index := range values {
		var err error
		if values[index], err = argument(args[index+1]); err != nil {
			return err
		}
	}
	scope, _ := values[0].(map[string]any)
	if values[1] != nil {
		repository, _ := values[1].(map[string]any)
		created, _ := values[2].(bool)
		permissions, err := permissionArguments(scope)
		if err != nil {
			return err
		}
		prefix := append(append([]string{command[0], "sandbox", "-P", "atlas_repository", "-C", workspacePath}, permissions...), "--")
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
