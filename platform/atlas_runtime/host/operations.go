package main

// The operations commands: requests to the operations contract on <home>/backend.sock
// (design 2026-11-16-runtime-backend §13 S2, §13.1 Q4–Q9; the routes of
// backend/contract/lib/operations_api.ex). runtime.sock refuses them since S2 and keeps
// only guidance. The Runtime validates every request and answers with the outcome's
// entity, or with an application/problem+json refusal, as for the work commands.

import (
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// stopWait bounds how long service stop waits for backend.sock to go once the Runtime
// accepted the stop: a graceful stop signals the running turns and kills them after the
// policy's cancel grace (30 s) before the process exits. A variable for tests.
var stopWait = 60 * time.Second

// startWait bounds how long service start waits for backend.sock to answer.
var startWait = 15 * time.Second

const serviceUsage = "use service start|status|stop [--force]|pause|resume|drain|update --build BUILD"

// runtimeInfo is GET /v1/runtime: mode, incarnation, runtime_build, policy_version, slots.
func runtimeInfo(dir string) (map[string]any, error) {
	return callBackend(dir, workCall{method: http.MethodGet, path: "/v1/runtime"})
}

// backendGone reports whether nothing listens on backend.sock any more.
func backendGone(dir string) bool {
	conn, err := net.DialTimeout("unix", filepath.Join(dir, backendSocket), time.Second)
	if conn != nil {
		conn.Close()
	}
	return absent(err)
}

func service(dir string, args []string) (map[string]any, error) {
	if len(args) == 0 {
		return nil, errors.New(serviceUsage)
	}
	action := args[0]
	if action == "update" {
		return serviceUpdate(dir, args[1:])
	}
	if action != "stop" && len(args) != 1 {
		return nil, errors.New(serviceUsage)
	}
	flags := flag.NewFlagSet("service "+action, flag.ContinueOnError)
	force := new(bool)
	if action == "stop" {
		force = flags.Bool("force", false, "kill running turns at once instead of the graceful cancel stages")
	}
	if err := flags.Parse(args[1:]); err != nil {
		return nil, err
	}
	if flags.NArg() != 0 {
		return nil, errors.New(serviceUsage)
	}
	switch action {
	case "status":
		result, err := runtimeInfo(dir)
		if errors.Is(err, errStopped) {
			return map[string]any{"service": "stopped"}, nil
		}
		return result, err
	case "pause", "resume", "drain":
		return callBackend(dir, workCall{method: http.MethodPost, path: "/v1/control/" + action})
	case "start", "stop":
	default:
		return nil, errors.New(serviceUsage)
	}
	lock, err := os.OpenFile(filepath.Join(dir, "service.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return nil, err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	if action == "stop" {
		return serviceStop(dir, *force)
	}
	return serviceStart(dir)
}

// serviceStop asks the Runtime to stop (202 with its runtime info, mode stopping, also on a
// repeat) and returns once backend.sock is gone: that is the confirmation that it exited (Q9).
func serviceStop(dir string, force bool) (map[string]any, error) {
	result, err := callBackend(dir, workCall{method: http.MethodPost, path: "/v1/control/stop",
		body: map[string]any{"force": force}})
	if errors.Is(err, errStopped) {
		return map[string]any{"service": "stopped"}, nil
	}
	if err != nil {
		return nil, err
	}
	for deadline := time.Now().Add(stopWait); ; {
		if backendGone(dir) {
			result["service"] = "stopped"
			return result, nil
		}
		if !time.Now().Before(deadline) {
			return nil, fmt.Errorf("service stop accepted but exit not confirmed: backend.sock still answers after %s; "+
				"run service stop again, with --force to kill the running turns", stopWait)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// serviceStart starts the Runtime unless backend.sock answers, and waits until it does.
func serviceStart(dir string) (map[string]any, error) {
	result, err := runtimeInfo(dir)
	if err == nil {
		return result, nil
	}
	if !errors.Is(err, errStopped) {
		return nil, fmt.Errorf("existing service is not responding: %w", err)
	}
	// Only remove a socket when no process is listening. Never signal saved PIDs. A service
	// from before the operations cutover listens on runtime.sock alone: stop it with its CLI.
	commandSocket := filepath.Join(dir, "runtime.sock")
	if conn, dialErr := net.DialTimeout("unix", commandSocket, time.Second); dialErr == nil {
		conn.Close()
		return nil, errors.New("a Runtime service answers on runtime.sock but not on backend.sock; stop it before starting this one")
	} else if !absent(dialErr) {
		return nil, fmt.Errorf("existing service is not responding: %w", dialErr)
	}
	if root, _ := atlasRoot(); root == "" {
		return nil, errors.New("CLI was not built with the Atlas checkout location")
	}
	if err = os.Remove(commandSocket); err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	build, cmd := serviceCommands(dir, executable)
	build.Stdout = os.Stderr
	build.Stderr = os.Stderr
	if err = build.Run(); err != nil {
		return nil, fmt.Errorf("Runtime build: %w", err)
	}
	log, err := os.OpenFile(filepath.Join(dir, "service.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return nil, err
	}
	defer log.Close()
	cmd.Stdout = log
	cmd.Stderr = log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err = cmd.Start(); err != nil {
		return nil, err
	}
	ended := make(chan error, 1)
	go func() { ended <- cmd.Wait() }()
	for deadline := time.Now().Add(startWait); time.Now().Before(deadline); {
		select {
		case exit := <-ended:
			return nil, fmt.Errorf("Runtime exited (%v); inspect %s", exit, filepath.Join(dir, "service.log"))
		default:
		}
		if result, err = runtimeInfo(dir); err == nil {
			return result, nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	// This is the child started by this invocation, not a PID read from disk.
	cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-ended:
	case <-time.After(5 * time.Second):
		cmd.Process.Kill()
		<-ended
	}
	return nil, fmt.Errorf("Runtime startup timed out; inspect %s", filepath.Join(dir, "service.log"))
}

// preferences shows the policy view (GET /v1/policy), or clears a harness's quota mark
// (--reenable HARNESS: POST /v1/harnesses/{harness}/clear-quota-mark). The policy itself is
// a hand edit of policy.json; no command sets it (Q7).
func preferences(dir string, args []string) (map[string]any, error) {
	flags := flag.NewFlagSet("preferences", flag.ContinueOnError)
	reenable := flags.String("reenable", "", "harness whose quota mark to clear, for example claude")
	removed := map[string]bool{}
	for _, name := range []string{"preferred", "fallback", "preferred-model", "fallback-model"} {
		flags.Func(name, "removed: edit policy.json", func(string) error {
			removed[name] = true
			return nil
		})
	}
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	if flags.NArg() != 0 {
		return nil, errors.New("preferences does not accept positional arguments")
	}
	if len(removed) != 0 {
		return nil, fmt.Errorf("preferences no longer sets the policy: set the configuration of this Runtime's machinery through Control (atlas set MACHINERY configuration=@policy.json), or without Control edit policy.json in the Runtime home (%s) and raise its version",
			filepath.Join(dir, "policy.json"))
	}
	if !visited(flags)["reenable"] {
		return callBackend(dir, workCall{method: http.MethodGet, path: "/v1/policy"})
	}
	if *reenable == "" {
		return nil, errors.New("use preferences --reenable HARNESS")
	}
	return callBackend(dir, workCall{method: http.MethodPost, path: "/v1/harnesses/" + url.PathEscape(*reenable) + "/clear-quota-mark"})
}

// slotBusy is release's 409: the slot's process is still alive. It keeps the problem's fields.
type slotBusy struct {
	*backendProblem
	slot string
}

func (e *slotBusy) Error() string {
	return fmt.Sprintf("slot busy: %s still has a live process; release it after the process has ended (%s)",
		e.slot, e.backendProblem.Error())
}

// release clears a slot's admission latch: POST /v1/slots/{slot}/release (Q8). It starts nothing.
func release(dir string, args []string) (map[string]any, error) {
	flags := flag.NewFlagSet("release", flag.ContinueOnError)
	slot := flags.String("slot", "", "the slot to release, as named in policy.json")
	worker := false
	flags.Func("worker", "removed: use --slot", func(string) error {
		worker = true
		return nil
	})
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	if worker {
		return nil, errors.New("release names a slot: use release --slot SLOT (--worker was removed)")
	}
	if flags.NArg() != 0 {
		return nil, errors.New("unexpected arguments")
	}
	if *slot == "" {
		return nil, errors.New("use release --slot SLOT; it clears the slot's stop latch and starts nothing")
	}
	result, err := callBackend(dir, workCall{method: http.MethodPost, path: "/v1/slots/" + url.PathEscape(*slot) + "/release"})
	var problem *backendProblem
	if errors.As(err, &problem) && problem.status == http.StatusConflict {
		return nil, &slotBusy{backendProblem: problem, slot: *slot}
	}
	return result, err
}
