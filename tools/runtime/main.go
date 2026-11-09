// atlas-runtime is a client of the separate Elixir Runtime service.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/eyra/atlas/tools/runtime/host"
	"github.com/eyra/atlas/tools/runtime/snapshot"
	"github.com/eyra/atlas/tools/runtime/workspace"
)

// Set at installation with -ldflags '-X main.repoRoot=...'.
var repoRoot string

func home() (string, error) {
	if value := os.Getenv("ATLAS_RUNTIME_HOME"); value != "" {
		return filepath.Abs(value)
	}
	user, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(user, ".local", "state", "atlas-runtime"), nil
}

func request(dir string, command map[string]any) (map[string]any, error) {
	conn, err := net.DialTimeout("unix", filepath.Join(dir, "runtime.sock"), time.Second)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(30 * time.Second))
	if err = json.NewEncoder(conn).Encode(command); err != nil {
		return nil, err
	}
	var reply map[string]any
	var response io.Reader = conn
	// History can span many turns; retain the existing cap for individual replies.
	if command["command"] != "turns" {
		response = io.LimitReader(conn, 1048576)
	}
	err = json.NewDecoder(response).Decode(&reply)
	if err == nil && reply["command_error"] != nil {
		err = fmt.Errorf("%v", reply["command_error"])
	}
	return reply, err
}

func absent(err error) bool {
	return errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED)
}

func environment(dir string) []string {
	result := []string{}
	for _, item := range os.Environ() {
		if !strings.HasPrefix(item, "ATLAS_") && !strings.HasPrefix(item, "MIX_ENV=") &&
			!strings.HasPrefix(item, "MIX_BUILD_PATH=") && !strings.HasPrefix(item, "ELIXIR_ERL_OPTIONS=") {
			result = append(result, item)
		}
	}
	return append(result, "MIX_ENV=test", "MIX_BUILD_PATH="+filepath.Join(dir, "build"), "ELIXIR_ERL_OPTIONS=+S 2:2")
}

func service(dir, action string) (map[string]any, error) {
	if action == "status" {
		result, err := request(dir, map[string]any{"command": "service-status"})
		if absent(err) {
			return map[string]any{"service": "stopped"}, nil
		}
		return result, err
	}
	if action != "start" && action != "stop" {
		return nil, errors.New("use service start|status|stop")
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
	result, err := request(dir, map[string]any{"command": "service-status"})
	if action == "stop" {
		if absent(err) {
			return map[string]any{"service": "stopped"}, nil
		}
		if err != nil {
			return nil, err
		}
		result, err = request(dir, map[string]any{"command": "service-stop"})
		if err != nil {
			return nil, err
		}
		for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); {
			conn, dialErr := net.DialTimeout("unix", filepath.Join(dir, "runtime.sock"), time.Second)
			if absent(dialErr) {
				result["service"] = "stopped"
				return result, nil
			}
			if conn != nil {
				conn.Close()
			}
			time.Sleep(100 * time.Millisecond)
		}
		return nil, errors.New("service stop acknowledged but exit not confirmed")
	}
	if err == nil {
		return result, nil
	}
	if !absent(err) {
		return nil, fmt.Errorf("existing service is not responding: %w", err)
	}
	if repoRoot == "" {
		return nil, errors.New("CLI was not built with the Atlas checkout location")
	}
	// Only remove a socket when no process is listening. Never signal saved PIDs.
	if err = os.Remove(filepath.Join(dir, "runtime.sock")); err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	build := exec.Command("mix", "compile", "--warnings-as-errors")
	build.Dir = filepath.Join(repoRoot, "beam", "apps", "atlas_runtime")
	build.Env = environment(dir)
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
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command("mix", "run", "--no-start", "--no-compile", "--no-deps-check",
		filepath.Join(repoRoot, "tools/runtime/service.exs"), dir)
	cmd.Dir = filepath.Join(repoRoot, "beam", "apps", "atlas_runtime")
	cmd.Env = append(environment(dir), "ATLAS_RUNTIME_EXECUTABLE="+executable)
	cmd.Stdout = log
	cmd.Stderr = log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err = cmd.Start(); err != nil {
		return nil, err
	}
	ended := make(chan error, 1)
	go func() { ended <- cmd.Wait() }()
	for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); {
		select {
		case exit := <-ended:
			return nil, fmt.Errorf("Runtime exited (%v); inspect %s", exit, filepath.Join(dir, "service.log"))
		default:
		}
		result, err = request(dir, map[string]any{"command": "service-status"})
		if err == nil {
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

var workerName = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,63}$`)
var requestIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`)

