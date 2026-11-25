package main

// The Runtime's one update command (IS-Atlas-116, IS-Atlas-26): it installs a released
// build of the Runtime, the build Atlas publishes, never a checkout on the machine.
//
//	atlas-runtime update --build BUILD [--from URL|DIR] [--install PATH] [--restart auto|launchd|service|none] [--detach]
//
// A release is one archive per platform, atlas-runtime-BUILD-GOOS-GOARCH.tar.gz, next to its
// .sha256, under FROM/atlas-runtime-BUILD/ (a GitHub release's download path, or a folder).
// It holds release.json ({"build", "goos", "goarch"}), bin/atlas-runtime (built with
// -X main.build=BUILD) and the compiled service (build/, the boot scripts and the umbrella's
// config), so the service starts from it without Mix or Hex (see releaseLayout).
//
// The steps, each refusing before anything changed when it cannot go on:
//  1. take update.lock in the Runtime home, without waiting: another update holds it;
//  2. read service status: refuse while a slot is busy, naming every busy slot. An open
//     Runtime is drained first (so nothing starts meanwhile) and checked again;
//  3. fetch the archive, check its sha256, unpack it into the releases folder and check
//     that it is BUILD for this machine and that its binary says so (version);
//  4. stop the service (it is idle: nothing is cancelled), point the installed command
//     (~/.local/bin/atlas-runtime) at the release's binary, keeping the one it replaced;
//  5. restart: through its launch agent (launchctl kickstart, the same path as at login),
//     or with service start; then wait until service status shows BUILD;
//  6. a Runtime the update drained itself is resumed; a mode someone else set stays.
//
// A start that fails puts the replaced command back and starts that again. The outcome,
// done or the step that failed, is written to update.json in the Runtime home too (the
// Runtime's own upgrade procedure reads it after --detach).

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"syscall"
	"time"
)

// Set at a release build with -ldflags '-X main.build=BUILD'; empty for a checkout build.
var build string

// The launch agent that starts the Runtime at login (macos/install.sh).
const launchAgent = "com.mimbre.atlas-runtime"

var buildName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// Variables for the tests: how long update waits for the restarted Runtime, how it
// restarts it, and how it reads the version of a release's binary.
var (
	updateRestartWait = 3 * time.Minute
	restartRuntime    = restartWith
	releaseVersion    = binaryVersion
)

// releaseLayout says where the service's code is: the release folder the binary sits in
// (bin/atlas-runtime next to release.json), already compiled, or the checkout the binary was
// built with (main.repoRoot), which service start compiles.
func releaseLayout() (root string, prebuilt bool, err error) {
	if executable, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(executable); err == nil {
			candidate := filepath.Dir(filepath.Dir(resolved))
			if _, err := os.Stat(filepath.Join(candidate, "release.json")); err == nil {
				return candidate, true, nil
			}
		}
	}
	if repoRoot == "" {
		return "", false, errors.New("CLI was not built with the Atlas checkout location and is not in a release")
	}
	return repoRoot, false, nil
}

// runtimeBuild is the build this binary reports: its release's, or "checkout".
func runtimeBuild() string {
	if build != "" {
		return build
	}
	return "checkout"
}

func version() map[string]any {
	root, prebuilt, err := releaseLayout()
	result := map[string]any{"build": runtimeBuild(), "release": prebuilt, "goos": runtime.GOOS, "goarch": runtime.GOARCH}
	if err == nil {
		result["root"] = root
	}
	return result
}

// updateRefused is a refusal before anything changed; slots names the busy ones.
type updateRefused struct {
	reason string
	slots  []string
	text   string
}

func (e *updateRefused) Error() string { return e.text }
func (e *updateRefused) Result() map[string]any {
	result := map[string]any{"reason": e.reason, "step": "check"}
	if e.slots != nil {
		result["busy"] = e.slots
	}
	return result
}

// updateFailed is a failure at a step after the checks.
type updateFailed struct {
	step string
	err  error
}

func (e *updateFailed) Error() string          { return e.step + ": " + e.err.Error() }
func (e *updateFailed) Unwrap() error          { return e.err }
func (e *updateFailed) Result() map[string]any { return map[string]any{"step": e.step} }

type updateOptions struct {
	build, from, install, restart, releases string
}

