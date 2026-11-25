package main

// The Runtime's one update command (IS-Atlas-26, IS-Atlas-116): service update --build BUILD
// installs a build Atlas released, never a checkout on the machine, and restarts the
// Runtime on it. A supervised upgrade runs it from the Runtime itself (AtlasRuntime.Upgrade,
// with --upgrade ID --detach); a person may run it by hand. Either way it:
//
//  1. takes the home's update.lock, or refuses while another update holds it, naming it;
//  2. refuses while a slot is busy, naming the slots (a Runtime that is open is paused
//     first, so no turn starts between the check and the stop, and opened again on refusal);
//  3. downloads the release (atlas-runtime-BUILD-GOOS-GOARCH.tar.gz of the GitHub release
//     atlas-runtime-BUILD, and its .sha256), checks its SHA-256, and unpacks it into
//     releases/BUILD of the data folder (~/.local/share/atlas-runtime);
//  4. checks that its CLI says it is BUILD (atlas-runtime version), and points the install
//     path (~/.local/bin/atlas-runtime) at it, a symbolic link swapped in one rename;
//  5. stops the Runtime (graceful: no slot is busy) and starts it again through its launch
//     agent (com.mimbre.atlas-runtime, as at login), or with the new CLI's service start when
//     there is none; a Runtime that was stopped stays stopped;
//  6. waits until service status shows BUILD in a new incarnation, and opens it again when
//     it paused it in 2. A Runtime that was draining stays draining: whoever drained it
//     (the supervised upgrade) resumes it.
//
// Every step is recorded in update.json in the home ({upgrade, build, state, step, reason}),
// which the Runtime reports to the work source that ordered the upgrade, also after its restart.
//
// A release is a folder: BUILD (the build's name), bin/atlas-runtime (this CLI, built
// without a checkout location) and the Atlas tree at the release's revision with its
// dependencies. Its CLI finds its tree from its own path (atlasRoot), and gives the Runtime
// ATLAS_RUNTIME_BUILD, which service status shows as runtime_build.

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
	"strconv"
	"strings"
	"syscall"
	"time"
)

// The GitHub releases Atlas publishes the Runtime to (CI job deploy-runtime-release).
const defaultReleases = "https://github.com/mimbre/atlas/releases/download"

// The launch agent that starts the Runtime at login (macos/install.sh).
const launchAgent = "com.mimbre.atlas-runtime"

// The Code service's launch agent (macos/install.sh, IS-Atlas-116): it runs the atlas_code
// release of the release the installed CLI points at, so an update restarts it too.
const codeAgent = "com.mimbre.atlas-code"

// restartWait bounds how long update waits for the Runtime to answer on the new build: the
// first start on a release compiles it. A variable for tests.
var restartWait = 20 * time.Minute

// updatePoll is how often update reads service status while it waits. A variable for tests.
var updatePoll = time.Second

var buildName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

const updateUsage = "use service update --build BUILD [--upgrade ID] [--detach] [--releases URL|DIR] [--install PATH] [--restart auto|launchd|direct|none]"

// atlasRoot is the Atlas tree the Runtime runs from, and the release's build: the checkout
// the CLI was built with (-X main.repoRoot, no build), or the release this CLI is part of
// (RELEASE/bin/atlas-runtime with RELEASE/BUILD). Neither: "".
func atlasRoot() (root, build string) {
	if repoRoot != "" {
		return repoRoot, ""
	}
	executable, err := os.Executable()
	if err != nil {
		return "", ""
	}
	if executable, err = filepath.EvalSymlinks(executable); err != nil {
		return "", ""
	}
	release := filepath.Dir(filepath.Dir(executable))
	content, err := os.ReadFile(filepath.Join(release, "BUILD"))
	if err != nil {
		return "", ""
	}
	build = strings.TrimSpace(string(content))
	if !buildName.MatchString(build) {
		return "", ""
	}
	return release, build
}

// version: the build this CLI is of and the tree it runs the Runtime from.
func version() (map[string]any, error) {
	root, build := atlasRoot()
	if build == "" {
		build = "checkout"
	}
	return map[string]any{"build": build, "root": root}, nil
}

type updateOptions struct {
	build, upgrade, releases, install, restart string
	detach                                     bool
}

