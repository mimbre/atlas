// pull-stub: the pull-e2e's stand-in programs (Go standard library only; never a model).
//
//	pull-stub session -- CMD ARGS...   run CMD in a new session (Setsid); the first line of its stdout
//	                                   is {"session":<pid>} (the child's pid = its pgid), before anything
//	                                   the child prints; SIGTERM/SIGINT are forwarded to the child's
//	                                   group; it exits with the child's status (128+signal when killed).
//	                                   Tethered: when its own stdin ends (the BEAM that started it is
//	                                   gone, however it ended) it KILLs the child's group and exits
//	pull-stub tether -- CMD ARGS...    the same tether without a new session or a session line (a
//	                                   reader's command: `cat` on a FIFO, `events --follow`, tmux -C).
//	                                   The tether leads a group of its own (its pid = its pgid, the
//	                                   Port's os pid) and CMD stays in it: a KILL of that group ends
//	                                   both, so a KILLed tether can never leave CMD behind
//	pull-stub agent RUN ARGV0 ARGS...  the agent behind the Runtime's `codex` on PATH (pull/README.md):
//	                                   speaks `codex exec --json`, reports to RUN/stub/events.fifo and
//	                                   acts only on the command its gate RUN/stub/gates/<launch> gives;
//	                                   `codex sandbox -P P -C DIR ... -- ARGV` execs ARGV in DIR
//	pull-stub gate FIFO JSON           write one gate command to an agent's gate; exit 3 when no agent
//	                                   waits at it (never blocks: the agent holds its gate open)
//	pull-stub hold                     wait for SIGTERM/SIGINT (a test's stand-in process)
//	pull-stub ids                      print {"pid","pgid","sid"} of itself (no ps needed)
package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		die(2, "usage: pull-stub session|agent|gate|hold|ids ...")
	}
	switch mode, args := os.Args[1], os.Args[2:]; mode {
	case "session":
		session(args, true)
	case "tether":
		session(args, false)
	case "agent":
		if len(args) < 2 {
			die(2, "agent needs RUN and ARGV0")
		}
		agent(args[0], args[1], args[2:])
	case "gate":
		if len(args) != 2 {
			die(2, "gate needs FIFO and JSON")
		}
		gate(args[0], args[1])
	case "hold":
		hold()
	case "ids":
		pgid, _ := syscall.Getpgid(0)
		sid, _ := syscall.Getsid(0)
		fmt.Printf("{\"pid\":%d,\"pgid\":%d,\"sid\":%d}\n", os.Getpid(), pgid, sid)
	default:
		die(2, "unknown mode "+mode)
	}
}

func die(status int, message string) {
	fmt.Fprintln(os.Stderr, "pull-stub: "+message)
	os.Exit(status)
}

// ---- session -------------------------------------------------------------------------

