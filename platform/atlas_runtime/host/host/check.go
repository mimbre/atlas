package host

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/eyra/atlas/platform/atlas_runtime/host/snapshot"
	"github.com/eyra/atlas/platform/atlas_runtime/host/workspace"
)

// The bounds of one `host check`. The core validates the request first (B16); the helper refuses
// anything outside them again as a usage error, before anything is created or started.
const (
	checkMaxArguments = 64
	checkMaxArgument  = 4096
	checkMaxTimeout   = 24 * 60 * 60
	checkMaxGrace     = 60 * 60
	checkMaxTail      = 1 << 20
)

// checkScratchName is the last element of a check's scratch, <home>/scratch/<name>.
var checkScratchName = regexp.MustCompile(`\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z`)

// checkSweep bounds how long the helper keeps killing an ended check's process group before it
// reports the group as not gone, and checkDrain how long it then waits for the merged output.
var checkSweep, checkDrain = 10 * time.Second, 3 * time.Second

// checkOptions is one parsed `host check` command line.
type checkOptions struct {
	cwd, scratch, sandbox string
	scope                 map[string]any
	timeout, grace        time.Duration
	tail                  int
	argv                  []string
}

// CheckMain runs `atlas-runtime host check` and exits. It exits 0 once it has printed its last
// event (ended or refused); a usage or setup error prints {"error"} on stderr, no event, and exits 1.
func CheckMain(args []string) {
	defer func() {
		if recovered := recover(); recovered != nil {
			json.NewEncoder(os.Stderr).Encode(map[string]any{"error": fmt.Sprint(recovered)})
			os.Exit(1)
		}
	}()
	// A lost parent closes stdout; cleanup must still run instead of the helper dying of SIGPIPE.
	signal.Notify(make(chan os.Signal, 1), syscall.SIGPIPE)
	if err := Check(args, os.Stdin, os.Stdout); err != nil {
		json.NewEncoder(os.Stderr).Encode(map[string]any{"error": err.Error()})
		os.Exit(1)
	}
	os.Exit(0)
}

