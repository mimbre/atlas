package host

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"slices"
	"syscall"
	"time"

	"github.com/eyra/atlas/tools/runtime/snapshot"
	"github.com/eyra/atlas/tools/runtime/workspace"
)

// prepareLogLimit is how many bytes of each of stdout and stderr a preparation keeps; the rest
// is counted in its diagnostics, not stored.
const prepareLogLimit = 1 << 20

// prepareTimeout bounds one preparation, after which its process group is killed and the
// preparation fails. It is fixed; tests shorten it. Nothing is ever retried.
var prepareTimeout = 10 * time.Minute

// npmArguments are the only preparation command: a clean install of the tracked lockfile without
// lifecycle scripts, so no repository or package code runs while the registry is reachable.
var npmArguments = []string{"ci", "--ignore-scripts", "--no-audit", "--no-fund"}

// runArguments precede the script of an npm-run preparation: npm runs exactly that declared script,
// none of its pre- or post-scripts, offline, while the sandbox has no network.
var runArguments = []string{"run", "--ignore-scripts", "--offline"}

// preparationKept is all a preparation inherits from the caller's environment; tokens, API keys and
// npm_config_* settings never reach npm. HOME and CODEX_HOME are kept for the trusted Codex launcher.
var preparationKept = []string{"HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "CODEX_HOME"}

// PreparationFailure is a preparation that did not become ready: the CLI prints its result beside
// the error and exits nonzero.
type PreparationFailure struct {
	result map[string]any
	err    error
}

func (failure *PreparationFailure) Error() string          { return failure.err.Error() }
func (failure *PreparationFailure) Result() map[string]any { return failure.result }

// Prepare runs the one explicit npm-ci preparation of path in the materialized folder dest, or
// reports its recorded outcome when the same preparation was already run. It holds the folder lock
// that workers and submissions take, so none of them overlap, and runs nothing but npm ci, in the
// installed Codex sandbox, in an owned process group that is reaped before it returns.
func Prepare(home, dest, path string) (map[string]any, error) {
	return prepare(home, dest, path, "", nil)
}

// PrepareRun runs the one explicit npm-run preparation of the tracked script in path after its
// succeeded npm-ci, or reports its recorded outcome when the same run was already run. Like Prepare
// it holds the folder lock and runs in the installed Codex sandbox, here with no network, writing
// only the declared outputs and an owned scratch. Afterwards every tracked file, the regenerated
// ones included, must be byte- and mode-identical to the snapshot.
func PrepareRun(home, dest, path, script string, outputs []string) (map[string]any, error) {
	return prepare(home, dest, path, script, outputs)
}

// prepare runs an npm-ci of path, or with a script an npm-run of it.
func prepare(home, dest, path, script string, outputs []string) (map[string]any, error) {
	kind := "npm-ci"
	if script != "" {
		kind = "npm-run"
	}
	scope, err := workspace.FolderScopeBeforePreparation(dest, home)
	if err != nil {
		return nil, err
	}
	root, home := scope["root"].(string), scope["home"].(string)
	lock, _, err := workspace.Lock(root, false)
	if err != nil {
		if err.Error() == "Repository already has an active Runtime owner" {
			return nil, fmt.Errorf("folder %s has an active Runtime owner (a worker, preparation or submission); nothing was prepared, run the command again after it stops", root)
		}
		return nil, err
	}
	defer lock.Close()
	if current, err := workspace.FolderScopeBeforePreparation(root, home); err != nil {
		return nil, err
	} else if !workspace.JSONEqual(current, scope) {
		return nil, errors.New("Materialized folder permission scope changed")
	}
	recorded, err := snapshot.LoadPreparation(home, root)
	if err != nil {
		return nil, err
	}
	var step *snapshot.Preparation
	if recorded != nil {
		step = recorded.Step(kind)
	}
	if step != nil {
		if step.Path != path || step.Script != script || kind == "npm-run" && !slices.Equal(step.Outputs, slices.Sorted(slices.Values(outputs))) {
			return nil, fmt.Errorf("%s already has a %s; a folder is prepared once, with one npm-ci and at most one npm-run after it; materialize the snapshot into a fresh folder for another", root, step.Describe())
		}
		// A repeat reports the recorded outcome and never runs again.
		return preparationOutcome(home, step)
	}
	var plan *snapshot.Preparation
	required := [][2]string{{"codex", "Preparation requires the installed Codex sandbox (codex on PATH)"}, {"npm", "Preparation requires npm on PATH"}}
	if kind == "npm-ci" {
		plan, err = snapshot.PlanNPMCI(home, root, path)
	} else {
		plan, err = snapshot.PlanNPMRun(home, root, path, script, outputs)
		required = append(required, [2]string{"node", "Preparation requires node on PATH"})
	}
	if err != nil {
		return nil, err
	}
	tools := map[string]string{}
	for _, tool := range required {
		name := tool[0]
		found, err := exec.LookPath(name)
		if err != nil || !filepath.IsAbs(found) {
			return nil, errors.New(tool[1])
		}
		resolved, err := resolvePath(found)
		if err != nil {
			return nil, err
		}
		if within(root, found) || within(root, resolved) {
			return nil, fmt.Errorf("%s %s is inside the folder being prepared", name, found)
		}
		tools[name] = found
	}
	user, err := homeDirectory()
	if err == nil {
		user, err = resolvePath(user)
	}
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(filepath.Join(home, "scratch"), 0700); err != nil {
		return nil, err
	}
	scratch, err := os.MkdirTemp(filepath.Join(home, "scratch"), "prepare-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(scratch)
	writable := []string{}
	for _, output := range plan.Outputs {
		writable = append(writable, filepath.Join(root, output))
	}
	arguments, err := setupArguments(scope, writable, scratch, user, kind == "npm-ci")
	if err != nil {
		return nil, err
	}
	environment, err := preparationEnvironment(scratch)
	if err != nil {
		return nil, err
	}
	directory := filepath.Join(root, path)
	command := append(append([]string{tools["codex"], "sandbox", "-P", setupProfile, "-C", directory}, arguments...), "--", tools["npm"])
	request := map[string]any{"destination": root, "kind": plan.Kind, "path": path, "timeout_seconds": int(prepareTimeout / time.Second), "log_limit_bytes": prepareLogLimit}
	if kind == "npm-ci" {
		command = append(command, npmArguments...)
	} else {
		command = append(append(command, runArguments...), script)
		environment = append(environment, "npm_config_offline=true")
		request["script"], request["outputs"] = script, plan.Outputs
	}
	request["command"], request["environment"] = command, environment
	if kind == "npm-ci" {
		err = snapshot.BeginPreparation(home, plan, request)
	} else {
		err = snapshot.BeginRun(home, plan, request)
	}
	if err != nil {
		return nil, err
	}

	diagnostics := plan.Diagnostics(home)
	run := runPreparation(command, directory, environment, diagnostics)
	plan.State, plan.Reason, plan.ExitCode = "failed", run.reason, run.code
	var problem error = run.err
	if run.reason == "" {
		plan.Reason = "exit"
		if *run.code == 0 {
			problem = checkPrepared(home, root, plan)
			if problem == nil {
				plan.State, plan.Reason = "succeeded", ""
			} else {
				plan.Reason = "changed"
			}
		}
	}
	plan.EndedAt = time.Now().UTC().Format(time.RFC3339)
	outcome := map[string]any{"state": plan.State, "reason": plan.Reason, "exit_code": plan.ExitCode,
		"stdout_dropped_bytes": run.dropped[0], "stderr_dropped_bytes": run.dropped[1], "error": nil}
	if problem != nil {
		outcome["error"] = problem.Error()
	}
	if body, err := json.Marshal(outcome); err == nil {
		err = os.WriteFile(filepath.Join(diagnostics, "outcome.json"), append(body, '\n'), 0600)
	}
	if err = snapshot.FinishPreparation(home, plan); err != nil {
		return nil, fmt.Errorf("the preparation of %s ended but its outcome is not recorded, so the folder stays not ready: %v", root, err)
	}
	return preparationOutcome(home, plan)
}

// preparationOutcome is the command result of p: success, or a PreparationFailure with the same result.
func preparationOutcome(home string, p *snapshot.Preparation) (map[string]any, error) {
	result := map[string]any{"destination": p.Destination, "snapshot_id": p.SnapshotID, "kind": p.Kind, "path": p.Path,
		"outputs": p.Outputs, "state": p.State, "ready": p.Ready(), "reason": nil, "exit_code": p.ExitCode,
		"started_at": p.StartedAt, "ended_at": nil, "diagnostics": p.Diagnostics(home)}
	if p.Script != "" {
		result["script"] = p.Script
	}
	if p.Reason != "" {
		result["reason"] = p.Reason
	}
	if p.EndedAt != "" {
		result["ended_at"] = p.EndedAt
	}
	if p.Ready() {
		return result, nil
	}
	return nil, &PreparationFailure{result, p.NotReady(home)}
}

// checkPrepared requires the finished preparation p to have changed nothing but its excluded
// outputs: an npm-ci output is absent or a real directory, and an npm-run left every tracked file,
// those it regenerated included, identical to the snapshot.
func checkPrepared(home, root string, p *snapshot.Preparation) error {
	if p.Kind == "npm-ci" {
		output := filepath.Join(root, p.Outputs[0])
		if info, err := os.Lstat(output); err == nil && !info.IsDir() {
			return fmt.Errorf("%s is not a directory", output)
		} else if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	inspection, err := snapshot.Inspect(home, root, nil, false)
	if err != nil {
		return err
	}
	if inspection["clean"] != true {
		body, _ := json.Marshal(inspection["changes"])
		return fmt.Errorf("the preparation changed files outside its output: %s", body)
	}
	return nil
}

// preparationEnvironment is the scrubbed environment of a preparation, with its temp, caches and
// empty npm user and global configuration inside the owned scratch.
func preparationEnvironment(scratch string) ([]string, error) {
	var environment []string
	for _, name := range preparationKept {
		if value, present := os.LookupEnv(name); present {
			environment = append(environment, name+"="+value)
		}
	}
	for _, directory := range [][2]string{{"TMPDIR", "tmp"}, {"XDG_CACHE_HOME", "cache"}, {"npm_config_cache", "npm-cache"}} {
		path := filepath.Join(scratch, directory[1])
		if err := os.Mkdir(path, 0700); err != nil {
			return nil, err
		}
		environment = append(environment, directory[0]+"="+path)
	}
	for _, config := range [][2]string{{"npm_config_userconfig", "user-npmrc"}, {"npm_config_globalconfig", "global-npmrc"}} {
		path := filepath.Join(scratch, config[1])
		file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return nil, err
		}
		file.Close()
		environment = append(environment, config[0]+"="+path)
	}
	return append(environment, "npm_config_registry=https://"+snapshot.NPMRegistry+"/", "npm_config_update_notifier=false"), nil
}

// preparationRun is how one preparation process group ended: an exit code, or a reason
// (start, timeout, interrupted, cleanup) for ending without one.
type preparationRun struct {
	code    *int
	reason  string
	err     error
	dropped [2]int64
}

// cappedLog keeps the first prepareLogLimit bytes written to it and counts the rest.
type cappedLog struct {
	file    *os.File
	kept    int64
	dropped int64
}

func (log *cappedLog) Write(data []byte) (int, error) {
	keep := min(int64(len(data)), prepareLogLimit-log.kept)
	if keep > 0 {
		if _, err := log.file.Write(data[:keep]); err != nil {
			return 0, err
		}
		log.kept += keep
	}
	log.dropped += int64(len(data)) - keep
	return len(data), nil
}

// runPreparation runs command as the leader of a new process group with its output in the
// diagnostics, and kills and reaps the whole group on exit, timeout or interruption.
func runPreparation(command []string, directory string, environment []string, diagnostics string) (run preparationRun) {
	var logs [2]*cappedLog
	var readers, writers [2]*os.File
	for index, name := range []string{"stdout.log", "stderr.log"} {
		file, err := os.OpenFile(filepath.Join(diagnostics, name), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return preparationRun{reason: "start", err: err}
		}
		defer file.Close()
		logs[index] = &cappedLog{file: file}
		if readers[index], writers[index], err = os.Pipe(); err != nil {
			return preparationRun{reason: "start", err: err}
		}
		defer readers[index].Close()
	}
	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(interrupts)

	child := exec.Command(command[0], command[1:]...)
	child.Dir, child.Env, child.Stdout, child.Stderr = directory, environment, writers[0], writers[1]
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	err := child.Start()
	writers[0].Close()
	writers[1].Close()
	if err != nil {
		return preparationRun{reason: "start", err: err}
	}
	copied := make(chan int, 2)
	for index := range readers {
		go func() {
			io.Copy(logs[index], readers[index])
			copied <- index
		}()
	}
	leader := &process{pid: child.Process.Pid}
	if body, err := json.Marshal(map[string]any{"pid": leader.pid, "command": command, "directory": directory}); err == nil {
		os.WriteFile(filepath.Join(diagnostics, "process.json"), append(body, '\n'), 0600)
	}
	deadline := time.Now().Add(prepareTimeout)
	for {
		exited, err := leader.wait(100 * time.Millisecond)
		if err != nil {
			run.reason, run.err = "cleanup", err
		} else if exited {
			break
		}
		select {
		case <-interrupts:
			run.reason, run.err = "interrupted", errors.New("the preparation was interrupted")
		default:
		}
		if run.reason == "" && time.Now().After(deadline) {
			run.reason, run.err = "timeout", fmt.Errorf("the preparation did not finish within %s", prepareTimeout)
		}
		if run.reason != "" {
			if err := leader.signalGroup(syscall.SIGKILL); err != nil {
				run.reason, run.err = "cleanup", err
				return run
			}
			if _, err := leader.wait(-1); err != nil {
				run.reason, run.err = "cleanup", err
			}
			break
		}
	}
	// A normal exit also ends every remaining descendant of the owned group.
	if err := leader.signalGroup(syscall.SIGKILL); err != nil {
		run.reason, run.err = "cleanup", err
	}
	// The pipes close once the group is gone; a process that left the group may still hold one.
	timer := time.After(3 * time.Second)
	for range readers {
		select {
		case <-copied:
		case <-timer:
			readers[0].Close()
			readers[1].Close()
			if run.reason == "" {
				run.reason, run.err = "cleanup", errors.New("a process outside the owned group kept the preparation output open")
			}
		}
	}
	run.dropped = [2]int64{logs[0].dropped, logs[1].dropped}
	if run.reason == "" || run.reason == "timeout" || run.reason == "interrupted" {
		code := leader.code()
		run.code = &code
	}
	return run
}