func update(dir string, args []string) (map[string]any, error) {
	flags := flag.NewFlagSet("update", flag.ContinueOnError)
	options := updateOptions{}
	flags.StringVar(&options.build, "build", "", "the released build to install, as Atlas published it")
	flags.StringVar(&options.from, "from", os.Getenv("ATLAS_RUNTIME_RELEASES"), "where the releases are: a URL (https://github.com/OWNER/REPO/releases/download) or a folder; default $ATLAS_RUNTIME_RELEASES")
	flags.StringVar(&options.install, "install", "", "the installed command to point at the release; default ~/.local/bin/atlas-runtime")
	flags.StringVar(&options.restart, "restart", "auto", "how the Runtime is started again: launchd (its launch agent), service (service start), auto (launchd when its agent is loaded) or none")
	detach := flags.Bool("detach", false, "run the update in the background, writing update.log and update.json in the Runtime home, and return at once")
	if err := flags.Parse(args); err != nil {
		return nil, err
	}
	if flags.NArg() != 0 {
		return nil, errors.New("use update --build BUILD [--from URL|DIR] [--install PATH] [--restart auto|launchd|service|none] [--detach]")
	}
	if !buildName.MatchString(options.build) {
		return nil, errors.New("update needs --build BUILD: the released build (letters, digits, '.', '_' or '-')")
	}
	if options.from == "" {
		return nil, errors.New("update needs --from URL|DIR or ATLAS_RUNTIME_RELEASES: where Atlas publishes the Runtime's releases")
	}
	switch options.restart {
	case "auto", "launchd", "service", "none":
	default:
		return nil, errors.New("--restart is auto, launchd, service or none")
	}
	if options.install == "" {
		user, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		options.install = filepath.Join(user, ".local", "bin", "atlas-runtime")
	}
	options.releases = releasesDir()
	if *detach {
		return detachUpdate(dir, args)
	}
	return runUpdate(dir, options)
}

func releasesDir() string {
	if value := os.Getenv("ATLAS_RUNTIME_RELEASES_DIR"); value != "" {
		return value
	}
	user, _ := os.UserHomeDir()
	return filepath.Join(user, ".local", "share", "atlas-runtime", "releases")
}

// detachUpdate checks the lock and the slots as the update will, so a refusal is answered
// at once, then runs the same update in a new session and returns.
func detachUpdate(dir string, args []string) (map[string]any, error) {
	unlock, err := takeUpdateLock(dir)
	if err != nil {
		return nil, err
	}
	_, err = busyCheck(dir)
	unlock()
	if err != nil {
		return nil, err
	}
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	rest := []string{"update"}
	for _, arg := range args {
		if arg != "--detach" && arg != "-detach" {
			rest = append(rest, arg)
		}
	}
	logPath := filepath.Join(dir, "update.log")
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return nil, err
	}
	defer log.Close()
	os.Remove(filepath.Join(dir, "update.json"))
	cmd := exec.Command(executable, rest...)
	cmd.Env = os.Environ()
	cmd.Stdout, cmd.Stderr = log, log
	// Its own session: the update stops the service that may have started it. The outcome
	// file is the new update's from here; an older one would read as its outcome.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err = cmd.Start(); err != nil {
		return nil, err
	}
	pid := cmd.Process.Pid
	cmd.Process.Release()
	return map[string]any{"update": "started", "pid": pid, "log": logPath, "outcome": filepath.Join(dir, "update.json")}, nil
}

// record writes update.json: done with the result, or the step that failed and why.
func record(dir, wanted string, result map[string]any, err error) {
	outcome := map[string]any{"build": wanted, "at": time.Now().UTC().Format(time.RFC3339)}
	if err == nil {
		for key, value := range result {
			outcome[key] = value
		}
		outcome["result"], outcome["state"] = result["state"], "done"
	} else {
		outcome["state"] = "failed"
		outcome["error"] = err.Error()
		var failure interface{ Result() map[string]any }
		if errors.As(err, &failure) {
			for key, value := range failure.Result() {
				outcome[key] = value
			}
		}
	}
	data, _ := json.Marshal(outcome)
	temporary := filepath.Join(dir, "update.json.tmp")
	if os.WriteFile(temporary, append(data, '\n'), 0600) == nil {
		os.Rename(temporary, filepath.Join(dir, "update.json"))
	}
}