func session(args []string, newSession bool) {
	if len(args) < 2 || args[0] != "--" {
		die(2, "session/tether needs -- CMD ARGS...")
	}
	reader, writer, err := os.Pipe()
	if err != nil {
		die(1, err.Error())
	}
	// The child's stdin: a pipe nobody writes, open until the tether lets go (a reader such as
	// `tmux -C` needs a stdin that stays open; none of the bench's commands reads one).
	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		die(1, err.Error())
	}
	cmd := exec.Command(args[1], args[2:]...)
	cmd.Stdin = stdinR
	cmd.Stdout = writer
	cmd.Stderr = writer
	// The group the command runs in, and that the tether KILLs when its stdin ends.
	group := 0
	if newSession {
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	} else {
		// Our own group, which the command inherits: the bench knows its id (our pid, the
		// Port's os pid) before the command starts. A Port child that is already a session
		// leader (OTP 28) leads its group already and may not move (EPERM).
		syscall.Setpgid(0, 0)
		if pgid, _ := syscall.Getpgid(0); pgid != os.Getpid() {
			die(1, "tether: cannot lead a process group of its own")
		}
		group = os.Getpid()
	}
	signals := make(chan os.Signal, 2)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	// A write to the BEAM's closed Port must fail, not kill us before the tether KILLs the child.
	signal.Ignore(syscall.SIGPIPE)
	if err := cmd.Start(); err != nil {
		die(127, err.Error())
	}
	writer.Close()
	stdinR.Close()
	if newSession {
		// The session line first: the child's output is held in the pipe until it is written.
		fmt.Fprintf(os.Stdout, "{\"session\":%d}\n", cmd.Process.Pid)
	}
	copied := make(chan struct{})
	go func() {
		io.Copy(os.Stdout, reader)
		close(copied)
	}()
	if newSession {
		group = cmd.Process.Pid
	}
	go func() {
		for received := range signals {
			if newSession {
				syscall.Kill(-group, received.(syscall.Signal))
			} else {
				// Our own group would send it back to us: the command only.
				cmd.Process.Signal(received)
			}
		}
	}()
	// The tether: our stdin is the BEAM's Port; it ends when the BEAM closes the Port or dies.
	// For a tether the group is ours too: the KILL ends us with the command.
	go func() {
		io.Copy(io.Discard, os.Stdin)
		stdinW.Close()
		syscall.Kill(-group, syscall.SIGKILL)
		os.Exit(137)
	}()
	err = cmd.Wait()
	stdinW.Close()
	// A descendant may keep the pipe open (a daemon the child started): drain what is there
	// now and stop; the child itself has ended.
	reader.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	<-copied
	status := 0
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		if ws, ok := exit.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			status = 128 + int(ws.Signal())
		} else {
			status = exit.ExitCode()
		}
	} else if err != nil {
		status = 1
	}
	os.Exit(status)
}

// ---- hold ----------------------------------------------------------------------------

func hold() {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	<-signals
	os.Exit(0)
}

// ---- gate ----------------------------------------------------------------------------