// updateRecord is update.json: what the update command did, for the Runtime's report.
type updateRecord struct {
	Upgrade   string `json:"upgrade"`
	Build     string `json:"build"`
	State     string `json:"state"`
	Step      string `json:"step,omitempty"`
	Reason    string `json:"reason,omitempty"`
	FromBuild string `json:"from_build,omitempty"`
	Previous  string `json:"previous,omitempty"`
	PID       int    `json:"pid,omitempty"`
	At        string `json:"at"`
}

func writeRecord(dir string, record updateRecord) {
	record.At = time.Now().UTC().Format(time.RFC3339)
	content, _ := json.Marshal(record)
	path := filepath.Join(dir, "update.json")
	tmp := path + ".tmp"
	if os.WriteFile(tmp, content, 0600) == nil {
		os.Rename(tmp, path)
	}
}

// updateFailure is a refusal or failure at a step, recorded before it is returned.
type updateFailure struct {
	state, step, reason string
}

func (e *updateFailure) Error() string { return e.reason }

func (e *updateFailure) Result() map[string]any {
	return map[string]any{"update": e.state, "step": e.step}
}

func parseUpdate(args []string) (updateOptions, error) {
	flags := flag.NewFlagSet("service update", flag.ContinueOnError)
	options := updateOptions{}
	flags.StringVar(&options.build, "build", "", "the released build to install (the GitHub release atlas-runtime-BUILD)")
	flags.StringVar(&options.upgrade, "upgrade", "", "the supervised upgrade this update is of (set by the Runtime)")
	flags.BoolVar(&options.detach, "detach", false, "run in the background, in its own session, logging to update.log in the home")
	releases := os.Getenv("ATLAS_RUNTIME_RELEASES")
	if releases == "" {
		releases = defaultReleases
	}
	flags.StringVar(&options.releases, "releases", releases, "where the releases are: a URL, or a folder with atlas-runtime-BUILD/ in it")
	user, _ := os.UserHomeDir()
	flags.StringVar(&options.install, "install", filepath.Join(user, ".local", "bin", "atlas-runtime"), "the installed CLI, pointed at the release's")
	flags.StringVar(&options.restart, "restart", "auto", "how the Runtime is started again: launchd (its launch agent), direct (service start), auto (launchd when the agent is installed) or none")
	if err := flags.Parse(args); err != nil {
		return options, err
	}
	if flags.NArg() != 0 || !buildName.MatchString(options.build) {
		return options, errors.New(updateUsage)
	}
	if options.upgrade != "" && !buildName.MatchString(options.upgrade) {
		return options, errors.New("--upgrade must be an upgrade id such as RU-01")
	}
	switch options.restart {
	case "auto", "launchd", "direct", "none":
	default:
		return options, errors.New(updateUsage)
	}
	return options, nil
}

func serviceUpdate(dir string, args []string) (map[string]any, error) {
	options, err := parseUpdate(args)
	if err != nil {
		return nil, err
	}
	lock, holder, err := updateLock(dir)
	if err != nil {
		return nil, err
	}
	if lock == nil {
		return nil, &updateFailure{state: "refused", step: "update", reason: "another update holds the lock: " + holder}
	}
	defer lock.Close()
	if options.detach {
		return detach(dir, lock, args, options)
	}
	return runUpdate(dir, lock, options)
}

// updateLock takes update.lock, or names who holds it (lock nil). A detached update gets
// the lock its parent took as file descriptor 3.
func updateLock(dir string) (lock *os.File, holder string, err error) {
	if os.Getenv("ATLAS_RUNTIME_UPDATE_LOCKED") == "3" {
		os.Unsetenv("ATLAS_RUNTIME_UPDATE_LOCKED")
		return os.NewFile(3, "update.lock"), "", nil
	}
	path := filepath.Join(dir, "update.lock")
	lock, err = os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, "", err
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		content, _ := os.ReadFile(path)
		lock.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			holder = strings.TrimSpace(string(content))
			if holder == "" {
				holder = "an update that has not said which"
			}
			return nil, holder, nil
		}
		return nil, "", err
	}
	return lock, "", nil
}

func holdLock(lock *os.File, options updateOptions) {
	lock.Truncate(0)
	lock.Seek(0, io.SeekStart)
	who := "build " + options.build
	if options.upgrade != "" {
		who = "upgrade " + options.upgrade + " to " + who
	}
	fmt.Fprintf(lock, "%s (pid %d, since %s)\n", who, os.Getpid(), time.Now().UTC().Format(time.RFC3339))
}