// takeUpdateLock holds update.lock until the returned function runs; another update that
// holds it is a refusal, never a wait.
func takeUpdateLock(dir string) (func(), error) {
	lock, err := os.OpenFile(filepath.Join(dir, "update.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		holder, _ := io.ReadAll(io.LimitReader(lock, 64))
		lock.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			text := "update refused: another update holds update.lock"
			if pid := strings.TrimSpace(string(holder)); pid != "" {
				text += " (pid " + pid + ")"
			}
			return nil, &updateRefused{reason: "update_running", text: text + "; wait until it ends"}
		}
		return nil, err
	}
	lock.Truncate(0)
	lock.WriteAt([]byte(fmt.Sprintf("%d\n", os.Getpid())), 0)
	return func() {
		lock.Truncate(0)
		syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
		lock.Close()
	}, nil
}

// busySlots are the slots service status shows busy, sorted.
func busySlots(info map[string]any) []string {
	busy := []string{}
	slots, _ := info["slots"].([]any)
	for _, slot := range slots {
		if slot, ok := slot.(map[string]any); ok && slot["busy"] == true {
			if name, ok := slot["name"].(string); ok {
				busy = append(busy, name)
			}
		}
	}
	sort.Strings(busy)
	return busy
}

func slotsBusy(busy []string) error {
	return &updateRefused{reason: "slot_busy", slots: busy,
		text: fmt.Sprintf("update refused: slot busy: %s; drain the Runtime (atlas-runtime service drain) and wait until service status shows no busy slot",
			strings.Join(busy, ", "))}
}

// busyCheck reads service status: nil info when the service is stopped, a refusal naming
// the busy slots.
func busyCheck(dir string) (map[string]any, error) {
	info, err := runtimeInfo(dir)
	if errors.Is(err, errStopped) {
		return nil, nil
	}
	if err != nil {
		return nil, &updateFailed{step: "check", err: err}
	}
	if busy := busySlots(info); len(busy) != 0 {
		return nil, slotsBusy(busy)
	}
	return info, nil
}

// runUpdate holds update.lock and records its outcome in update.json; an update refused
// for the lock records nothing there, since that file is the lock holder's.
func runUpdate(dir string, options updateOptions) (map[string]any, error) {
	unlock, err := takeUpdateLock(dir)
	if err != nil {
		return nil, err
	}
	defer unlock()
	result, err := updateLocked(dir, options)
	record(dir, options.build, result, err)
	return result, err
}

func updateLocked(dir string, options updateOptions) (map[string]any, error) {
	info, err := busyCheck(dir)
	if err != nil {
		return nil, err
	}
	previous, mode := "", ""
	drained := false
	if info != nil {
		previous, _ = info["runtime_build"].(string)
		mode, _ = info["mode"].(string)
		if mode == "open" {
			// Nothing may start between the check and the stop.
			if info, err = callBackend(dir, workCall{method: http.MethodPost, path: "/v1/control/drain"}); err != nil {
				return nil, &updateFailed{step: "drain", err: err}
			}
			drained = true
			if busy := busySlots(info); len(busy) != 0 {
				callBackend(dir, workCall{method: http.MethodPost, path: "/v1/control/resume"})
				return nil, slotsBusy(busy)
			}
		}
	}
	if previous == options.build {
		if drained {
			callBackend(dir, workCall{method: http.MethodPost, path: "/v1/control/resume"})
		}
		info, _ = runtimeInfo(dir)
		return map[string]any{"build": options.build, "previous_build": previous, "state": "current", "runtime": info}, nil
	}
	reopen := func() {
		if drained {
			callBackend(dir, workCall{method: http.MethodPost, path: "/v1/control/resume"})
		}
	}
	release, err := fetchRelease(options)
	if err != nil {
		reopen()
		return nil, &updateFailed{step: "fetch", err: err}
	}
	if info != nil {
		if _, err = service(dir, []string{"stop"}); err != nil {
			reopen()
			return nil, &updateFailed{step: "stop", err: err}
		}
	}
	replaced, err := installCommand(options.install, filepath.Join(release, "bin", "atlas-runtime"))
	if err != nil {
		// installCommand put the old command back: start that again.
		if info != nil {
			restartRuntime(dir, options)
		}
		return nil, &updateFailed{step: "install", err: err}
	}
	started, err := restartAndWait(dir, options, options.build)
	if err != nil {
		// Back to the command it replaced, started again, so the machine keeps a Runtime.
		if restoreErr := restoreCommand(options.install, replaced); restoreErr == nil {
			restartRuntime(dir, options)
		}
		return nil, &updateFailed{step: "restart", err: err}
	}
	if drained {
		if resumed, err := callBackend(dir, workCall{method: http.MethodPost, path: "/v1/control/resume"}); err == nil {
			started = resumed
		}
	}
	return map[string]any{"build": options.build, "previous_build": previous, "state": "updated",
		"installed": options.install, "release": release, "runtime": started}, nil
}

