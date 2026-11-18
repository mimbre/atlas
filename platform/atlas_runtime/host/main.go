// atlas-runtime is a client of the separate Elixir Runtime service.
package main

import (
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

	"github.com/eyra/atlas/platform/atlas_runtime/host/host"
	"github.com/eyra/atlas/platform/atlas_runtime/host/snapshot"
	"github.com/eyra/atlas/platform/atlas_runtime/host/workspace"
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

// serviceCommands builds the Runtime service and runs platform/atlas_runtime/host/service.exs for the home
// dir, with executable as the native host. Both run in the products/software_factory umbrella, the project whose
// deps hold the model the service is wired to with server.json (products/software_factory/mix.exs, D-0083): atlas_runtime's own project has the model neither compiled nor on its code
// path, and no platform app depends on it. The build first fetches the umbrella's Hex dependencies
// as products/software_factory/mix.lock pins them (Plug and Bandit, for the backend); when they are
// all present it changes nothing. The service itself runs without Mix, on the build's ebin paths with
// the configuration host/boot.exs loads: `mix run` starts Mix's PubSub, a loopback TCP listener, and an
// agent machine runs no network listener. elixir expands the ebin wildcard itself.
func serviceCommands(dir, executable string) (build, run *exec.Cmd) {
	project := filepath.Join(repoRoot, "products/software_factory")
	build = exec.Command("mix", "do", "deps.get", "+", "compile", "--warnings-as-errors")
	build.Dir = project
	build.Env = environment(dir)
	output := filepath.Join(dir, "build")
	run = exec.Command("elixir",
		"-pz", filepath.Join(output, "lib", "*", "ebin"), "-pa", filepath.Join(output, "consolidated"),
		"-r", filepath.Join(repoRoot, "platform/atlas_runtime/host/boot.exs"),
		filepath.Join(repoRoot, "platform/atlas_runtime/host/service.exs"), dir)
	run.Dir = project
	run.Env = append(environment(dir), "ATLAS_RUNTIME_EXECUTABLE="+executable)
	return build, run
}

var workerName = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,63}$`)

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

func execute(args []string) (map[string]any, error) {
	return executeTo(args, nil)
}

func executeTo(args []string, out io.Writer) (map[string]any, error) {
	if len(args) == 0 {
		return nil, errors.New("use service start|status|stop [--force]|pause|resume|drain, start|continue --profile PROFILE --cost-class CLASS (--cwd PATH [--permissions P] | --repo URL --branch BRANCH) [--key KEY] [--slot SLOT] [--resume-from TURN_ID] ASSIGNMENT, status [--work WORK_ID | --key KEY | --state STATE --changed-since SEQUENCE], capacity, retry --work WORK_ID [--resume], stop|kill --work WORK_ID [--reason TEXT], output --turn TURN_ID [--cursor CURSOR] [--follow], turns, events [--cursor CURSOR] [--limit N | --follow], answer --worker NAME --turn TURN_ID --question QUESTION_ID --answers JSON_OBJECT, preferences, release --slot SLOT, snapshot materialize --snapshot sha256:HEX --dest NEW_PATH [--read-only], snapshot changes --dest PATH --blobs DIR, snapshot compose --base-id sha256:HEX --change-set FILE --blobs DIR --dest NEW_PATH [--read-only], snapshot prepare --dest PATH --npm-ci REPO_PATH[/SUBDIR] | --npm-run REPO_PATH[/SUBDIR] --script NAME --output REPO_PATH/OUT..., snapshot status|diff --dest PATH [--path REPO_PATH]..., snapshot submit --dest PATH [--path REPO_PATH] --change-id UUID [--fingerprint fpr_HEX], snapshot freeze --dest PATH --turn TURN_ID --packet NEW_PATH --packet-id UUID [--previous PACKET_ID] [--revision REVISION], snapshot findings --packet PATH --turn TURN_ID, snapshot packets --dest PATH, snapshot discard --packet PATH | --packet-id UUID, or snapshot rebind --dest PATH")
	}
	dir, err := home()
	if err != nil {
		return nil, err
	}
	// Offline inspection only reads the home, so it also runs where the home is read-only.
	if len(args) > 1 && args[0] == "snapshot" && (args[1] == "status" || args[1] == "diff" || args[1] == "packets") {
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
	// Operations go to the operations contract on backend.sock (S2).
	switch args[0] {
	case "service":
		return service(dir, args[1:])
	case "preferences":
		return preferences(dir, args[1:])
	case "release":
		return release(dir, args[1:])
	}
	if args[0] == "snapshot" {
		usage := errors.New("use snapshot materialize --snapshot sha256:HEX --dest NEW_PATH [--read-only], snapshot changes --dest PATH --blobs DIR, snapshot compose --base-id sha256:HEX --change-set FILE --blobs DIR --dest NEW_PATH [--read-only], snapshot prepare --dest PATH --npm-ci REPO_PATH[/SUBDIR] | --npm-run REPO_PATH[/SUBDIR] --script NAME --output REPO_PATH/OUT..., snapshot status|diff --dest PATH [--path REPO_PATH]..., snapshot submit --dest PATH [--path REPO_PATH] --change-id UUID [--fingerprint fpr_HEX], snapshot freeze --dest PATH --turn TURN_ID --packet NEW_PATH --packet-id UUID [--previous PACKET_ID] [--revision REVISION], snapshot findings --packet PATH --turn TURN_ID, snapshot packets --dest PATH, snapshot discard --packet PATH | --packet-id UUID, or snapshot rebind --dest PATH")
		if len(args) < 2 || args[1] != "materialize" && args[1] != "changes" && args[1] != "compose" && args[1] != "prepare" && args[1] != "status" && args[1] != "diff" && args[1] != "submit" && args[1] != "rebind" && args[1] != "freeze" && args[1] != "findings" && args[1] != "packets" && args[1] != "discard" {
			return nil, usage
		}
		flags := flag.NewFlagSet("snapshot "+args[1], flag.ContinueOnError)
		dest := new(string)
		if args[1] != "findings" && args[1] != "discard" {
			dest = flags.String("dest", "", "materialized destination folder")
		}
		id, path, paths := new(string), new(string), []string{}
		run, script, approved := new(string), new(string), new(string)
		turn, previous, revision := new(string), new(string), new(string)
		blobs, changeSet, readOnly := new(string), new(string), new(bool)
		switch args[1] {
		case "materialize":
			id = flags.String("snapshot", "", "Code snapshot ID")
			readOnly = flags.Bool("read-only", false, "seal the folder: files without write bits, directories 0555")
		case "changes":
			blobs = flags.String("blobs", "", "folder that keeps every written file's content as <sha256>")
		case "compose":
			id = flags.String("base-id", "", "snapshot whose baseline under the Runtime home the folder starts from")
			changeSet = flags.String("change-set", "", "change set file, as snapshot changes reports it, with base equal to --base-id")
			blobs = flags.String("blobs", "", "folder holding every written file's content as <sha256>")
			readOnly = flags.Bool("read-only", false, "seal the folder: files without write bits, directories 0555")
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
			approved = flags.String("fingerprint", "", "approved repository fingerprint fpr_HEX; refuses other content before contacting Code")
		case "freeze":
			turn = flags.String("turn", "", "ended author turn that ran in --dest")
			path = flags.String("packet", "", "new packet folder, outside --dest, the Runtime home and any Git work tree")
			id = flags.String("packet-id", "", "caller-chosen lowercase UUID; repeat it to get the same packet")
			previous = flags.String("previous", "", "recorded packet this one follows")
			revision = flags.String("revision", "", "revision of the reviewed change this packet is for, recorded in packet.json")
		case "findings":
			path = flags.String("packet", "", "packet folder made by snapshot freeze")
			turn = flags.String("turn", "", "ended review-packet turn that ran in the packet tree")
		case "packets":
		case "discard":
			path = flags.String("packet", "", "packet folder that snapshot freeze made")
			id = flags.String("packet-id", "", "ID of a recorded packet")
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
		if flags.NArg() != 0 || *dest == "" && args[1] != "findings" && args[1] != "discard" || args[1] == "findings" && (*path == "" || *turn == "") || args[1] == "discard" && (*path == "") == (*id == "") || (args[1] == "materialize" || args[1] == "compose" || args[1] == "submit" || args[1] == "freeze") && *id == "" ||
			(args[1] == "changes" || args[1] == "compose") && *blobs == "" || args[1] == "compose" && *changeSet == "" || args[1] == "freeze" && (*turn == "" || *path == "") {
			return nil, usage
		}
		// A preparation is exactly one npm-ci, or one npm-run with its script and outputs.
		if args[1] == "prepare" && ((*path == "") == (*run == "") || *path != "" && (*script != "" || len(paths) > 0) || *run != "" && (*script == "" || len(paths) == 0)) {
			return nil, usage
		}
		switch args[1] {
		case "materialize":
			if *readOnly {
				return snapshot.MaterializeReadOnly(dir, *id, *dest)
			}
			return snapshot.Materialize(dir, *id, *dest)
		case "changes":
			return snapshot.Changes(dir, *dest, *blobs)
		case "compose":
			return snapshot.Compose(dir, *id, *changeSet, *blobs, *dest, *readOnly)
		case "prepare":
			if *run != "" {
				return host.PrepareRun(dir, *dest, *run, *script, paths)
			}
			return host.Prepare(dir, *dest, *path)
		case "submit":
			return snapshot.Submit(dir, *dest, *path, *id, *approved)
		case "rebind":
			return snapshot.Rebind(dir, *dest)
		case "freeze":
			return snapshot.Freeze(dir, *dest, *turn, *path, *id, *previous, *revision)
		case "findings":
			return snapshot.Findings(dir, *path, *turn)
		case "packets":
			return snapshot.Packets(dir, *dest)
		case "discard":
			return snapshot.Discard(dir, *path, *id)
		}
		return snapshot.Inspect(dir, *dest, paths, args[1] == "diff")
	}
	if build, ok := workCommands[args[0]]; ok {
		call, err := build(args[0], args[1:])
		if err != nil {
			return nil, err
		}
		if call.follow {
			if out == nil {
				return nil, errors.New("output --follow requires streaming output")
			}
			return nil, followOutput(dir, call, out)
		}
		return callBackend(dir, call)
	}
	command := map[string]any{"command": args[0]}
	switch args[0] {
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
		follow := flags.Bool("follow", false, "stream events from runtime.sock until interrupted")
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
		// The journal is read on runtime.sock (runtime.read/1 events).
		delete(command, "command")
		return journalRequest(dir, command)
	case "turns":
		if len(args) != 1 {
			return nil, errors.New("unexpected arguments")
		}
		return listTurns(dir)
	default:
		return nil, errors.New("unknown command")
	}
	result, err := request(dir, command)
	if absent(err) {
		return nil, errors.New("Runtime service is stopped; run atlas-runtime service start")
	}
	return result, err
}

// runWorkspace runs workspace args and returns the exit status. The core-only base-import and
// materialize (S5c P6) write a refusal as writeCommandError's JSON, with its code (and an invalid
// base's rule), so the core branches on the code and never on the text; the others write the text.
func runWorkspace(args []string, stdout, stderr io.Writer) int {
	err := workspace.Run(args, stdout)
	if err == nil {
		return 0
	}
	if len(args) > 0 && (args[0] == "base-import" || args[0] == "materialize") {
		writeCommandError(stderr, err)
	} else {
		fmt.Fprintln(stderr, err)
	}
	return 1
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "workspace" {
		if code := runWorkspace(os.Args[2:], os.Stdout, os.Stderr); code != 0 {
			os.Exit(code)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "native-host" {
		host.Main(os.Args[2:])
	}
	// The after-check runner streams its events on stdout and reads stop controls on stdin.
	if len(os.Args) > 1 && os.Args[1] == "host" {
		if len(os.Args) > 2 && os.Args[2] == "check" {
			host.CheckMain(os.Args[3:])
		}
		writeCommandError(os.Stderr, errors.New("use host check --cwd DIR (--scope JSON | --sandbox read-only) --scratch DIR --timeout SEC --grace SEC --tail BYTES -- ARGV..."))
		os.Exit(1)
	}
	if len(os.Args) == 2 && (os.Args[1] == "--help" || os.Args[1] == "-h") {
		printHelp(os.Stdout)
		return
	}
	result, err := executeTo(os.Args[1:], os.Stdout)
	if err != nil {
		writeCommandError(errorStream(os.Args[1:], os.Stdout, os.Stderr), err)
		os.Exit(1)
	}
	if result != nil {
		json.NewEncoder(os.Stdout).Encode(result)
	}
}

// printHelp writes the CLI help.
func printHelp(out io.Writer) {
	fmt.Fprintln(out, "atlas-runtime service start|status|stop [--force]|pause|resume|drain\natlas-runtime start --profile PROFILE --cost-class low|standard|high --cwd PATH [--permissions read-only|workspace-write|materialized-folder] [--title TITLE] [--key KEY] [--slot SLOT] [--resume-from TURN_ID] \"assignment\"\natlas-runtime start --profile PROFILE --cost-class low|standard|high --repo https://github.com/OWNER/REPO.git --branch NEW_BRANCH [--base develop] [--title TITLE] [--key KEY] [--slot SLOT] \"assignment\"\natlas-runtime continue --resume-from TURN_ID --profile PROFILE --cost-class CLASS (--cwd PATH [--permissions P] | --repo URL --branch BRANCH) [--title TITLE] [--key KEY] [--slot SLOT] \"next assignment\"\natlas-runtime status [--work WORK_ID | --key KEY | [--state STATE] [--changed-since SEQUENCE]]\natlas-runtime capacity\natlas-runtime retry --work WORK_ID [--resume]\natlas-runtime stop|kill --work WORK_ID [--reason TEXT]\natlas-runtime output --turn TURN_ID [--cursor CURSOR] [--follow]\natlas-runtime turns\natlas-runtime preferences\natlas-runtime release --slot SLOT\nWork commands are HTTP requests to the work contract on backend.sock in the Runtime home (start and continue: POST /v1/work; status: GET /v1/work; capacity: GET /v1/capacity; retry: POST /v1/work/WORK_ID/attempts; stop and kill: POST /v1/work/WORK_ID/cancel; output: GET /v1/turns/TURN_ID/output). Each prints the Runtime's answer: the work, the list of work with its change sequence, the capacity or one output page; output --follow prints every page from the cursor on, one JSON line each, and returns once a page says ended (the turn has ended and no output follows). The Runtime validates every request; a refusal prints its problem (type, status, reason, detail; at-capacity, HTTP 503, also retry_after and capacity) and exits nonzero. A work states its needs, an execution profile and a cost class, never a backend or model: the Runtime picks the slot and the harness from its human-owned policy.json, queues the work in its local work source, which hands it to the executor as a work source does, and runs one attempt at a time. Start answers once the work is recorded, not when its turn ends; read progress with status and output, or follow events. --title defaults to the assignment's first line; --permissions defaults to read-only; --base must be develop. --key is the client key, sent as Idempotency-Key: the same key with the same request returns the same work, with another request it is a conflict, so a lost reply is safe to repeat. --slot is for a human at this machine. Continue is start with --resume-from: it continues that turn's conversation and workspace, on its slot. Stop cancels gracefully (the turn gets SIGINT, and is killed after the grace period); kill forces at once; both answer with the work, whose current attempt shows the cancel stage. Retry starts the next attempt of a work; --resume continues an interrupted attempt's conversation. Flags precede the assignment; use -- before an assignment starting with a dash. Turns lists the history (GET /v1/turns on backend.sock, every page): each turn's turn_id, slot, state, native_outcome, started_at, ended_at, harness, configured_model, reported_model and conversation_id; the socket's client reads all history, so turns from before work moved to backend.sock are listed too. Events read the journal on runtime.sock. Operations are HTTP requests to the operations contract on backend.sock too (service status: GET /v1/runtime; service pause, resume and drain: POST /v1/control/ACTION; service stop: POST /v1/control/stop; preferences: GET /v1/policy; release: POST /v1/slots/SLOT/release). Service status prints the runtime info: mode (open, paused, draining or stopping), incarnation, runtime_build, policy_version and the slots, each with busy; a stopped Runtime prints {\"service\":\"stopped\"}. Pause takes no new work and starts no buffered work, while running turns continue; drain also returns the work the executor accepted and has not started (work queued at the local source stays queued), and the Runtime stays draining until resume, which opens it again. The mode outlasts a restart. Service stop takes no new work and keeps the buffer, cancels the running turns (--force kills them at once), whose attempts end interrupted and retryable, and returns once backend.sock is gone; it exits nonzero if that takes over 60 s. Preferences prints the policy view, with each option's availability; edit policy.json locally to change the policy. Release clears a slot's stop latch and tells the Runtime that nothing of the slot's turn is left; it starts nothing, and refuses as slot busy while the slot's process is alive. runtime.sock keeps only questions, answers, handoffs, peer correlation and the journal (events).")
	fmt.Fprintln(out, "atlas-runtime events [--cursor CURSOR] [--limit N]\natlas-runtime events --follow [--cursor CURSOR]\nEvents returns one finite page of durable execution events, not native output or task-success claims. Limit defaults to 50 (1..100). Follow streams events from runtime.sock as JSON lines, one per event, plus {\"reset\":...} for a retention gap or epoch change and {\"cursor\":...} after each page; it reconnects from the last printed cursor and reports {\"reachable\":false,\"reason\":...} and {\"reachable\":true} itself. It never starts the service and exits 0 on SIGINT or SIGTERM.")
	fmt.Fprintln(out, "Claude questions, for a turn that recorded the questions capability (the work contract does not offer it in S1):\natlas-runtime question --worker NAME --turn TURN_ID --question QUESTION_ID\natlas-runtime answer --worker NAME --turn TURN_ID --question QUESTION_ID --answers JSON_OBJECT\nAnswers map exact question texts to strings. Identical repeats return recorded admission without resending; conflicting answers refuse. Admission, delivery, native processing and verified task success are distinct. Codex does not support questions.")
	fmt.Fprintln(out, "Explicit coordinator handoff:\natlas-runtime submit-handoff --worker NAME --turn TURN_ID --handoff JSON_OBJECT\natlas-runtime handoff --worker NAME --turn TURN_ID\nDeclaration fields: kind (completion|pull_request), repository_url, branch, base_sha, head_sha, result, verification, limits, remaining_processes; pull_request requires pr_url, completion forbids it. The last three fields are arrays of strings. Stored provenance is coordinator_submitted_declaration, not authenticated native submission or verified task/PR acceptance. Identical repeats return the original record; replacement conflicts. Execution, merge and next assignment remain separate.")
	fmt.Fprintln(out, "Explicit coordinator peer correlation (records only; never dispatches work or answers):\natlas-runtime route-peer-question --worker SENDER --turn TURN --question QUESTION --peer-worker PEER --peer-turn SOURCE\natlas-runtime peer-question --worker SENDER --turn TURN --question QUESTION\natlas-runtime bind-peer-reply --worker SENDER --turn TURN --question QUESTION --response-turn RESPONSE\nContinue and answer remain separate explicit commands. New transitions require the exact live pending sender question; reply binding requires the peer's successful continuation of the recorded source. Provenance is coordinator_routed_declaration, not authenticated native peer delivery. Identical routing repeats return original routed evidence; inspection returns current evidence. Conflicting targets or replies refuse.")
	fmt.Fprintln(out, "Snapshot materialization (Code service required, Runtime service not):\natlas-runtime snapshot materialize --snapshot sha256:HEX --dest NEW_PATH [--read-only]\nVerifies the manifest identity and every archive entry, then publishes the new folder atomically and never replaces an existing path. Keeps a read-only baseline under the Runtime home in snapshots/HEX/ and records the destination in materializations/. No Git runs and no Git metadata is written. With --read-only the folder is sealed like the baseline: files without write bits, directories 0555; the record and baseline are the same. The result names snapshot_id, destination, baseline, repositories and read_only.")
	fmt.Fprintln(out, "Snapshot change sets (no Code, Runtime service or Git):\natlas-runtime snapshot changes --dest PATH --blobs DIR\nReports a materialized or composed folder as a change set against its recorded baseline: {snapshot_id, roots: [{root, entries}], outside}. Every repository path of the baseline is a root, in manifest order, with entries [] when it is unchanged; entries are exactly what submit sends (write: path, op, kind, mode, size, sha256 and target for a symlink; delete: path, op), with paths relative to the root. outside lists the paths outside every repository. Every written file's content is kept as DIR/SHA256 (read-only; an existing blob is kept). Takes the folder lock workers and submissions take and scans twice; the result is printed only when both scans agree. Works on a read-only folder and writes to neither it nor its baseline. On failure it exits nonzero and writes {code, error} to stderr: code not_materialized (no record for PATH), busy (an owner holds the lock), changed_during_scan, unsupported_entry (what submit refuses: a FIFO, socket, device, .git path, symlink leaving its repository or a file over 64 MiB) or io.\natlas-runtime snapshot compose --base-id sha256:HEX --change-set FILE --blobs DIR --dest NEW_PATH [--read-only]\nBuilds the new folder NEW_PATH from the baseline of HEX under the Runtime home plus exactly the change set in FILE ({base, roots}, as snapshot changes prints it, with base equal to --base-id): deletes remove baseline files and symlinks, writes take their content from DIR/SHA256, and every blob's size and sha256 are checked on the copy. Files are APFS clones where the filesystem allows. With --read-only, files lose their write bits and directories are 0555. NEW_PATH must not exist; its parent must. Inside the Runtime home only RUNTIME_HOME/workers/work-NAME is accepted, NAME starting with a lowercase letter, then lowercase letters, digits, _ or -. Publishes by an exclusive rename and records NEW_PATH as a materialization of HEX, so status, diff, submit and changes of it are relative to the same baseline. Never contacts Code. The result is {snapshot_id, destination, read_only}. On failure it exits nonzero, leaves no NEW_PATH and writes {code, error} to stderr: code baseline_missing, invalid_change_set, blob_mismatch, destination_exists, destination_not_allowed or io.")
	fmt.Fprintln(out, "Snapshot preparation (Runtime service, Code and Git not; npm and the installed Codex sandbox required):\natlas-runtime snapshot prepare --dest PATH --npm-ci REPO_PATH[/SUBDIR]\nRuns the one explicit preparation of a freshly materialized, unchanged folder: npm ci --ignore-scripts --no-audit --no-fund in that tracked package folder, from its tracked package-lock.json, which must pin every package to https://registry.npmjs.org/ with a sha512 integrity. No project .npmrc. Runs in the Codex sandbox, which writes only the folder's node_modules and an owned scratch and reaches only registry.npmjs.org, with a scrubbed environment and empty npm user and global configuration. Holds the folder lock that workers and submissions take; refuses while either runs. Kills the process group after 10 minutes and keeps 1 MiB of each of stdout and stderr; nothing is retried. Records a minimal result workers can read and private diagnostics they cannot under the Runtime home in preparations/. Status, diff and submit then skip the node_modules directory. A failed or interrupted preparation keeps the folder and diagnostics and makes the folder not ready: workers refuse it, status, diff and submit still work, and the recovery is a fresh materialization. A repeat reports the recorded result without running again; a result that is not ready exits nonzero.\natlas-runtime snapshot prepare --dest PATH --npm-run REPO_PATH[/SUBDIR] --script NAME --output REPO_PATH/OUT [--output REPO_PATH/OUT]...\nRuns, at most once and only after a succeeded --npm-ci of the same package in an otherwise unchanged folder, npm run --ignore-scripts --offline NAME for a script in the tracked package.json: no pre- or post-scripts. Runs in the Codex sandbox with no network, writing only the declared outputs and an owned scratch; node_modules and the rest of the folder are read-only. Outputs are paths in the package's repository, outside node_modules and the package manifests, not nested and not containing the package folder; an existing one, and every folder above it, is a real directory or, for the output itself, a regular file. Afterwards every tracked file, regenerated ones included, must be byte- and mode-identical to the snapshot, or the preparation fails (changed). Status, diff and submit skip only declared outputs that hold no tracked path, while they are real directories. Same lock, timeout, log cap, environment, records (diagnostics in private/npm-run) and readiness as --npm-ci; node must be on PATH.")
	fmt.Fprintln(out, "Offline snapshot inspection (no Code, Runtime service or Git):\natlas-runtime snapshot status --dest PATH [--path REPO_PATH]...\natlas-runtime snapshot diff --dest PATH [--path REPO_PATH]...\nCompares a materialized folder with its verified baseline and writes to neither. Reports added, deleted, modified (binary flagged), mode, symlink and kind changes sorted by path; diff adds a unified diff per text content change. Symlinks are compared, never followed. --path selects repository paths; without it, files outside every repository are reported as added. Files over 1 MiB are not classified or diffed. Missing or invalid records or baselines fail.")
	fmt.Fprintln(out, "Snapshot change submission (Code service required, Runtime service and Git not):\natlas-runtime snapshot submit --dest PATH [--path REPO_PATH] --change-id UUID [--fingerprint fpr_HEX]\nSends one materialized repository's changes from its verified baseline to Code as a change based on the snapshot's revision and seals it; the result names the sealed revision, nothing is reviewed or integrated. --path may be omitted only with one repository. A clean repository returns state clean and sends nothing. Written files are captured into a private copy and the folder is scanned again before anything is sent; a folder that changed meanwhile is refused. FIFOs, sockets, devices, .git paths, symlinks leaving the repository and files over 64 MiB are refused; empty directories cannot be represented. Repeating the same command and change ID resumes an incomplete submission or returns the sealed revision; different content under the same ID is a conflict. Writes to neither the folder nor its baseline. Every result reports the repository fingerprint: fpr_ plus the SHA-256 of the canonical change request without its change ID, {base_revision, entries, repository, snapshot_id} with sorted keys and entries, so a clean repository has the fingerprint of entries []. With --fingerprint, content with any other fingerprint on either scan exits nonzero before Code is contacted.")
	fmt.Fprintln(out, "Review packet freeze (no Code, Runtime service or Git):\natlas-runtime snapshot freeze --dest PATH --turn TURN_ID --packet NEW_PATH --packet-id UUID [--previous PACKET_ID] [--revision REVISION]\nFreezes a materialized folder after its author turn into a new packet folder for review. The turn must have run in PATH and be finished, stopped or killed. Takes the folder lock workers and submissions take and refuses while another owner holds it. NEW_PATH must not exist, overlap PATH or the Runtime home, or lie in a Git work tree. Scans PATH like submit and refuses what submit refuses, then builds NEW_PATH/tree: each file an APFS clone (copy-on-write) or, where the filesystem cannot clone, a streamed copy; directories 0555, files without write bits. The tree is recorded as a materialization of the same snapshot with the packet ID, a preparation result is copied with it, and the tree is scanned again: content that differs from the first scan is refused (folder changed during freeze) and the packet folder removed. NEW_PATH then holds packet.json (packet and repository fingerprints, entries exactly as submit sends them, the author turn, previous packet, outside paths and incomplete diffs), diff.json (exactly snapshot diff --dest NEW_PATH/tree) and an empty writable findings folder; the Runtime home keeps the authoritative packet.json and diff.json in packets/PACKET_ID/. The packet fingerprint is fpr_ plus the SHA-256 of {repositories: [{fingerprint, path, repository}] sorted by path, snapshot_id, version: 1}; each repository fingerprint is the one submit reports for the same content. --previous must name a recorded packet other than this one; its ID and fingerprint are recorded. --revision, when given, is recorded in packet.json as revision, exactly as given (1 to 255 visible ASCII characters): the revision of the reviewed change the packet is for, which a review pass checks against the revision it reviews. The result is packet.json plus state frozen, the packet folder and cost: elapsed_ms, files, bytes, cloned_files, copied_files, copied_bytes and the free space before and after (disk_used_bytes). A repeat with the same packet ID and arguments returns the recorded packet with state existing; other arguments under a used ID are a conflict. Writes to neither PATH nor its baseline.")
	fmt.Fprintln(out, "Review findings (no Code, Runtime service or Git):\natlas-runtime snapshot findings --packet PATH --turn TURN_ID\nRecords the findings a review pass wrote to PATH/findings/findings.json. PATH is a packet folder made by snapshot freeze; TURN_ID is a review-packet turn of that packet that ran in PATH/tree and is finished, stopped or killed. Takes the tree's lock and refuses while an owner holds it. The tree, packet.json and diff.json must still match the packet (code packet_modified). The file is at most 65536 bytes (64 KiB) of UTF-8 JSON with exactly the fields version 1, packet_id and fingerprint of this packet, verdict (pass, changes_required or uncertain), summary, findings, checked and not_checked (arrays of strings), with no repeated keys; each finding has exactly id (unique), severity (blocking, should-fix or note), repository, path, lines, problem, evidence and direction. repository, path and lines may be null; repository and path are as diff.json names them, the path must be in the tree or its baseline and in that repository, and lines {side: new|old, start, end} must lie within the tree's (new) or baseline's (old) file. pass with a blocking finding is invalid. A missing file is refused with code findings_missing, any other invalid one with findings_invalid; Runtime never writes a verdict and a refusal is never a pass. The result, also written read-only to packets/PACKET_ID/findings/TURN_ID.json in the Runtime home, holds the file (compacted) as findings, the sha256 of its original bytes, review_turn, reviewer {worker_id, backend, model, selection} from the review turn, author {turn_id, worker_id, backend, model, selection} from the packet and its author turn, packet_id, fingerprint and recorded_at, plus state recorded and the record path. A repeat for the same turn with an unchanged file returns the record with state existing; a changed or removed file is a conflict.\natlas-runtime snapshot packets --dest PATH\nLists the packets frozen from PATH, oldest first along their previous links: packet_id, fingerprint, previous, snapshot_id, created_at, author, the packet folder and every findings record. Reads only; PATH need not still exist.")
	fmt.Fprintln(out, "Review packet discard (no Code, Runtime service or Git):\natlas-runtime snapshot discard --packet PATH | --packet-id UUID\nRemoves the folder of a packet made by snapshot freeze, named by its path or its packet ID, with its tree's materialization record and preparation copy. Takes the tree's folder lock and refuses while a review pass or another command holds it. Removes only the folder the packet's record names while its tree is still recorded as that packet: read-only directories and files are made writable first, symbolic links are never followed, and nothing outside the folder is changed. The Runtime home keeps packets/PACKET_ID/ (packet.json, diff.json and the findings records) and stamps discarded.json there with discarded_at. The result is state discarded, the packet ID, packet folder, tree, fingerprint, discarded_at and the kept record. A repeat, by path or ID, reports the same discard; by path it selects the packet not yet discarded when a later freeze reused the path.")
	fmt.Fprintln(out, "Snapshot rebind (Code required, Runtime service stopped):\natlas-runtime snapshot rebind --dest PATH\nMoves a folder materialized before revision handles to the successor snapshot Code names for it, which must have exactly the same entries, repositories and paths. Copies a new baseline from the old one with every file re-hashed, then switches the saved turns bound to the folder's exact old scope, their Claude contexts and the materialization record, so they still continue; admissions, process logs, events and other turns are untouched. Never writes the folder. Backs up every original and journals each step under rebinds/; an interrupted rebind resumes when repeated, and until then the folder's status, diff, submit and scope refuse. Refuses while the Runtime service runs or may be starting, or while a worker owns the folder. A folder that already uses revision handles reports state current. Status, diff and submit of an older folder refuse until it is rebound.")
}

// errorStream is where a failed command reports its error: stderr for snapshot changes and
// compose, whose stdout carries only a result; stdout for every other command, as before.
func errorStream(args []string, stdout, stderr io.Writer) io.Writer {
	if len(args) > 1 && args[0] == "snapshot" && (args[1] == "changes" || args[1] == "compose") {
		return stderr
	}
	return stdout
}

// Preserve typed command results across the CLI boundary, including findings refusal
// codes and preparation readiness. Unclassified errors carry no invented code.
func writeCommandError(out io.Writer, err error) {
	reply := map[string]any{}
	var failure interface {
		error
		Result() map[string]any
	}
	if errors.As(err, &failure) {
		reply = failure.Result()
	}
	reply["error"] = err.Error()
	json.NewEncoder(out).Encode(reply)
}