// detach records the update running and runs it again in its own session, holding the lock
// it took; it returns at once.
func detach(dir string, lock *os.File, args []string, options updateOptions) (map[string]any, error) {
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	log, err := os.OpenFile(filepath.Join(dir, "update.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return nil, err
	}
	defer log.Close()
	rest := []string{}
	for _, arg := range args {
		if arg != "--detach" && arg != "-detach" && arg != "--detach=true" {
			rest = append(rest, arg)
		}
	}
	holdLock(lock, options)
	writeRecord(dir, updateRecord{Upgrade: options.upgrade, Build: options.build, State: "running", Step: "update"})
	cmd := exec.Command(executable, append([]string{"service", "update"}, rest...)...)
	cmd.Env = append(os.Environ(), "ATLAS_RUNTIME_HOME="+dir, "ATLAS_RUNTIME_UPDATE_LOCKED=3")
	cmd.Stdout, cmd.Stderr = log, log
	cmd.ExtraFiles = []*os.File{lock}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err = cmd.Start(); err != nil {
		writeRecord(dir, updateRecord{Upgrade: options.upgrade, Build: options.build, State: "failed", Step: "update", Reason: err.Error()})
		return nil, err
	}
	pid := cmd.Process.Pid
	cmd.Process.Release()
	return map[string]any{"update": "started", "build": options.build, "pid": pid, "log": filepath.Join(dir, "update.log")}, nil
}

func runUpdate(dir string, lock *os.File, options updateOptions) (map[string]any, error) {
	holdLock(lock, options)
	record := updateRecord{Upgrade: options.upgrade, Build: options.build, State: "running", Step: "update", PID: os.Getpid()}
	writeRecord(dir, record)
	fail := func(state, step, reason string) (map[string]any, error) {
		record.State, record.Step, record.Reason = state, step, reason
		writeRecord(dir, record)
		fmt.Fprintf(os.Stderr, "%s update %s at %s: %s\n", time.Now().UTC().Format(time.RFC3339), state, step, reason)
		return nil, &updateFailure{state: state, step: step, reason: reason}
	}

	// 2. No busy slot, and none starting meanwhile.
	info, err := runtimeInfo(dir)
	running := err == nil
	if err != nil && !errors.Is(err, errStopped) {
		return fail("failed", "update", "service status: "+err.Error())
	}
	paused := false
	if running {
		if busy := busySlots(info); len(busy) > 0 {
			return fail("refused", "update", busyReason(busy))
		}
		if info["mode"] == "open" {
			if _, err = callBackend(dir, workCall{method: http.MethodPost, path: "/v1/control/pause"}); err != nil {
				return fail("failed", "update", "pause: "+err.Error())
			}
			paused = true
			if info, err = runtimeInfo(dir); err != nil {
				return fail("failed", "update", "service status: "+err.Error())
			}
			if busy := busySlots(info); len(busy) > 0 {
				callBackend(dir, workCall{method: http.MethodPost, path: "/v1/control/resume"})
				return fail("refused", "update", busyReason(busy))
			}
		}
		record.FromBuild, _ = info["runtime_build"].(string)
	}
	reopen := func() {
		if paused {
			callBackend(dir, workCall{method: http.MethodPost, path: "/v1/control/resume"})
		}
	}

	// 3, 4. The release, checked and installed.
	release, err := fetchRelease(options)
	if err != nil {
		reopen()
		return fail("failed", "update", err.Error())
	}
	binary := filepath.Join(release, "bin", "atlas-runtime")
	out, err := exec.Command(binary, "version").Output()
	var said map[string]any
	if err != nil || json.Unmarshal(out, &said) != nil || said["build"] != options.build {
		reopen()
		return fail("failed", "update", fmt.Sprintf("the release's CLI does not say it is build %s: %s", options.build, strings.TrimSpace(string(out))))
	}
	if previous, err := os.Readlink(options.install); err == nil {
		record.Previous = previous
	}
	if err = pointAt(options.install, binary); err != nil {
		reopen()
		return fail("failed", "update", "install: "+err.Error())
	}
	if !running {
		record.State, record.Step, record.Reason = "installed", "update", ""
		writeRecord(dir, record)
		return map[string]any{"update": "installed", "build": options.build, "release": release, "service": "stopped"}, nil
	}

	// 5. Stop, and start again on the release.
	record.Step = "restart"
	writeRecord(dir, record)
	incarnation, _ := info["incarnation"].(string)
	if _, err = service(dir, []string{"stop"}); err != nil {
		return fail("failed", "restart", "service stop: "+err.Error())
	}
	how, err := restart(dir, options)
	if err != nil {
		return fail("failed", "restart", err.Error())
	}

	// 6. Back on the release, in a new incarnation.
	for deadline := time.Now().Add(restartWait); ; time.Sleep(updatePoll) {
		info, err = runtimeInfo(dir)
		if err == nil && info["incarnation"] != incarnation && info["incarnation"] != "stopped" {
			if info["runtime_build"] != options.build {
				return fail("failed", "restart", fmt.Sprintf("the Runtime came back on build %v, not %s", info["runtime_build"], options.build))
			}
			break
		}
		if !time.Now().Before(deadline) {
			return fail("failed", "restart", fmt.Sprintf("the Runtime did not come back on build %s within %s (started by %s); see service.log in the Runtime home", options.build, restartWait, how))
		}
	}
	if paused {
		if info, err = callBackend(dir, workCall{method: http.MethodPost, path: "/v1/control/resume"}); err != nil {
			return fail("failed", "restart", "resume: "+err.Error())
		}
	}
	record.State, record.Reason = "installed", ""
	writeRecord(dir, record)
	return map[string]any{"update": "installed", "build": options.build, "release": release, "started_by": how,
		"from_build": record.FromBuild, "incarnation": info["incarnation"], "mode": info["mode"]}, nil
}

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

func busyReason(busy []string) string {
	return "slot busy: " + strings.Join(busy, ", ") + "; the update runs once no slot runs a turn (service drain, then wait)"
}

// pointAt makes path a symbolic link to target, swapped in with one rename.
func pointAt(path, target string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	tmp := path + ".new"
	os.Remove(tmp)
	if err := os.Symlink(target, tmp); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// restart starts the stopped Runtime again: through its launch agent, as at login, or with
// the installed (new) CLI's service start.
func restart(dir string, options updateOptions) (string, error) {
	how := options.restart
	if how == "none" {
		return how, nil
	}
	user, _ := os.UserHomeDir()
	plist := filepath.Join(user, "Library", "LaunchAgents", launchAgent+".plist")
	if how == "auto" {
		how = "direct"
		if _, err := os.Stat(plist); err == nil && runtime.GOOS == "darwin" {
			how = "launchd"
		}
	}
	var cmd *exec.Cmd
	if how == "launchd" {
		// Code first, on the new release (-k: stop the running one), then the Runtime.
		if _, err := os.Stat(filepath.Join(user, "Library", "LaunchAgents", codeAgent+".plist")); err == nil {
			code := exec.Command("launchctl", "kickstart", "-k", "gui/"+strconv.Itoa(os.Getuid())+"/"+codeAgent)
			code.Stdout, code.Stderr = os.Stderr, os.Stderr
			if err := code.Run(); err != nil {
				return how, fmt.Errorf("restart Code by launchd: %w", err)
			}
		}
		cmd = exec.Command("launchctl", "kickstart", "gui/"+strconv.Itoa(os.Getuid())+"/"+launchAgent)
	} else {
		cmd = exec.Command(options.install, "service", "start")
		cmd.Env = append(os.Environ(), "ATLAS_RUNTIME_HOME="+dir)
	}
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	if err := cmd.Run(); err != nil {
		return how, fmt.Errorf("start by %s: %w", how, err)
	}
	return how, nil
}

// dataDir is where releases are unpacked.
func dataDir() string {
	if value := os.Getenv("XDG_DATA_HOME"); value != "" && filepath.IsAbs(value) {
		return filepath.Join(value, "atlas-runtime")
	}
	user, _ := os.UserHomeDir()
	return filepath.Join(user, ".local", "share", "atlas-runtime")
}

func archiveName(build string) string {
	return fmt.Sprintf("atlas-runtime-%s-%s-%s.tar.gz", build, runtime.GOOS, runtime.GOARCH)
}

// fetchRelease downloads, checks and unpacks the release once: releases/BUILD, reused when
// it is there already with its BUILD.
func fetchRelease(options updateOptions) (string, error) {
	releases := filepath.Join(dataDir(), "releases")
	target := filepath.Join(releases, options.build)
	if content, err := os.ReadFile(filepath.Join(target, "BUILD")); err == nil && strings.TrimSpace(string(content)) == options.build {
		return target, nil
	}
	if err := os.MkdirAll(releases, 0755); err != nil {
		return "", err
	}
	name := archiveName(options.build)
	base := strings.TrimSuffix(options.releases, "/") + "/atlas-runtime-" + options.build + "/"
	sum, err := fetch(base+name+".sha256", 1024)
	if err != nil {
		return "", fmt.Errorf("release %s: %w", options.build, err)
	}
	fields := strings.Fields(string(sum))
	if len(fields) == 0 || len(fields[0]) != 64 {
		return "", fmt.Errorf("release %s: %s.sha256 holds no SHA-256", options.build, name)
	}
	archive, err := fetch(base+name, 2<<30)
	if err != nil {
		return "", fmt.Errorf("release %s: %w", options.build, err)
	}
	digest := sha256.Sum256(archive)
	if hex.EncodeToString(digest[:]) != strings.ToLower(fields[0]) {
		return "", fmt.Errorf("release %s: %s does not have the SHA-256 its .sha256 names", options.build, name)
	}
	tmp, err := os.MkdirTemp(releases, "."+options.build+"-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(tmp)
	if err = unpack(archive, tmp); err != nil {
		return "", fmt.Errorf("release %s: %w", options.build, err)
	}
	content, err := os.ReadFile(filepath.Join(tmp, "BUILD"))
	if err != nil || strings.TrimSpace(string(content)) != options.build {
		return "", fmt.Errorf("release %s: its BUILD does not name it", options.build)
	}
	os.RemoveAll(target)
	if err = os.Rename(tmp, target); err != nil {
		return "", err
	}
	return target, nil
}

// fetch reads a URL, or a file when the releases are a folder.
func fetch(location string, limit int64) ([]byte, error) {
	if !strings.Contains(location, "://") || strings.HasPrefix(location, "file://") {
		file, err := os.Open(strings.TrimPrefix(location, "file://"))
		if err != nil {
			return nil, err
		}
		defer file.Close()
		return io.ReadAll(io.LimitReader(file, limit))
	}
	client := &http.Client{Timeout: 10 * time.Minute}
	response, err := client.Get(location)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: %s", location, response.Status)
	}
	return io.ReadAll(io.LimitReader(response.Body, limit))
}

// unpack writes a .tar.gz into dir: directories, regular files and symbolic links that stay
// inside it, nothing else.
func unpack(archive []byte, dir string) error {
	gz, err := gzip.NewReader(strings.NewReader(string(archive)))
	if err != nil {
		return err
	}
	reader := tar.NewReader(gz)
	for {
		header, err := reader.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		name := filepath.Clean(header.Name)
		if name == "." {
			continue
		}
		if filepath.IsAbs(name) || name == ".." || strings.HasPrefix(name, "../") {
			return fmt.Errorf("the archive names %q, outside the release", header.Name)
		}
		path := filepath.Join(dir, name)
		switch header.Typeflag {
		case tar.TypeDir:
			if err = os.MkdirAll(path, 0755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err = os.MkdirAll(filepath.Dir(path), 0755); err != nil {
				return err
			}
			file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(header.Mode)&0755|0600)
			if err != nil {
				return err
			}
			_, err = io.Copy(file, reader)
			file.Close()
			if err != nil {
				return err
			}
		case tar.TypeSymlink:
			resolved := filepath.Clean(filepath.Join(filepath.Dir(name), header.Linkname))
			if filepath.IsAbs(header.Linkname) || resolved == ".." || strings.HasPrefix(resolved, "../") {
				return fmt.Errorf("the archive links %q outside the release", header.Name)
			}
			if err = os.MkdirAll(filepath.Dir(path), 0755); err != nil {
				return err
			}
			if err = os.Symlink(header.Linkname, path); err != nil {
				return err
			}
		case tar.TypeXGlobalHeader:
		default:
			return fmt.Errorf("the archive holds %q, which is not a file, folder or link", header.Name)
		}
	}
}
