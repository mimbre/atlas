package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

// The connected node: this machine as a node of an Atlas environment, as opposed to the
// standalone service the rest of this CLI drives. The node's lifecycle stays in the checkout
// (tools/runtime.py and tools/runtime_process.py); this only finds that checkout and hands it
// the operation. It resolves no environment file and touches no Fly, keychain or Runtime home.
const nodeUsage = "use node start|stop|status [--env test|prod] [--machine NAME] [--checkout PATH] [--json]"

// nodeLaunch is the argv that runs one node operation: python3 is argv[0]. Every argument
// but --env and --checkout passes on in order; the checkout's contract validates them.
func nodeLaunch(args []string, getenv func(string) string) ([]string, error) {
	if len(args) == 0 {
		return nil, errors.New(nodeUsage)
	}
	op := args[0]
	if op != "start" && op != "stop" && op != "status" {
		return nil, errors.New(nodeUsage)
	}
	env, checkout, rest := "", "", []string{}
	for i := 1; i < len(args); i++ {
		name, value, inline := strings.Cut(args[i], "=")
		if name != "--env" && name != "--checkout" {
			rest = append(rest, args[i])
			continue
		}
		if !inline {
			if i+1 >= len(args) {
				value = ""
			} else {
				i++
				value = args[i]
			}
		}
		if value == "" {
			if name == "--env" {
				return nil, errors.New("--env needs test or prod")
			}
			return nil, errors.New("--checkout needs a path")
		}
		if name == "--env" {
			env = value
		} else {
			checkout = value
		}
	}
	if checkout == "" {
		checkout = getenv("ATLAS_ROOT")
	}
	if checkout == "" {
		var err error
		if checkout, err = configuredCheckout(env, getenv); err != nil {
			return nil, err
		}
	}
	checkout, err := filepath.Abs(checkout)
	if err != nil {
		return nil, err
	}
	entry := filepath.Join(checkout, "tools", "runtime.py")
	if info, err := os.Stat(entry); err != nil || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%s has no Runtime node lifecycle (%s)", checkout, entry)
	}
	// An empty environment lets the checkout take it from ATLAS_ENV_FILE, else prod.
	return append([]string{"python3", entry, "runtime-" + op, checkout, env}, rest...), nil
}

// configuredCheckout is the "checkout" the node's runtime.json names, if it names one.
func configuredCheckout(env string, getenv func(string) string) (string, error) {
	file := getenv("ATLAS_RUNTIME_FILE")
	if file == "" {
		if base := getenv("ATLAS_RUNTIME_HOME"); base != "" {
			file = filepath.Join(base, "runtime.json")
		} else {
			if env == "" {
				env = "prod"
			}
			user, err := os.UserHomeDir()
			if err != nil {
				return "", err
			}
			file = filepath.Join(user, ".local", "share", "atlas", env+"-runtime", "runtime.json")
		}
	}
	missing := errors.New("no Atlas checkout: pass --checkout PATH, set ATLAS_ROOT, or name \"checkout\" in " + file)
	data, err := os.ReadFile(file)
	if errors.Is(err, os.ErrNotExist) {
		return "", missing
	} else if err != nil {
		return "", err
	}
	var settings struct {
		Checkout any `json:"checkout"`
	}
	if err = json.Unmarshal(data, &settings); err != nil {
		return "", fmt.Errorf("%s: %w", file, err)
	}
	checkout, ok := settings.Checkout.(string)
	if settings.Checkout != nil && (!ok || checkout == "") {
		return "", fmt.Errorf("%s: \"checkout\" must be a path", file)
	}
	if !ok {
		return "", missing
	}
	if strings.HasPrefix(checkout, "~/") {
		user, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		checkout = filepath.Join(user, checkout[2:])
	}
	return checkout, nil
}

// nodeEnvironment is this process's environment without the Runtime read grant: it belongs
// to `atlas discover` alone, never to the node's lifecycle.
func nodeEnvironment() []string {
	result := []string{}
	for _, item := range os.Environ() {
		if !strings.HasPrefix(item, "ATLAS_RUNTIME_READ_TOKEN=") {
			result = append(result, item)
		}
	}
	return result
}

// runNode replaces this process with the checkout's lifecycle, so its output and exit
// status are the operation's own. It returns only when the launch itself fails.
func runNode(args []string) error {
	argv, err := nodeLaunch(args, os.Getenv)
	if err != nil {
		return err
	}
	python, err := exec.LookPath(argv[0])
	if err != nil {
		return err
	}
	return syscall.Exec(python, argv, nodeEnvironment())
}