func parseCheck(args []string) (*checkOptions, error) {
	usage := errors.New("use host check --cwd DIR (--scope JSON | --sandbox read-only) --scratch DIR --timeout SEC --grace SEC --tail BYTES -- ARGV...")
	separator := slices.Index(args, "--")
	if separator < 0 {
		return nil, usage
	}
	flags := flag.NewFlagSet("host check", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	cwd := flags.String("cwd", "", "the work's folder; the command runs in it")
	scope := flags.String("scope", "", "the turn's materialized-folder permission scope (JSON)")
	sandbox := flags.String("sandbox", "", "read-only: the turn's plain read-only sandbox")
	scratch := flags.String("scratch", "", "the check's scratch, <Runtime home>/scratch/NAME")
	timeout := flags.Int("timeout", 0, "seconds before the check is stopped")
	grace := flags.Int("grace", -1, "seconds between SIGINT and SIGKILL")
	tail := flags.Int("tail", -1, "bytes of merged output kept")
	if err := flags.Parse(args[:separator]); err != nil || flags.NArg() != 0 {
		return nil, usage
	}
	options := &checkOptions{cwd: *cwd, scratch: *scratch, sandbox: *sandbox, argv: args[separator+1:],
		timeout: time.Duration(*timeout) * time.Second, grace: time.Duration(*grace) * time.Second, tail: *tail}
	if *cwd == "" || *scratch == "" || (*scope == "") == (*sandbox == "") || *sandbox != "" && *sandbox != "read-only" ||
		*timeout < 1 || *timeout > checkMaxTimeout || *grace < 0 || *grace > checkMaxGrace || *tail < 0 || *tail > checkMaxTail {
		return nil, usage
	}
	if len(options.argv) == 0 || len(options.argv) > checkMaxArguments {
		return nil, fmt.Errorf("host check takes 1 to %d command arguments", checkMaxArguments)
	}
	for _, argument := range options.argv {
		if argument == "" || len(argument) > checkMaxArgument || strings.ContainsRune(argument, 0) {
			return nil, fmt.Errorf("every host check command argument is 1 to %d bytes without NUL", checkMaxArgument)
		}
	}
	if *scope != "" {
		value, err := argument(*scope)
		if err != nil {
			return nil, err
		}
		if options.scope, _ = value.(map[string]any); options.scope == nil || options.scope["profile"] != "materialized-folder" {
			return nil, errors.New("host check --scope must be a materialized-folder permission scope")
		}
	}
	return options, nil
}

// checkFolder verifies the folder and scope of options against the Runtime home and returns the
// canonical folder. A scope must be exactly the folder's recorded materialized-folder scope (its
// record and verified baseline, as snapshot status opens them), of a ready folder that is no packet
// tree. Unlike a turn launch it accepts a folder below the home, as <home>/workers/work-* is (B6).
func checkFolder(options *checkOptions, home string) (string, error) {
	if !filepath.IsAbs(options.cwd) {
		return "", errors.New("host check --cwd must be an absolute path")
	}
	folder, err := filepath.EvalSymlinks(options.cwd)
	if err != nil {
		return "", err
	}
	if info, err := os.Stat(folder); err != nil || !info.IsDir() {
		return "", fmt.Errorf("host check --cwd %s is not a directory", options.cwd)
	}
	if options.scope == nil {
		return folder, nil
	}
	if folder != filepath.Clean(options.cwd) || options.scope["root"] != folder || options.scope["home"] != home {
		return "", errors.New("host check --scope must name the canonical --cwd as its root and ATLAS_RUNTIME_HOME as its home")
	}
	verified, err := snapshot.Verified(home, folder)
	if err != nil {
		return "", err
	}
	verified["profile"], verified["version"], verified["home"] = "materialized-folder", json.Number("1"), home
	if !workspace.JSONEqual(verified, options.scope) {
		return "", errors.New("Materialized folder permission scope changed")
	}
	if packet, err := snapshot.RecordedPacket(home, folder); err != nil {
		return "", err
	} else if packet != "" {
		return "", fmt.Errorf("Materialized folder %s is the tree of review packet %s; a check does not run there", folder, packet)
	}
	if preparation, err := snapshot.LoadPreparation(home, folder); err != nil {
		return "", err
	} else if preparation != nil && !preparation.Ready() {
		return "", preparation.NotReady(home)
	}
	return folder, nil
}

// checkCommand resolves argv[0] the way the check will run it: a relative path must stay inside
// folder after every symlink, and a bare name must be found on PATH. It returns the refusal, or "".
func checkCommand(folder, name string) string {
	if !strings.Contains(name, "/") {
		if found, err := exec.LookPath(name); err != nil || !filepath.IsAbs(found) {
			return "not_found"
		}
		return ""
	}
	if filepath.IsAbs(name) || slices.Contains(strings.Split(name, "/"), "..") {
		return "leaves_folder"
	}
	resolved, err := filepath.EvalSymlinks(filepath.Join(folder, name))
	if err != nil {
		// A dangling link that points out of the folder still leaves it.
		if target, linkErr := os.Readlink(filepath.Join(folder, name)); linkErr == nil && filepath.IsAbs(target) && !within(folder, target) {
			return "leaves_folder"
		}
		return "not_found"
	}
	if !within(folder, resolved) {
		return "leaves_folder"
	}
	return ""
}

// checkSignal signals the check's whole process group.
func checkSignal(leader *process, sig syscall.Signal) error {
	return leader.signalGroup(sig)
}

// Check runs one after-check (design §3.10; B18, B19, B23, B24): ARGV in the work's folder, under
// `codex sandbox` with the turn's own profile, in its own process group, with stdout and stderr
// merged into a bounded tail. stdin carries {"stop":"signal"} and {"stop":"kill"}; its EOF means the
// parent is lost. stdout gets {"event":"started","pgid"} and then exactly one ended line, or only a
// refused line when nothing was started. The scratch is removed on every end once the group is gone.
func Check(args []string, stdin io.Reader, stdout io.Writer) (err error) {
	options, err := parseCheck(args)
	if err != nil {
		return err
	}
	home := os.Getenv("ATLAS_RUNTIME_HOME")
	if home == "" || !filepath.IsAbs(home) {
		return errors.New("host check requires ATLAS_RUNTIME_HOME, an absolute path")
	}
	if home, err = filepath.EvalSymlinks(home); err != nil {
		return err
	}
	folder, err := checkFolder(options, home)
	if err != nil {
		return err
	}
	scratch := filepath.Clean(options.scratch)
	if scratch != options.scratch || filepath.Dir(scratch) != filepath.Join(home, "scratch") || !checkScratchName.MatchString(filepath.Base(scratch)) {
		return errors.New("host check --scratch must be <ATLAS_RUNTIME_HOME>/scratch/NAME")
	}
	if within(folder, scratch) || within(scratch, folder) {
		return errors.New("host check --scratch must not overlap --cwd")
	}
	lock, _, err := workspace.Lock(folder, false)
	if err != nil {
		if err.Error() == "Repository already has an active Runtime owner" {
			return fmt.Errorf("folder %s has an active Runtime owner (a worker, preparation or submission); the check was not run", folder)
		}
		return err
	}
	defer lock.Close()
	// A scratch left by a killed helper goes first; the core starts one check per attempt at a time.
	if err = removeScratch(scratch); err != nil {
		return err
	}
	write := func(record map[string]any) error {
		data, err := json.Marshal(record)
		if err == nil {
			_, err = stdout.Write(append(data, '\n'))
		}
		return err
	}
	// Never unsandboxed: no absolute codex on PATH, no check.
	codex, err := exec.LookPath("codex")
	if err != nil || !filepath.IsAbs(codex) {
		return write(map[string]any{"event": "refused", "why": "sandbox_unavailable"})
	}
	if why := checkCommand(folder, options.argv[0]); why != "" {
		return write(map[string]any{"event": "refused", "why": why})
	}

	if err = os.MkdirAll(filepath.Join(home, "scratch"), 0700); err != nil {
		return err
	}
	if err = os.Mkdir(scratch, 0700); err != nil {
		return err
	}
	var leader *process
	groupGoneConfirmed := false
	defer func() {
		// Failure cleanup: kill and reap what was started. The scratch goes only once the group is
		// gone (B24); otherwise the core removes it after its heartbeat probe finds the group gone.
		if leader != nil && !groupGoneConfirmed {
			checkSignal(leader, syscall.SIGKILL)
			leader.wait(-1)
			groupGoneConfirmed, _ = sweepGroup(leader)
		}
		if leader == nil || groupGoneConfirmed {
			if removeErr := removeScratch(scratch); removeErr != nil && err == nil {
				err = removeErr
			}
		}
	}()
	var profile string
	var arguments []string
	if options.scope != nil {
		inspector, err := os.Executable()
		if err == nil {
			inspector, err = filepath.EvalSymlinks(inspector)
		}
		if err != nil {
			return err
		}
		user, err := homeDirectory()
		if err != nil {
			return err
		}
		profile = "atlas_folder"
		if arguments, err = folderArguments(options.scope, scratch, user, inspector); err != nil {
			return err
		}
	} else {
		profile = "atlas_read_only"
		if arguments, err = sandboxArguments(options.sandbox, folder, home); err != nil {
			return err
		}
	}
	environment, err := preparationEnvironment(scratch)
	if err != nil {
		return err
	}
	command := append(append([]string{codex, "sandbox", "-P", profile, "-C", folder}, arguments...), "--")
	command = append(command, options.argv...)

	reader, writer, err := os.Pipe()
	if err != nil {
		return err
	}
	defer reader.Close()
	// Handling SIGINT here also gives the check the default SIGINT disposition, even when the helper
	// itself was started with it ignored (P0 T1f). SIGINT or SIGTERM to the helper is a lost parent.
	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(interrupts)
	child := exec.Command(command[0], command[1:]...)
	child.Dir, child.Env, child.Stdout, child.Stderr = folder, environment, writer, writer
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	err = child.Start()
	writer.Close()
	if err != nil {
		return err
	}
	startedAt := time.Now()
	leader = &process{pid: child.Process.Pid}
	output := &checkTail{limit: options.tail}
	drained := make(chan struct{})
	go func() {
		io.Copy(output, reader)
		close(drained)
	}()
	controls := make(chan string)
	go func() {
		scanner := bufio.NewScanner(stdin)
		scanner.Buffer(make([]byte, 4096), 4096)
		for scanner.Scan() {
			controls <- scanner.Text()
		}
		close(controls)
	}()
	// A parent that cannot read the started line is lost.
	parentLost := write(map[string]any{"event": "started", "pgid": leader.pid}) != nil

	var sent syscall.Signal
	var grace <-chan time.Time
	timedOut, stopped := false, false
	stop := func(sig syscall.Signal) error {
		if sent == syscall.SIGKILL || sent == sig {
			return nil
		}
		if exited, err := leader.wait(0); err != nil || exited {
			return err
		}
		if err := checkSignal(leader, sig); err != nil {
			return err
		}
		sent, grace = sig, nil
		if sig == syscall.SIGINT {
			grace = time.After(options.grace)
		}
		return nil
	}
	if parentLost {
		stopped = true
		if err = stop(syscall.SIGINT); err != nil {
			return err
		}
	}
	deadline := time.NewTimer(options.timeout)
	defer deadline.Stop()
	poll := time.NewTicker(20 * time.Millisecond)
	defer poll.Stop()
	for exited := false; !exited; {
		select {
		case line, open := <-controls:
			if !open {
				// The parent is lost: signal, then after the grace kill, then end.
				controls, stopped = nil, true
				err = stop(syscall.SIGINT)
				break
			}
			var control map[string]string
			if json.Unmarshal([]byte(line), &control) != nil || len(control) != 1 || control["stop"] != "signal" && control["stop"] != "kill" {
				fmt.Fprintf(os.Stderr, "host check: ignored unknown control %q\n", line)
				break
			}
			stopped = true
			if control["stop"] == "kill" {
				err = stop(syscall.SIGKILL)
			} else {
				err = stop(syscall.SIGINT)
			}
		case <-deadline.C:
			timedOut = true
			err = stop(syscall.SIGINT)
		case <-grace:
			err = stop(syscall.SIGKILL)
		case <-interrupts:
			stopped = true
			err = stop(syscall.SIGINT)
		case <-poll.C:
			exited, err = leader.wait(0)
		}
		if err != nil {
			return err
		}
	}
	// The leader is reaped. A normal end also ends every remaining member of the owned group.
	if groupGoneConfirmed, err = sweepGroup(leader); err != nil {
		return err
	}
	duration := time.Since(startedAt)
	// The pipe closes once the group is gone; a process that left the group may still hold it.
	drainedAll := true
	select {
	case <-drained:
	case <-time.After(checkDrain):
		drainedAll = false
		reader.Close()
	}
	scratchRemoved := false
	if groupGoneConfirmed {
		scratchRemoved = removeScratch(scratch) == nil
	}
	tail, complete := output.result()
	ended := map[string]any{"event": "ended", "exit_status": nil, "signal": nil, "timed_out": timedOut, "stopped": stopped,
		"duration_ms": duration.Milliseconds(), "output": map[string]any{"tail": tail, "complete": complete && drainedAll},
		"group_gone": groupGoneConfirmed, "scratch_removed": scratchRemoved}
	switch {
	case sent != 0:
		// Only a stop the helper itself sent names a signal.
		ended["signal"] = map[syscall.Signal]string{syscall.SIGINT: "SIGINT", syscall.SIGKILL: "SIGKILL"}[sent]
	case leader.status.Signaled():
		// A command that dies of its own signal: the status `codex sandbox` passes on (P0 T1e: 143).
		ended["exit_status"] = 128 + int(leader.status.Signal())
	default:
		ended["exit_status"] = leader.status.ExitStatus()
	}
	// After a lost parent nobody reads this line; the end is the same.
	if writeErr := write(ended); writeErr != nil && !stopped {
		return writeErr
	}
	return nil
}

// sweepGroup kills the reaped leader's process group until no member is left, for at most checkSweep,
// and reports whether it is gone.
func sweepGroup(leader *process) (bool, error) {
	for until := time.Now().Add(checkSweep); time.Now().Before(until); {
		if err := checkSignal(leader, syscall.SIGKILL); err != nil {
			return false, err
		}
		for range 50 {
			if gone, err := groupGone(leader.pid); err != nil || gone {
				return gone, err
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	return false, nil
}

// checkTail keeps the last limit bytes written to it and counts them all.
type checkTail struct {
	mu    sync.Mutex
	limit int
	data  []byte
	total int64
}

func (tail *checkTail) Write(data []byte) (int, error) {
	tail.mu.Lock()
	defer tail.mu.Unlock()
	tail.total += int64(len(data))
	tail.data = append(tail.data, data...)
	if len(tail.data) > 2*tail.limit+65536 {
		tail.data = append([]byte(nil), tail.data[len(tail.data)-tail.limit:]...)
	}
	return len(data), nil
}

// result is the tail, cut on a UTF-8 boundary with invalid bytes dropped, so it never exceeds the
// limit, and whether the whole output fit.
func (tail *checkTail) result() (string, bool) {
	tail.mu.Lock()
	defer tail.mu.Unlock()
	data := tail.data
	if len(data) > tail.limit {
		data = data[len(data)-tail.limit:]
		for len(data) > 0 && !utf8.RuneStart(data[0]) {
			data = data[1:]
		}
	}
	return strings.ToValidUTF8(string(data), ""), tail.total <= int64(tail.limit)
}