func requestIDFlag(flags *flag.FlagSet, command map[string]any) {
	flags.Func("request-id", "caller-supplied start/continue identity; never generated or retried automatically", func(value string) error {
		if !requestIDPattern.MatchString(value) {
			return errors.New("request-id must match ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
		}
		command["request_id"] = value
		return nil
	})
}

func workerFlag(flags *flag.FlagSet, command map[string]any) {
	flags.Func("worker", "worker name (lowercase letter, then lowercase letters, digits, _ or -; at most 64 characters)", func(value string) error {
		if !workerName.MatchString(value) {
			return errors.New("worker must match ^[a-z][a-z0-9_-]{0,63}$")
		}
		command["worker_id"] = value
		return nil
	})
}

func turnFlag(flags *flag.FlagSet, command map[string]any) {
	flags.Func("turn", "saved turn ID (must belong to --worker when both are supplied)", func(value string) error {
		if strings.TrimSpace(value) == "" {
			return errors.New("turn must be nonempty")
		}
		command["turn_id"] = value
		return nil
	})
}

func parseAnswers(raw string) (map[string]string, error) {
	const invalid = "answers must be a JSON object of 1..4 unique nonempty question/string pairs (4096 bytes each, 16384 bytes total)"
	if len(raw) > 16384 || !utf8.ValidString(raw) {
		return nil, errors.New(invalid)
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, errors.New(invalid)
	}
	answers := make(map[string]string, 4)
	for decoder.More() {
		token, err = decoder.Token()
		key, ok := token.(string)
		if err != nil || !ok || strings.TrimSpace(key) == "" || len(key) > 4096 || len(answers) == 4 {
			return nil, errors.New(invalid)
		}
		if _, duplicate := answers[key]; duplicate {
			return nil, errors.New(invalid)
		}
		var value string
		if err = decoder.Decode(&value); err != nil || strings.TrimSpace(value) == "" || len(value) > 4096 {
			return nil, errors.New(invalid)
		}
		answers[key] = value
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim('}') || len(answers) == 0 {
		return nil, errors.New(invalid)
	}
	if _, err = decoder.Token(); err != io.EOF {
		return nil, errors.New(invalid)
	}
	return answers, nil
}

func parseHandoff(raw string) (map[string]json.RawMessage, error) {
	const invalid = "handoff must be one UTF-8 JSON object with unique fields (32768 bytes maximum)"
	if len(raw) > 32768 || !utf8.ValidString(raw) {
		return nil, errors.New(invalid)
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, errors.New(invalid)
	}
	handoff := make(map[string]json.RawMessage, 10)
	for decoder.More() {
		token, err = decoder.Token()
		key, ok := token.(string)
		if err != nil || !ok {
			return nil, errors.New(invalid)
		}
		if _, duplicate := handoff[key]; duplicate {
			return nil, errors.New(invalid)
		}
		var value json.RawMessage
		if err = decoder.Decode(&value); err != nil {
			return nil, errors.New(invalid)
		}
		handoff[key] = value
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim('}') || len(handoff) == 0 {
		return nil, errors.New(invalid)
	}
	if _, err = decoder.Token(); err != io.EOF {
		return nil, errors.New(invalid)
	}
	return handoff, nil
}

func parseOutput(args []string) (map[string]any, bool, error) {
	command := map[string]any{"command": "output"}
	flags := flag.NewFlagSet("output", flag.ContinueOnError)
	workerFlag(flags, command)
	turnFlag(flags, command)
	follow := flags.Bool("follow", false, "follow the selected worker's current turn without switching turns")
	if err := flags.Parse(args); err != nil {
		return nil, false, err
	}
	if flags.NArg() != 0 {
		return nil, false, errors.New("output does not accept positional arguments")
	}
	if *follow && command["turn_id"] != nil {
		return nil, false, errors.New("output --follow cannot be combined with --turn")
	}
	return command, *follow, nil
}

func execute(args []string) (map[string]any, error) {
	return executeTo(args, nil)
}

func executeTo(args []string, out io.Writer) (map[string]any, error) {
	if len(args) == 0 {
		return nil, errors.New("use service start|status|stop, start [--worker NAME] [--questions] --cwd PATH ASSIGNMENT, continue [--worker NAME] [--turn TURN_ID] ASSIGNMENT, answer --worker NAME --turn TURN_ID --question QUESTION_ID --answers JSON_OBJECT, preferences, status [--worker NAME], turns, events [--cursor CURSOR] [--limit N | --follow], output [--worker NAME] [--follow | --turn TURN_ID], stop|kill --worker NAME --turn TURN_ID, release --worker NAME, snapshot materialize --snapshot sha256:HEX --dest NEW_PATH, snapshot prepare --dest PATH --npm-ci REPO_PATH[/SUBDIR] | --npm-run REPO_PATH[/SUBDIR] --script NAME --output REPO_PATH/OUT..., snapshot status|diff --dest PATH [--path REPO_PATH]..., snapshot submit --dest PATH [--path REPO_PATH] --change-id UUID, or snapshot rebind --dest PATH")
	}
	dir, err := home()
	if err != nil {
		return nil, err
	}
	// Offline inspection only reads the home, so it also runs where the home is read-only.
	if len(args) > 1 && args[0] == "snapshot" && (args[1] == "status" || args[1] == "diff") {
		if value := os.Getenv("ATLAS_RUNTIME_HOME"); value != "" && !filepath.IsAbs(value) {
			return nil, errors.New("ATLAS_RUNTIME_HOME must be an absolute path")
		}
	} else {
		if err = os.MkdirAll(dir, 0700); err != nil {
			return nil, err
		}
		// Mix derives relative priv symlinks from MIX_BUILD_PATH. Resolve directory
		// aliases (notably /tmp -> /private/tmp on macOS) before building or launching.
		dir, err = filepath.EvalSymlinks(dir)
		if err != nil {
			return nil, err
		}
		if err = os.Chmod(dir, 0700); err != nil {
			return nil, err
		}
	}
	if args[0] == "service" {
		if len(args) != 2 {
			return nil, errors.New("use service start|status|stop")
		}
		return service(dir, args[1])
	}
	if args[0] == "snapshot" {
		usage := errors.New("use snapshot materialize --snapshot sha256:HEX --dest NEW_PATH, snapshot prepare --dest PATH --npm-ci REPO_PATH[/SUBDIR] | --npm-run REPO_PATH[/SUBDIR] --script NAME --output REPO_PATH/OUT..., snapshot status|diff --dest PATH [--path REPO_PATH]..., snapshot submit --dest PATH [--path REPO_PATH] --change-id UUID, or snapshot rebind --dest PATH")
		if len(args) < 2 || args[1] != "materialize" && args[1] != "prepare" && args[1] != "status" && args[1] != "diff" && args[1] != "submit" && args[1] != "rebind" {
			return nil, usage
		}
		flags := flag.NewFlagSet("snapshot "+args[1], flag.ContinueOnError)
		dest := flags.String("dest", "", "materialized destination folder")
		id, path, paths := new(string), new(string), []string{}
		run, script := new(string), new(string)
		switch args[1] {
		case "materialize":
			id = flags.String("snapshot", "", "Code snapshot ID")
		case "prepare":
			path = flags.String("npm-ci", "", "tracked package folder whose package-lock.json npm ci installs")
			run = flags.String("npm-run", "", "package folder, after its --npm-ci, whose tracked script runs offline")
			script = flags.String("script", "", "tracked package.json script that --npm-run runs")
			flags.Func("output", "repository path the --npm-run script writes; repeat for each", func(value string) error {
				paths = append(paths, value)
				return nil
			})
		case "submit":
			path = flags.String("path", "", "materialized repository path; optional with one repository")
			id = flags.String("change-id", "", "caller-chosen lowercase UUID; repeat it to resume")
		case "rebind":
		default:
			flags.Func("path", "materialized repository path; repeat to select several", func(value string) error {
				paths = append(paths, value)
				return nil
			})
		}
		if err = flags.Parse(args[2:]); err != nil {
			return nil, err
		}
		if flags.NArg() != 0 || *dest == "" || (args[1] == "materialize" || args[1] == "submit") && *id == "" {
			return nil, usage
		}
		// A preparation is exactly one npm-ci, or one npm-run with its script and outputs.
		if args[1] == "prepare" && ((*path == "") == (*run == "") || *path != "" && (*script != "" || len(paths) > 0) || *run != "" && (*script == "" || len(paths) == 0)) {
			return nil, usage
		}
		switch args[1] {
		case "materialize":
			return snapshot.Materialize(dir, *id, *dest)
		case "prepare":
			if *run != "" {
				return host.PrepareRun(dir, *dest, *run, *script, paths)
			}
			return host.Prepare(dir, *dest, *path)
		case "submit":
			return snapshot.Submit(dir, *dest, *path, *id)
		case "rebind":
			return snapshot.Rebind(dir, *dest)
		}
		return snapshot.Inspect(dir, *dest, paths, args[1] == "diff")
	}
	command := map[string]any{"command": args[0]}
	switch args[0] {
	case "start":
		flags := flag.NewFlagSet("start", flag.ContinueOnError)
		workerFlag(flags, command)
		requestIDFlag(flags, command)
		cwd := flags.String("cwd", "", "existing working directory")
		sandbox := flags.String("sandbox", "read-only", "read-only or workspace-write")
		permissions := flags.String("permissions", "", "explicit dedicated-repository Git/GitHub scope or materialized-folder scope")
		repository := flags.String("repo", "", "GitHub HTTPS repository to provision")
		branch := flags.String("branch", "", "new task branch based on freshly fetched develop")
		backend := flags.String("backend", "", "explicit codex or claude; omitted uses preferences")
		questions := flags.Bool("questions", false, "opt in to Claude's restricted host-question path")
		if err = flags.Parse(args[1:]); err != nil {
			return nil, err
		}
		backendSet := false
		flags.Visit(func(f *flag.Flag) {
			if f.Name == "backend" {
				backendSet = true
			}
			if f.Name == "questions" {
				command["questions_enabled"] = *questions
			}
		})
		if backendSet {
			if *backend != "codex" && *backend != "claude" {
				return nil, errors.New("backend must be codex or claude")
			}
			command["backend"] = *backend
		}
		if *questions && *backend == "codex" {
			return nil, errors.New("questions are supported only by Claude")
		}
		if *sandbox != "read-only" && *sandbox != "workspace-write" {
			return nil, errors.New("sandbox must be read-only or workspace-write")
		}
		if *permissions != "" && *permissions != "dedicated-repository" && *permissions != "materialized-folder" {
			return nil, errors.New("unknown permission profile")
		}
		conflict := false
		flags.Visit(func(f *flag.Flag) {
			if f.Name == "sandbox" && *permissions != "" {
				conflict = true
			}
		})
		if conflict {
			return nil, errors.New("permissions cannot be combined with sandbox")
		}
		if flags.NArg() != 1 || strings.TrimSpace(flags.Arg(0)) == "" {
			return nil, errors.New("start requires one nonempty assignment")
		}
		if *repository != "" || *branch != "" {
			if *repository == "" || *branch == "" || *cwd != "" || *permissions != "dedicated-repository" {
				return nil, errors.New("use start --repo URL --branch NEW_BRANCH --permissions dedicated-repository \"assignment\" without --cwd")
			}
			command["repository"] = *repository
			command["branch"] = *branch
			command["permissions"] = *permissions
			command["assignment"] = flags.Arg(0)
			break
		}
		if *cwd == "" {
			return nil, errors.New("use start --cwd PATH \"assignment\"")
		}
		path, err := filepath.Abs(*cwd)
		if err != nil {
			return nil, err
		}
		// ID replay must reach the recorded admission even if its workspace no longer exists.
		if command["request_id"] == nil {
			info, err := os.Stat(path)
			if err != nil {
				return nil, err
			}
			if !info.IsDir() {
				return nil, errors.New("cwd is not a directory")
			}
		}
		command["cwd"] = path
		command["assignment"] = flags.Arg(0)
		if *permissions == "" {
			command["sandbox"] = *sandbox
		} else {
			command["permissions"] = *permissions
		}
	case "preferences":
		flags := flag.NewFlagSet("preferences", flag.ContinueOnError)
		preferred := flags.String("preferred", "", "preferred backend: claude")
		fallback := flags.String("fallback", "", "fallback backend: codex")
		preferredModel := flags.String("preferred-model", "", "optional Claude model")
		fallbackModel := flags.String("fallback-model", "", "optional Codex model")
		reenable := flags.String("reenable", "", "reenable backend: claude")
		if err = flags.Parse(args[1:]); err != nil {
			return nil, err
		}
		if flags.NArg() != 0 {
			return nil, errors.New("preferences does not accept positional arguments")
		}
		supplied := map[string]bool{}
		flags.Visit(func(f *flag.Flag) { supplied[f.Name] = true })
		if supplied["reenable"] {
			if len(supplied) != 1 || *reenable != "claude" {
				return nil, errors.New("use preferences --reenable claude without other flags")
			}
			command["reenable"] = *reenable
		} else if len(supplied) != 0 {
			if *preferred != "claude" || *fallback != "codex" {
				return nil, errors.New("use preferences --preferred claude --fallback codex [--preferred-model MODEL] [--fallback-model MODEL]")
			}
			for _, selection := range []struct {
				name  string
				model string
			}{
				{"preferred", *preferredModel},
				{"fallback", *fallbackModel},
			} {
				var model any
				if supplied[selection.name+"-model"] {
					if strings.TrimSpace(selection.model) == "" {
						return nil, errors.New("explicit preference models must be nonempty")
					}
					model = selection.model
				}
				backend := *preferred
				if selection.name == "fallback" {
					backend = *fallback
				}
				command[selection.name] = map[string]any{"backend": backend, "model": model}
			}
		}
	case "continue":
		flags := flag.NewFlagSet("continue", flag.ContinueOnError)
		workerFlag(flags, command)
		turnFlag(flags, command)
		requestIDFlag(flags, command)
		if err = flags.Parse(args[1:]); err != nil {
			return nil, err
		}
		if flags.NArg() != 1 || strings.TrimSpace(flags.Arg(0)) == "" {
			return nil, errors.New("use continue [--request-id ID] [--worker NAME] [--turn TURN_ID] \"assignment\"; working directory and sandbox cannot change")
		}
		command["assignment"] = flags.Arg(0)
	case "answer", "question":
		flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
		workerFlag(flags, command)
		turnFlag(flags, command)
		question := flags.String("question", "", "opaque question ID")
		var raw string
		if args[0] == "answer" {
			flags.StringVar(&raw, "answers", "", "JSON object mapping exact question texts to answers")
		}
		if err = flags.Parse(args[1:]); err != nil {
			return nil, err
		}
		if flags.NArg() != 0 || command["worker_id"] == nil || command["turn_id"] == nil ||
			strings.TrimSpace(*question) == "" || len(*question) > 128 {
			return nil, errors.New("question and answer require --worker, --turn and --question, with no positional arguments")
		}
		command["question_id"] = *question
		if args[0] == "answer" {
			answers, parseErr := parseAnswers(raw)
			if parseErr != nil {
				return nil, parseErr
			}
			command["answers"] = answers
		}
	case "route-peer-question", "peer-question", "bind-peer-reply":
		flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
		workerFlag(flags, command)
		turnFlag(flags, command)
		question := flags.String("question", "", "exact pending sender question ID")
		var peerWorker, peerTurn, responseTurn string
		if args[0] == "route-peer-question" {
			flags.StringVar(&peerWorker, "peer-worker", "", "distinct peer worker name")
			flags.StringVar(&peerTurn, "peer-turn", "", "exact saved peer source turn")
		}
		if args[0] == "bind-peer-reply" {
			flags.StringVar(&responseTurn, "response-turn", "", "successful peer continuation turn to record")
		}
		if err = flags.Parse(args[1:]); err != nil {
			return nil, err
		}
		if flags.NArg() != 0 || command["worker_id"] == nil || command["turn_id"] == nil ||
			strings.TrimSpace(*question) == "" || len(*question) > 128 {
			return nil, errors.New("peer question commands require --worker, --turn and --question, with no positional arguments")
		}
		command["question_id"] = *question
		if args[0] == "route-peer-question" {
			if !workerName.MatchString(peerWorker) || strings.TrimSpace(peerTurn) == "" {
				return nil, errors.New("route-peer-question requires a valid --peer-worker and nonempty --peer-turn")
			}
			command["peer_worker_id"] = peerWorker
			command["peer_source_turn_id"] = peerTurn
		}
		if args[0] == "bind-peer-reply" {
			if strings.TrimSpace(responseTurn) == "" {
				return nil, errors.New("bind-peer-reply requires --response-turn")
			}
			command["response_turn_id"] = responseTurn
		}
	case "submit-handoff", "handoff":
		flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
		workerFlag(flags, command)
		turnFlag(flags, command)
		var raw string
		if args[0] == "submit-handoff" {
			flags.StringVar(&raw, "handoff", "", "bounded JSON completion or pull_request declaration")
		}
		if err = flags.Parse(args[1:]); err != nil {
			return nil, err
		}
		if flags.NArg() != 0 || command["worker_id"] == nil || command["turn_id"] == nil {
			return nil, errors.New("handoff commands require --worker and --turn, with no positional arguments")
		}
		if args[0] == "submit-handoff" {
			handoff, parseErr := parseHandoff(raw)
			if parseErr != nil {
				return nil, parseErr
			}
			command["handoff"] = handoff
		}
	case "events":
		flags := flag.NewFlagSet("events", flag.ContinueOnError)
		cursor := flags.String("cursor", "", "opaque cursor from an earlier events page")
		limit := flags.Int("limit", 50, "maximum events to return (1..100)")
		follow := flags.Bool("follow", false, "stream events from read.sock until interrupted")
		if err = flags.Parse(args[1:]); err != nil {
			return nil, err
		}
		if flags.NArg() != 0 {
			return nil, errors.New("events does not accept positional arguments")
		}
		if *limit < 1 || *limit > 100 {
			return nil, errors.New("events limit must be between 1 and 100")
		}
		cursorSet, limitSet := false, false
		flags.Visit(func(f *flag.Flag) {
			cursorSet = cursorSet || f.Name == "cursor"
			limitSet = limitSet || f.Name == "limit"
		})
		if cursorSet {
			if *cursor == "" {
				return nil, errors.New("events cursor must be nonempty")
			}
			command["cursor"] = *cursor
		}
		command["limit"] = *limit
		if *follow {
			if limitSet {
				return nil, errors.New("events --follow does not accept --limit")
			}
			if out == nil {
				return nil, errors.New("events --follow requires streaming output")
			}
			return nil, followEventsCommand(dir, *cursor, out)
		}
	case "output":
		var follow bool
		command, follow, err = parseOutput(args[1:])
		if err != nil {
			return nil, err
		}
		if follow {
			if out == nil {
				return nil, errors.New("output --follow requires streaming output")
			}
			worker, _ := command["worker_id"].(string)
			return nil, followOutput(out, worker)
		}
	case "status", "release":
		flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
		workerFlag(flags, command)
		if err = flags.Parse(args[1:]); err != nil {
			return nil, err
		}
		if flags.NArg() != 0 {
			return nil, errors.New("unexpected arguments")
		}
		if args[0] == "release" && command["worker_id"] == nil {
			return nil, errors.New("use release --worker NAME; it clears the stop latch and starts nothing")
		}
	case "stop", "kill":
		flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
		workerFlag(flags, command)
		turnFlag(flags, command)
		if err = flags.Parse(args[1:]); err != nil {
			return nil, err
		}
		if flags.NArg() != 0 {
			return nil, errors.New("unexpected arguments")
		}
		if command["worker_id"] == nil || command["turn_id"] == nil {
			return nil, fmt.Errorf("use %s --worker NAME --turn TURN_ID; the exact current turn is required", args[0])
		}
	case "turns":
		if len(args) != 1 {
			return nil, errors.New("unexpected arguments")
		}
	default:
		return nil, errors.New("unknown command")
	}
	result, err := request(dir, command)
	if absent(err) {
		return nil, errors.New("Runtime service is stopped; run atlas-runtime service start")
	}
	return result, err
}

// eventReader retains incomplete records across EOF while the native log grows.
type eventReader struct {
	reader   *bufio.Reader
	pending  []byte
	turnID   string
	workerID string
	encoder  *json.Encoder
}

func (events *eventReader) drain(final bool) error {
	for {
		line, err := events.reader.ReadBytes('\n')
		if len(events.pending) == 0 {
			events.pending = line
		} else {
			events.pending = append(events.pending, line...)
		}
		if err != nil && err != io.EOF {
			return err
		}
		if len(events.pending) != 0 && (err == nil || final) {
			if !json.Valid(events.pending) {
				return errors.New("native output contains an invalid or truncated JSON event")
			}
			if writeErr := events.encoder.Encode(map[string]any{
				"type": "event", "turn_id": events.turnID, "worker_id": events.workerID, "event": json.RawMessage(events.pending),
			}); writeErr != nil {
				return writeErr
			}
			events.pending = nil
		}
		if err == io.EOF {
			return nil
		}
	}
}

func followOutput(out io.Writer, worker string) error {
	statusArgs := []string{"status"}
	if worker != "" {
		statusArgs = append(statusArgs, "--worker", worker)
	}
	current, err := execute(statusArgs)
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(out)
	if current["state"] == "idle" {
		return encoder.Encode(map[string]any{"type": "result", "turn": current})
	}
	id, idOK := current["id"].(string)
	folder, folderOK := current["artifacts"].(string)
	if !idOK || id == "" || !folderOK || folder == "" {
		return errors.New("Runtime did not provide a turn ID and artifact directory")
	}
	workerID, _ := current["worker_id"].(string)
	if workerID == "" {
		workerID = "default"
	}
	if worker != "" && workerID != worker {
		return errors.New("Runtime returned a different worker while following output")
	}
	statusArgs = []string{"status", "--worker", workerID}
	if err = encoder.Encode(map[string]any{"type": "status", "turn": current}); err != nil {
		return err
	}
	var file *os.File
	defer func() {
		if file != nil {
			file.Close()
		}
	}()
	events := eventReader{turnID: id, workerID: workerID, encoder: encoder}
	for {
		// Stopping and killing still own the execution; only its confirmed end is final.
		state, _ := current["state"].(string)
		final := state != "running" && state != "stopping" && state != "killing"
		if file == nil {
			file, err = os.Open(filepath.Join(folder, "stream.jsonl"))
			if err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
			if file != nil {
				events.reader = bufio.NewReader(file)
			}
		}
		if file != nil {
			if err = events.drain(final); err != nil {
				return err
			}
		}
		if final {
			answer, readErr := os.ReadFile(filepath.Join(folder, "answer.txt"))
			if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
				return readErr
			}
			current["answer"] = nil
			if readErr == nil {
				current["answer"] = string(answer)
			}
			return encoder.Encode(map[string]any{"type": "result", "turn": current})
		}
		time.Sleep(200 * time.Millisecond)
		current, err = execute(statusArgs)
		if err != nil {
			return err
		}
		if current["id"] != id {
			return errors.New("current turn changed while following output; refusing to switch turns")
		}
		currentWorker, _ := current["worker_id"].(string)
		if currentWorker == "" {
			currentWorker = "default"
		}
		if currentWorker != workerID {
			return errors.New("current worker changed while following output; refusing to switch workers")
		}
	}
}

func main() {
	// The connected node needs neither the Runtime home nor the service.
	if len(os.Args) > 1 && os.Args[1] == "node" {
		err := runNode(os.Args[2:])
		fmt.Fprintln(os.Stderr, "atlas-runtime node:", err)
		os.Exit(2)
	}
	if len(os.Args) > 1 && os.Args[1] == "workspace" {
		if err := workspace.Run(os.Args[2:], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "native-host" {
		host.Main(os.Args[2:])
	}
	if len(os.Args) == 2 && (os.Args[1] == "--help" || os.Args[1] == "-h") {
		fmt.Println("atlas-runtime node start|stop|status [--env test|prod] [--machine NAME] [--checkout PATH] [--json]\nThis machine as a node of an Atlas environment, not the standalone service below. Runs the node lifecycle of the checkout: --checkout, else ATLAS_ROOT, else the \"checkout\" in the node's runtime.json (ATLAS_RUNTIME_FILE, else ATLAS_RUNTIME_HOME/runtime.json, else ~/.local/share/atlas/ENV-runtime/runtime.json). The checkout resolves the environment as atlas does (ATLAS_ENV_FILE, else env/ENV.json; prod by default; --env and the file's \"env\" must agree) and an omitted --machine from runtime.json. The Runtime read grant is not passed on. Discovery is a Control read: atlas discover --machine NAME.")
		fmt.Println("atlas-runtime service start|status|stop\natlas-runtime start [--worker NAME] --cwd PATH [--backend codex|claude] [--sandbox read-only|workspace-write | --permissions dedicated-repository|materialized-folder] \"assignment\"\natlas-runtime start [--worker NAME] --repo https://github.com/OWNER/REPO.git --branch NEW_BRANCH [--backend codex|claude] --permissions dedicated-repository \"assignment\"\natlas-runtime continue [--worker NAME] [--turn TURN_ID] \"next assignment\"\natlas-runtime preferences\natlas-runtime preferences --preferred claude --fallback codex [--preferred-model MODEL] [--fallback-model MODEL]\natlas-runtime preferences --reenable claude\natlas-runtime status [--worker NAME]\natlas-runtime stop|kill --worker NAME --turn TURN_ID\natlas-runtime release --worker NAME\natlas-runtime turns\natlas-runtime output [--worker NAME] [--follow | --turn TURN_ID]\nStart uses configured preferences when --backend is omitted; without preferences it uses Codex. An explicit --backend never falls back. Configured models apply to the selected backend. Preferences inspects configuration and eligibility; --reenable claude clears its quota block. Claude defaults to read-only; explicit dedicated-repository uses native sandboxed Bash in an independent repository outside system temp roots. Codex-only materialized-folder runs in a folder published by snapshot materialize under this Runtime home, outside any Git work tree, with no network and no Git; worker commands may write only that folder and owned scratch and read only its record and baseline. Both use their official CLI login. Managed provisioning requires the installed Codex sandbox for Git preparation, including for Claude. Claude workspace-write is refused. Continue requires a finished, stopped or killed turn with a confirmed saved native session (and model, for Claude), retains its worker, backend, model and scope, and starts a new turn from the current files; it never restores a process. One active execution per worker. NAME must match ^[a-z][a-z0-9_-]{0,63}$. Omitted --worker selects the sole registered worker, or default when none exist; multiple workers require an explicit name. --turn selects its recorded worker; an explicit --worker must match. Flags precede assignment text; use -- before an assignment starting with a dash. Follow pins the selected worker and turn. Turns and events include all workers. Service status lists worker states. Stop sends one SIGINT to the turn's process group and never escalates; the turn stays stopping until the whole group is gone. Kill sends SIGKILL and wins over stop; killing ends as killed. Both latch the worker before signalling: start and continue refuse until release, which starts nothing. Service stop stops every running worker the same way and exits only once no owned execution remains; repeat it, or kill the remaining workers.")
		fmt.Println("atlas-runtime events [--cursor CURSOR] [--limit N]\natlas-runtime events --follow [--cursor CURSOR]\nEvents returns one finite page of durable execution events, not native output or task-success claims. Limit defaults to 50 (1..100). Follow streams events from read.sock as JSON lines, one per event, plus {\"reset\":...} for a retention gap or epoch change and {\"cursor\":...} after each page; it reconnects from the last printed cursor and reports {\"reachable\":false,\"reason\":...} and {\"reachable\":true} itself. It never starts the service and exits 0 on SIGINT or SIGTERM.")
		fmt.Println("Claude question opt-in: add --questions to start; continuation retains the saved capability.\natlas-runtime question --worker NAME --turn TURN_ID --question QUESTION_ID\natlas-runtime answer --worker NAME --turn TURN_ID --question QUESTION_ID --answers JSON_OBJECT\nAnswers map exact question texts to strings. Identical repeats return recorded admission without resending; conflicting answers refuse. Admission, delivery, native processing and verified task success are distinct. Codex does not support questions.")
		fmt.Println("Lost-response-safe admission: add --request-id ID to start or continue. Reuse exactly that ID and request to inspect recorded admission without launching twice; changed requests conflict. ID matches ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$. Accepted admission is not verified execution; indeterminate requires operator reconciliation and never auto-resends. recorded_result is the original admission snapshot, not live status.")
		fmt.Println("Explicit coordinator handoff:\natlas-runtime submit-handoff --worker NAME --turn TURN_ID --handoff JSON_OBJECT\natlas-runtime handoff --worker NAME --turn TURN_ID\nDeclaration fields: kind (completion|pull_request), repository_url, branch, base_sha, head_sha, result, verification, limits, remaining_processes; pull_request requires pr_url, completion forbids it. The last three fields are arrays of strings. Stored provenance is coordinator_submitted_declaration, not authenticated native submission or verified task/PR acceptance. Identical repeats return the original record; replacement conflicts. Execution, merge and next assignment remain separate.")
		fmt.Println("Explicit coordinator peer correlation (records only; never dispatches work or answers):\natlas-runtime route-peer-question --worker SENDER --turn TURN --question QUESTION --peer-worker PEER --peer-turn SOURCE\natlas-runtime peer-question --worker SENDER --turn TURN --question QUESTION\natlas-runtime bind-peer-reply --worker SENDER --turn TURN --question QUESTION --response-turn RESPONSE\nContinue and answer remain separate explicit commands. New transitions require the exact live pending sender question; reply binding requires the peer's successful continuation of the recorded source. Provenance is coordinator_routed_declaration, not authenticated native peer delivery. Identical routing repeats return original routed evidence; inspection returns current evidence. Conflicting targets or replies refuse.")
		fmt.Println("Snapshot materialization (Code service required, Runtime service not):\natlas-runtime snapshot materialize --snapshot sha256:HEX --dest NEW_PATH\nVerifies the manifest identity and every archive entry, then publishes the new folder atomically and never replaces an existing path. Keeps a read-only baseline under the Runtime home in snapshots/HEX/ and records the destination in materializations/. No Git runs and no Git metadata is written.")
		fmt.Println("Snapshot preparation (Runtime service, Code and Git not; npm and the installed Codex sandbox required):\natlas-runtime snapshot prepare --dest PATH --npm-ci REPO_PATH[/SUBDIR]\nRuns the one explicit preparation of a freshly materialized, unchanged folder: npm ci --ignore-scripts --no-audit --no-fund in that tracked package folder, from its tracked package-lock.json, which must pin every package to https://registry.npmjs.org/ with a sha512 integrity. No project .npmrc. Runs in the Codex sandbox, which writes only the folder's node_modules and an owned scratch and reaches only registry.npmjs.org, with a scrubbed environment and empty npm user and global configuration. Holds the folder lock that workers and submissions take; refuses while either runs. Kills the process group after 10 minutes and keeps 1 MiB of each of stdout and stderr; nothing is retried. Records a minimal result workers can read and private diagnostics they cannot under the Runtime home in preparations/. Status, diff and submit then skip the node_modules directory. A failed or interrupted preparation keeps the folder and diagnostics and makes the folder not ready: workers refuse it, status, diff and submit still work, and the recovery is a fresh materialization. A repeat reports the recorded result without running again; a result that is not ready exits nonzero.\natlas-runtime snapshot prepare --dest PATH --npm-run REPO_PATH[/SUBDIR] --script NAME --output REPO_PATH/OUT [--output REPO_PATH/OUT]...\nRuns, at most once and only after a succeeded --npm-ci of the same package in an otherwise unchanged folder, npm run --ignore-scripts --offline NAME for a script in the tracked package.json: no pre- or post-scripts. Runs in the Codex sandbox with no network, writing only the declared outputs and an owned scratch; node_modules and the rest of the folder are read-only. Outputs are paths in the package's repository, outside node_modules and the package manifests, not nested and not containing the package folder; an existing one, and every folder above it, is a real directory or, for the output itself, a regular file. Afterwards every tracked file, regenerated ones included, must be byte- and mode-identical to the snapshot, or the preparation fails (changed). Status, diff and submit skip only declared outputs that hold no tracked path, while they are real directories. Same lock, timeout, log cap, environment, records (diagnostics in private/npm-run) and readiness as --npm-ci; node must be on PATH.")
		fmt.Println("Offline snapshot inspection (no Code, Runtime service or Git):\natlas-runtime snapshot status --dest PATH [--path REPO_PATH]...\natlas-runtime snapshot diff --dest PATH [--path REPO_PATH]...\nCompares a materialized folder with its verified baseline and writes to neither. Reports added, deleted, modified (binary flagged), mode, symlink and kind changes sorted by path; diff adds a unified diff per text content change. Symlinks are compared, never followed. --path selects repository paths; without it, files outside every repository are reported as added. Files over 1 MiB are not classified or diffed. Missing or invalid records or baselines fail.")
		fmt.Println("Snapshot change submission (Code service required, Runtime service and Git not):\natlas-runtime snapshot submit --dest PATH [--path REPO_PATH] --change-id UUID\nSends one materialized repository's changes from its verified baseline to Code as a change based on the snapshot's revision and seals it; the result names the sealed revision, nothing is reviewed or integrated. --path may be omitted only with one repository. A clean repository returns state clean and sends nothing. Written files are captured into a private copy and the folder is scanned again before anything is sent; a folder that changed meanwhile is refused. FIFOs, sockets, devices, .git paths, symlinks leaving the repository and files over 64 MiB are refused; empty directories cannot be represented. Repeating the same command and change ID resumes an incomplete submission or returns the sealed revision; different content under the same ID is a conflict. Writes to neither the folder nor its baseline.")
		fmt.Println("Snapshot rebind (Code required, Runtime service stopped):\natlas-runtime snapshot rebind --dest PATH\nMoves a folder materialized before revision handles to the successor snapshot Code names for it, which must have exactly the same entries, repositories and paths. Copies a new baseline from the old one with every file re-hashed, then switches the saved turns bound to the folder's exact old scope, their Claude contexts and the materialization record, so they still continue; admissions, process logs, events and other turns are untouched. Never writes the folder. Backs up every original and journals each step under rebinds/; an interrupted rebind resumes when repeated, and until then the folder's status, diff, submit and scope refuse. Refuses while the Runtime service runs or may be starting, or while a worker owns the folder. A folder that already uses revision handles reports state current. Status, diff and submit of an older folder refuse until it is rebound.")
		return
	}
	result, err := executeTo(os.Args[1:], os.Stdout)
	if err != nil {
		reply := map[string]any{}
		// A preparation that is not ready still reports its recorded result.
		var failure *host.PreparationFailure
		if errors.As(err, &failure) {
			reply = failure.Result()
		}
		reply["error"] = err.Error()
		json.NewEncoder(os.Stdout).Encode(reply)
		os.Exit(1)
	}
	if result != nil {
		json.NewEncoder(os.Stdout).Encode(result)
	}
}