// fetchRelease puts the release of options.build for this machine in the releases folder,
// checked, and answers its folder. A release already there and complete is reused.
func fetchRelease(options updateOptions) (string, error) {
	target := filepath.Join(options.releases, options.build)
	if checkRelease(target, options.build) == nil {
		return target, nil
	}
	asset := fmt.Sprintf("atlas-runtime-%s-%s-%s.tar.gz", options.build, runtime.GOOS, runtime.GOARCH)
	base := strings.TrimSuffix(options.from, "/") + "/atlas-runtime-" + options.build + "/"
	if err := os.MkdirAll(options.releases, 0700); err != nil {
		return "", err
	}
	archive, err := os.CreateTemp(options.releases, ".download-")
	if err != nil {
		return "", err
	}
	defer os.Remove(archive.Name())
	defer archive.Close()
	digest := sha256.New()
	if err = fetch(base+asset, io.MultiWriter(archive, digest), 512<<20); err != nil {
		return "", err
	}
	var sum strings.Builder
	if err = fetch(base+asset+".sha256", &sum, 4096); err != nil {
		return "", err
	}
	want := strings.Fields(sum.String())
	if len(want) == 0 || !strings.EqualFold(want[0], hex.EncodeToString(digest.Sum(nil))) {
		return "", fmt.Errorf("%s does not match its sha256", asset)
	}
	unpacked, err := os.MkdirTemp(options.releases, ".unpack-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(unpacked)
	if _, err = archive.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	if err = untar(archive, unpacked); err != nil {
		return "", fmt.Errorf("%s: %w", asset, err)
	}
	if err = checkRelease(unpacked, options.build); err != nil {
		return "", err
	}
	os.RemoveAll(target)
	if err = os.Rename(unpacked, target); err != nil {
		return "", err
	}
	return target, nil
}

// checkRelease: release.json names build for this machine, and its binary says so.
func checkRelease(folder, wanted string) error {
	data, err := os.ReadFile(filepath.Join(folder, "release.json"))
	if err != nil {
		return fmt.Errorf("the release has no release.json: %w", err)
	}
	var described struct{ Build, Goos, Goarch string }
	if err = json.Unmarshal(data, &described); err != nil {
		return fmt.Errorf("release.json: %w", err)
	}
	if described.Build != wanted {
		return fmt.Errorf("the release is build %q, not %q", described.Build, wanted)
	}
	if described.Goos != runtime.GOOS || described.Goarch != runtime.GOARCH {
		return fmt.Errorf("the release is for %s/%s, not %s/%s", described.Goos, described.Goarch, runtime.GOOS, runtime.GOARCH)
	}
	said, err := releaseVersion(filepath.Join(folder, "bin", "atlas-runtime"))
	if err != nil {
		return fmt.Errorf("the release's atlas-runtime does not run: %w", err)
	}
	if said != wanted {
		return fmt.Errorf("the release's atlas-runtime is build %q, not %q", said, wanted)
	}
	return nil
}

func binaryVersion(path string) (string, error) {
	output, err := exec.Command(path, "version").Output()
	if err != nil {
		return "", err
	}
	var said struct{ Build string }
	if err = json.Unmarshal(output, &said); err != nil {
		return "", err
	}
	return said.Build, nil
}

// fetch copies a URL (http or https) or a file of a folder to out, at most limit bytes.
func fetch(location string, out io.Writer, limit int64) error {
	var body io.ReadCloser
	if strings.HasPrefix(location, "https://") || strings.HasPrefix(location, "http://") {
		client := &http.Client{Timeout: 10 * time.Minute}
		response, err := client.Get(location)
		if err != nil {
			return err
		}
		if response.StatusCode != http.StatusOK {
			response.Body.Close()
			return fmt.Errorf("%s: HTTP %d", location, response.StatusCode)
		}
		body = response.Body
	} else {
		file, err := os.Open(location)
		if err != nil {
			return err
		}
		body = file
	}
	defer body.Close()
	written, err := io.Copy(out, io.LimitReader(body, limit+1))
	if err == nil && written > limit {
		err = fmt.Errorf("%s is larger than %d bytes", location, limit)
	}
	return err
}

// untar unpacks a gzipped tar of regular files, folders and symlinks into dest; an entry
// outside dest is refused.
func untar(in io.Reader, dest string) error {
	compressed, err := gzip.NewReader(in)
	if err != nil {
		return err
	}
	archive := tar.NewReader(compressed)
	for {
		header, err := archive.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		name := filepath.Clean(header.Name)
		if filepath.IsAbs(name) || name == ".." || strings.HasPrefix(name, "../") {
			return fmt.Errorf("entry %q leaves the release", header.Name)
		}
		path := filepath.Join(dest, name)
		switch header.Typeflag {
		case tar.TypeDir:
			if err = os.MkdirAll(path, 0755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err = os.MkdirAll(filepath.Dir(path), 0755); err != nil {
				return err
			}
			file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_EXCL, os.FileMode(header.Mode)&0755|0400)
			if err != nil {
				return err
			}
			_, err = io.Copy(file, archive)
			file.Close()
			if err != nil {
				return err
			}
		case tar.TypeSymlink:
			if filepath.IsAbs(header.Linkname) || strings.HasPrefix(filepath.Clean(filepath.Join(filepath.Dir(name), header.Linkname)), "..") {
				return fmt.Errorf("symlink %q leaves the release", header.Name)
			}
			if err = os.MkdirAll(filepath.Dir(path), 0755); err != nil {
				return err
			}
			if err = os.Symlink(header.Linkname, path); err != nil {
				return err
			}
		default:
			return fmt.Errorf("entry %q is not a file, folder or symlink", header.Name)
		}
	}
}

// installCommand points install at binary (a symlink, swapped by a rename) and answers
// where the command it replaced is kept: install.previous, or "" when there was none.
func installCommand(install, binary string) (string, error) {
	if err := os.MkdirAll(filepath.Dir(install), 0755); err != nil {
		return "", err
	}
	kept := ""
	if _, err := os.Lstat(install); err == nil {
		kept = install + ".previous"
		os.Remove(kept)
		if err = os.Rename(install, kept); err != nil {
			return "", err
		}
	}
	link := install + ".new"
	os.Remove(link)
	if err := os.Symlink(binary, link); err != nil {
		restoreCommand(install, kept)
		return "", err
	}
	if err := os.Rename(link, install); err != nil {
		restoreCommand(install, kept)
		return "", err
	}
	return kept, nil
}

func restoreCommand(install, kept string) error {
	if kept == "" {
		return os.Remove(install)
	}
	return os.Rename(kept, install)
}

// restartAndWait starts the Runtime again and waits until service status shows wanted.
func restartAndWait(dir string, options updateOptions, wanted string) (map[string]any, error) {
	if options.restart == "none" {
		return map[string]any{"service": "stopped"}, nil
	}
	if err := restartRuntime(dir, options); err != nil {
		return nil, err
	}
	var last error
	for deadline := time.Now().Add(updateRestartWait); time.Now().Before(deadline); time.Sleep(200 * time.Millisecond) {
		info, err := runtimeInfo(dir)
		if err != nil {
			last = err
			continue
		}
		if got, _ := info["runtime_build"].(string); got == wanted {
			return info, nil
		} else {
			last = fmt.Errorf("service status shows build %q, not %q", got, wanted)
		}
	}
	return nil, fmt.Errorf("the Runtime did not come back on build %s within %s: %v", wanted, updateRestartWait, last)
}

// restartWith starts the Runtime through its launch agent, or with the installed command's
// service start.
func restartWith(dir string, options updateOptions) error {
	how := options.restart
	label := os.Getenv("ATLAS_RUNTIME_LAUNCH_AGENT")
	if label == "" {
		label = launchAgent
	}
	domain := fmt.Sprintf("gui/%d/%s", os.Getuid(), label)
	if how == "auto" {
		how = "service"
		if runtime.GOOS == "darwin" && exec.Command("launchctl", "print", domain).Run() == nil {
			how = "launchd"
		}
	}
	var cmd *exec.Cmd
	if how == "launchd" {
		cmd = exec.Command("launchctl", "kickstart", domain)
	} else {
		cmd = exec.Command(options.install, "service", "start")
		cmd.Env = append(os.Environ(), "ATLAS_RUNTIME_HOME="+dir)
	}
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s: %w", strings.Join(cmd.Args, " "), err)
	}
	return nil
}
