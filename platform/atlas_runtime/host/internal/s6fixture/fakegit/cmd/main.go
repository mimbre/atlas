// Command fakegit is the fake `git` of the S6 repository parity test (plan s6-plan.md, A4).
// Installed under the name `git` it logs its argv and answers from the row's script; installed
// under the name `sandbox` it stands in for the `codex sandbox -P … -C DIR … --` prefix: it
// changes to DIR and runs the command after `--`, which must be `git`, as the fake git.
//
// `git check-ref-format …` is the request's fact (`workspace facts repository`), gathered before
// any plan exists: it is handed to the real git (S6_FAKEGIT_REAL) and not logged.
//
// Environment: S6_FAKEGIT_SCRIPT (the script, JSON), S6_FAKEGIT_LOG (one JSON line per call is
// appended), S6_FAKEGIT_ROOT (the row root; a working directory outside it is logged as "") and
// S6_FAKEGIT_REAL (the real git).
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// Answer is the scripted reply to one argument list.
type Answer struct {
	Stdout string `json:"stdout"`
	Stderr string `json:"stderr"`
	Code   int    `json:"code"`
	// Effect "git_dir" creates a .git stub in the working directory (the default for clone);
	// "none" creates nothing.
	Effect string `json:"effect"`
}

// Call is one logged invocation of git.
type Call struct {
	Argv     []string `json:"argv"`
	Cwd      string   `json:"cwd"`
	Prefixed bool     `json:"prefixed"`
	Prompt   *string  `json:"git_terminal_prompt"`
}

func main() {
	args := os.Args[1:]
	prefixed := false
	if filepath.Base(os.Args[0]) == "sandbox" {
		dir, rest, ok := sandboxArgs(args)
		if !ok {
			fail(2, "fakegit sandbox: want -C DIR [ARG]... -- git [ARG]...")
		}
		if err := os.Chdir(dir); err != nil {
			fail(2, "fakegit sandbox: %v", err)
		}
		args, prefixed = rest[1:], true
	} else if filepath.Base(os.Args[0]) != "git" {
		fail(2, "fakegit: run as git or sandbox, not %s", os.Args[0])
	}
	os.Exit(git(args, prefixed))
}

// sandboxArgs takes the -C directory and everything after "--", which must start with git.
func sandboxArgs(args []string) (string, []string, bool) {
	dir := ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-C":
			if i+1 < len(args) {
				dir = args[i+1]
				i++
			}
		case "--":
			rest := args[i+1:]
			return dir, rest, dir != "" && len(rest) > 0 && rest[0] == "git"
		}
	}
	return "", nil, false
}

func git(args []string, prefixed bool) int {
	if len(args) > 0 && args[0] == "check-ref-format" {
		real := os.Getenv("S6_FAKEGIT_REAL")
		if real == "" {
			fail(2, "fakegit: S6_FAKEGIT_REAL is not set")
		}
		err := syscall.Exec(real, append([]string{"git"}, args...), os.Environ())
		fail(2, "fakegit: %v", err)
	}
	cwd, err := os.Getwd()
	if err != nil {
		fail(2, "fakegit: %v", err)
	}
	logged := cwd
	if root := os.Getenv("S6_FAKEGIT_ROOT"); root == "" || (cwd != root && !strings.HasPrefix(cwd, root+"/")) {
		logged = ""
	}
	call := Call{Argv: append([]string{}, args...), Cwd: logged, Prefixed: prefixed}
	if value, present := os.LookupEnv("GIT_TERMINAL_PROMPT"); present {
		call.Prompt = &value
	}
	appendLog(call)

	// The global options before the subcommand: -c NAME=VALUE pairs and -C DIR.
	dir := cwd
	rest := args
	for len(rest) >= 2 && (rest[0] == "-c" || rest[0] == "-C") {
		if rest[0] == "-C" {
			dir = rest[1]
		}
		rest = rest[2:]
	}
	key := strings.Join(rest, " ")
	answer, scripted := script()[key]
	if !scripted {
		answer = defaultAnswer(rest, dir)
	}
	if answer.Effect == "git_dir" {
		if err := gitDir(dir); err != nil {
			fail(2, "fakegit: %v", err)
		}
	}
	fmt.Fprint(os.Stdout, answer.Stdout)
	fmt.Fprint(os.Stderr, answer.Stderr)
	return answer.Code
}

// defaultAnswer: clone creates a .git stub; the dedicated-scope rev-parse triple answers the
// directory's own top level and .git; anything else succeeds silently.
func defaultAnswer(rest []string, dir string) Answer {
	switch {
	case len(rest) > 0 && rest[0] == "clone":
		return Answer{Effect: "git_dir"}
	case strings.Join(rest, " ") == "rev-parse --path-format=absolute --show-toplevel --git-dir --git-common-dir":
		return Answer{Stdout: dir + "\n" + dir + "/.git\n" + dir + "/.git\n"}
	}
	return Answer{}
}

func gitDir(dir string) error {
	git := dir + "/.git"
	for _, sub := range []string{"", "objects", "refs", "refs/heads", "refs/tags"} {
		if err := os.MkdirAll(filepath.Join(git, sub), 0o755); err != nil {
			return err
		}
	}
	if err := os.WriteFile(git+"/HEAD", []byte("ref: refs/heads/develop\n"), 0o644); err != nil {
		return err
	}
	return os.WriteFile(git+"/config", []byte("[core]\n\tbare = false\n"), 0o644)
}

func script() map[string]Answer {
	answers := map[string]Answer{}
	path := os.Getenv("S6_FAKEGIT_SCRIPT")
	if path == "" {
		return answers
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fail(2, "fakegit: %v", err)
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&answers); err != nil {
		fail(2, "fakegit: script: %v", err)
	}
	return answers
}

func appendLog(call Call) {
	path := os.Getenv("S6_FAKEGIT_LOG")
	if path == "" {
		return
	}
	line, err := json.Marshal(call)
	if err != nil {
		fail(2, "fakegit: %v", err)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		fail(2, "fakegit: %v", err)
	}
	defer file.Close()
	if _, err := file.Write(append(line, '\n')); err != nil {
		fail(2, "fakegit: %v", err)
	}
}

func fail(code int, format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(code)
}