// gate writes the command to an agent's gate without ever blocking: the agent holds its gate
// open (O_RDWR) from before its `started` until it has read it, so a write open with O_NONBLOCK
// succeeds while it waits and fails with ENXIO (no reader) or ENOENT (gate removed) otherwise.
func gate(fifo, command string) {
	var probe map[string]any
	if err := json.Unmarshal([]byte(command), &probe); err != nil {
		die(2, "gate command is not JSON: "+err.Error())
	}
	file, err := os.OpenFile(fifo, os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if errors.Is(err, syscall.ENXIO) || errors.Is(err, os.ErrNotExist) {
		die(3, "no agent waits at "+fifo)
	}
	if err != nil {
		die(1, err.Error())
	}
	defer file.Close()
	if _, err := file.Write([]byte(command + "\n")); err != nil {
		die(1, err.Error())
	}
}

// ---- agent ---------------------------------------------------------------------------

// The scenario's token (AtlasE2E.Pull.Seed): pe-s<n> and an optional letter, a word of its own.
var token = regexp.MustCompile(`\bpe-s[0-9]+[a-z]?\b`)

type agentState struct {
	run    string
	launch string
	token  string
	gate   string
	mu     sync.Mutex
	done   bool
}

// leave removes the agent's gate (on every way out), so nothing is left to write to.
func (a *agentState) leave() {
	if a.gate != "" {
		os.Remove(a.gate)
	}
}

// emit writes one event line (below PIPE_BUF, so whole) to the run's events FIFO.
func (a *agentState) emit(fields map[string]any) {
	fields["launch"] = a.launch
	fields["token"] = a.token
	fields["pid"] = os.Getpid()
	line, _ := json.Marshal(fields)
	if len(line) >= 512 {
		fields["cwd"] = ""
		line, _ = json.Marshal(fields)
	}
	file, err := os.OpenFile(filepath.Join(a.run, "stub", "events.fifo"), os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		fmt.Fprintln(os.Stderr, "pull-stub: events: "+err.Error())
		return
	}
	file.Write(append(line, '\n'))
	file.Close()
}

func agent(run, argv0 string, args []string) {
	backend := filepath.Base(argv0)
	if backend == "codex" && len(args) > 0 && args[0] == "sandbox" {
		sandbox(args)
	}
	for _, arg := range args {
		if arg == "--version" {
			fmt.Println("codex-cli 0.0.0-pull-e2e")
			os.Exit(0)
		}
	}
	if backend != "codex" || len(args) == 0 || args[0] != "exec" {
		die(2, "the pull-e2e agent stands in for `codex exec` only, not "+backend+" "+strings.Join(args, " "))
	}
	goal := args[len(args)-1]
	cwd := flagValue(args, "--cd")
	answerFile := flagValue(args, "--output-last-message")
	if cwd != "" {
		if err := os.Chdir(cwd); err != nil {
			die(1, err.Error())
		}
	}
	a := &agentState{run: run, launch: fmt.Sprintf("L%d", os.Getpid()), token: token.FindString(goal)}
	pgid, _ := syscall.Getpgid(0)
	root := repositoryRoot(cwd)
	base := ""
	if bytes, err := os.ReadFile(filepath.Join(root, "fixture", "base-2mib.bin")); err == nil {
		sum := sha256.Sum256(bytes)
		base = hex.EncodeToString(sum[:])
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		received := (<-signals).(syscall.Signal)
		a.mu.Lock()
		if !a.done {
			a.done = true
			a.emit(map[string]any{"event": "signalled", "signal": received.String()})
		}
		a.leave()
		signal.Reset(received)
		syscall.Kill(os.Getpid(), received)
		select {}
	}()

	gates := filepath.Join(run, "stub", "gates")
	os.MkdirAll(gates, 0o700)
	gatePath := filepath.Join(gates, a.launch)
	if err := syscall.Mkfifo(gatePath, 0o600); err != nil {
		die(1, "gate: "+err.Error())
	}
	a.gate = gatePath
	// Held open for reading (and writing, so the open never blocks) before `started`: the
	// bench's `gate` finds a reader the moment it hears of the agent.
	gateFile, err := os.OpenFile(gatePath, os.O_RDWR, 0)
	if err != nil {
		a.leave()
		die(1, "gate: "+err.Error())
	}
	codexLine(map[string]any{"type": "thread.started", "thread_id": "pe-" + a.launch})
	a.emit(map[string]any{"event": "started", "pgid": pgid, "cwd": cwd, "root": rel(cwd, root),
		"base_sha256": base, "gate": gatePath})

	command, err := readGate(gateFile)
	gateFile.Close()
	a.leave()
	if err != nil {
		die(1, "gate: "+err.Error())
	}
	a.mu.Lock()
	if a.done {
		a.mu.Unlock()
		select {}
	}
	a.emit(map[string]any{"event": "gated", "cmd": command["cmd"]})
	a.mu.Unlock()

	switch command["cmd"] {
	case "complete":
		if err := edits(root, command["edits"]); err != nil {
			end(a, "edit_failed")
			die(1, err.Error())
		}
		answer, _ := command["answer"].(string)
		if answer == "" {
			answer = "done " + a.token
		}
		if answerFile != "" {
			os.WriteFile(answerFile, []byte(answer), 0o644)
		}
		codexLine(map[string]any{"type": "item.completed", "item": map[string]any{"type": "agent_message", "text": answer}})
		codexLine(map[string]any{"type": "turn.completed"})
		end(a, "complete")
		os.Exit(0)
	case "fail":
		end(a, "fail")
		os.Exit(1)
	case "hang":
		select {}
	default:
		end(a, "unknown_command")
		die(2, fmt.Sprintf("unknown gate command %v", command["cmd"]))
	}
}

func end(a *agentState, how string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.done {
		return
	}
	a.done = true
	a.emit(map[string]any{"event": "ended", "how": how})
}

func readGate(file *os.File) (map[string]any, error) {
	line, err := bufio.NewReader(file).ReadString('\n')
	if err != nil && line == "" {
		return nil, errors.New("no command")
	}
	var command map[string]any
	if err := json.Unmarshal([]byte(line), &command); err != nil {
		return nil, err
	}
	return command, nil
}

func codexLine(fields map[string]any) {
	line, _ := json.Marshal(fields)
	os.Stdout.Write(append(line, '\n'))
}

func flagValue(args []string, name string) string {
	for i := 0; i+1 < len(args); i++ {
		if args[i] == name {
			return args[i+1]
		}
	}
	return ""
}

// repositoryRoot is the folder holding the fixture repository's files in the turn's
// workspace: <cwd>/atlas (a composed folder names its root), else <cwd>.
func repositoryRoot(cwd string) string {
	for _, dir := range []string{filepath.Join(cwd, "atlas"), cwd} {
		if _, err := os.Stat(filepath.Join(dir, "fixture", "base-2mib.bin")); err == nil {
			return dir
		}
	}
	return cwd
}

func rel(base, path string) string {
	r, err := filepath.Rel(base, path)
	if err != nil {
		return path
	}
	return r
}

// edits applies `write {path, text}`, `blob {path, size, seed}` and `delete {path}` under root.
func edits(root string, raw any) error {
	list, _ := raw.([]any)
	for _, item := range list {
		edit, _ := item.(map[string]any)
		path, _ := edit["path"].(string)
		if path == "" || strings.Contains(path, "..") || filepath.IsAbs(path) {
			return fmt.Errorf("bad edit path %q", path)
		}
		full := filepath.Join(root, path)
		switch edit["op"] {
		case "write":
			text, _ := edit["text"].(string)
			os.MkdirAll(filepath.Dir(full), 0o755)
			if err := os.WriteFile(full, []byte(text), 0o644); err != nil {
				return err
			}
		case "blob":
			size, _ := edit["size"].(float64)
			seed, _ := edit["seed"].(float64)
			os.MkdirAll(filepath.Dir(full), 0o755)
			if err := writeBlob(full, int64(size), uint64(seed)); err != nil {
				return err
			}
		case "delete":
			if err := os.Remove(full); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unknown edit %v", edit["op"])
		}
	}
	return nil
}

// writeBlob writes size bytes of xorshift64 output (AtlasE2E.Pull.Fixture.xorshift/2):
// each step x ^= x<<13; x ^= x>>7; x ^= x<<17, its 8 bytes little-endian; seed 0 is 1.
func writeBlob(path string, size int64, seed uint64) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()
	writer := bufio.NewWriterSize(file, 1<<16)
	x := seed
	if x == 0 {
		x = 1
	}
	var word [8]byte
	for written := int64(0); written < size; {
		x ^= x << 13
		x ^= x >> 7
		x ^= x << 17
		binary.LittleEndian.PutUint64(word[:], x)
		n := int64(8)
		if size-written < n {
			n = size - written
		}
		writer.Write(word[:n])
		written += n
	}
	return writer.Flush()
}

// sandbox stands in for `codex sandbox -P PROFILE -C DIR ARGS... -- ARGV` (the after-check's
// runner): it execs ARGV in DIR with its environment unchanged and enforces nothing.
func sandbox(args []string) {
	dir, rest := "", []string(nil)
	for i := 1; i < len(args); i++ {
		if args[i] == "-C" && i+1 < len(args) {
			dir = args[i+1]
		}
		if args[i] == "--" {
			rest = args[i+1:]
			break
		}
	}
	if dir == "" || len(rest) == 0 {
		die(2, "sandbox needs -C DIR and -- ARGV")
	}
	if err := os.Chdir(dir); err != nil {
		die(1, err.Error())
	}
	program := rest[0]
	if !strings.Contains(program, "/") {
		found, err := exec.LookPath(program)
		if err != nil {
			die(127, err.Error())
		}
		program = found
	}
	if err := syscall.Exec(program, rest, os.Environ()); err != nil {
		die(126, err.Error())
	}
}
