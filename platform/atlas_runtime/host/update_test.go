package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// fakeRuntime is a Runtime on backend.sock with a mode and busy slots, that stops on
// POST /v1/control/stop as the real one does (its socket goes).
type fakeRuntime struct {
	mu     sync.Mutex
	build  string
	mode   string
	busy   map[string]bool
	calls  []string
	server *httptest.Server
}

func startFake(t *testing.T, dir, build, mode string, busy map[string]bool) *fakeRuntime {
	t.Helper()
	fake := &fakeRuntime{build: build, mode: mode, busy: busy}
	listener, err := net.Listen("unix", filepath.Join(dir, backendSocket))
	if err != nil {
		t.Fatal(err)
	}
	fake.server = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fake.mu.Lock()
		fake.calls = append(fake.calls, r.Method+" "+r.URL.Path)
		status := http.StatusOK
		stop := false
		switch r.URL.Path {
		case "/v1/control/drain":
			fake.mode = "draining"
		case "/v1/control/resume":
			fake.mode = "open"
		case "/v1/control/stop":
			status, stop = http.StatusAccepted, true
		}
		slots := []any{}
		for _, name := range []string{"dev1", "dev2"} {
			slots = append(slots, map[string]any{"name": name, "busy": fake.busy[name]})
		}
		reply := map[string]any{"runtime_build": fake.build, "incarnation": "inc-" + fake.build, "mode": fake.mode,
			"policy_version": 1, "slots": slots}
		fake.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(reply)
		if stop {
			go fake.server.Close()
		}
	}))
	fake.server.Listener.Close()
	fake.server.Listener = listener
	fake.server.Start()
	t.Cleanup(fake.server.Close)
	return fake
}

func (f *fakeRuntime) seen() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string{}, f.calls...)
}

// publish writes the release of build for this machine under from/atlas-runtime-BUILD/, as
// CI publishes it; its binary is a script that answers version. corrupt spoils the sha256.
func publish(t *testing.T, from, build string, corrupt bool) {
	t.Helper()
	var archive bytes.Buffer
	compressed := gzip.NewWriter(&archive)
	writer := tar.NewWriter(compressed)
	release, _ := json.Marshal(map[string]string{"build": build, "goos": runtime.GOOS, "goarch": runtime.GOARCH})
	for _, file := range []struct {
		name string
		mode int64
		data string
	}{
		{"release.json", 0644, string(release)},
		{"bin/atlas-runtime", 0755, fmt.Sprintf("#!/bin/sh\necho '{\"build\":\"%s\"}'\n", build)},
		{"platform/atlas_runtime/host/service.exs", 0644, "# service\n"},
	} {
		writer.WriteHeader(&tar.Header{Name: file.name, Mode: file.mode, Size: int64(len(file.data)), Typeflag: tar.TypeReg})
		writer.Write([]byte(file.data))
	}
	writer.Close()
	compressed.Close()
	asset := fmt.Sprintf("atlas-runtime-%s-%s-%s.tar.gz", build, runtime.GOOS, runtime.GOARCH)
	folder := filepath.Join(from, "atlas-runtime-"+build)
	os.MkdirAll(folder, 0755)
	if err := os.WriteFile(filepath.Join(folder, asset), archive.Bytes(), 0644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(archive.Bytes())
	if corrupt {
		sum[0] ^= 0xff
	}
	os.WriteFile(filepath.Join(folder, asset+".sha256"), []byte(hex.EncodeToString(sum[:])+"  "+asset+"\n"), 0644)
}

// updateSetup: a Runtime home, a releases folder, an installed command and a restart
// that starts a fake Runtime on the build the installed command's release names.
func updateSetup(t *testing.T) (dir, from, install string, restarts *int) {
	t.Helper()
	dir = socketDirectory(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	work := t.TempDir()
	from = filepath.Join(work, "published")
	install = filepath.Join(work, "bin", "atlas-runtime")
	os.MkdirAll(filepath.Dir(install), 0755)
	os.WriteFile(install, []byte("#!/bin/sh\necho '{\"build\":\"b1\"}'\n"), 0755)
	t.Setenv("ATLAS_RUNTIME_RELEASES_DIR", filepath.Join(work, "releases"))
	restarts = new(int)
	savedRestart, savedWait := restartRuntime, updateRestartWait
	updateRestartWait = 5 * time.Second
	restartRuntime = func(dir string, options updateOptions) error {
		*restarts++
		said, err := binaryVersion(options.install)
		if err != nil {
			return err
		}
		startFake(t, dir, said, "draining", nil)
		return nil
	}
	t.Cleanup(func() { restartRuntime, updateRestartWait = savedRestart, savedWait })
	return dir, from, install, restarts
}

func outcome(t *testing.T, dir string) map[string]any {
	t.Helper()
	var recorded map[string]any
	data, err := os.ReadFile(filepath.Join(dir, "update.json"))
	if err != nil || json.Unmarshal(data, &recorded) != nil {
		t.Fatalf("update.json: %s, %v", data, err)
	}
	return recorded
}

func TestUpdateRefusesWhileASlotIsBusyAndNamesIt(t *testing.T) {
	dir, from, install, restarts := updateSetup(t)
	publish(t, from, "b2", false)
	fake := startFake(t, dir, "b1", "draining", map[string]bool{"dev2": true})

	printed, code := cli(t, dir, "update", "--build", "b2", "--from", from, "--install", install, "--restart", "none")
	if code != 1 || printed["reason"] != "slot_busy" || !strings.Contains(printed["error"].(string), "slot busy: dev2") {
		t.Fatalf("busy slot: exit %d, %v", code, printed)
	}
	if busy, _ := printed["busy"].([]any); len(busy) != 1 || busy[0] != "dev2" {
		t.Fatalf("busy slots named: %v", printed["busy"])
	}
	if got := fake.seen(); len(got) != 1 || got[0] != "GET /v1/runtime" {
		t.Fatalf("a refused update only reads status: %v", got)
	}
	if target, _ := os.Readlink(install); target != "" || *restarts != 0 {
		t.Fatalf("a refused update installs nothing: %q, %d restarts", target, *restarts)
	}
	if recorded := outcome(t, dir); recorded["state"] != "failed" || recorded["reason"] != "slot_busy" {
		t.Fatalf("update.json: %v", recorded)
	}
}

func TestUpdateRefusesWhileAnotherUpdateHoldsTheLock(t *testing.T) {
	dir, from, install, _ := updateSetup(t)
	publish(t, from, "b2", false)
	startFake(t, dir, "b1", "open", nil)
	lock, err := os.OpenFile(filepath.Join(dir, "update.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	lock.WriteString("4242\n")

	printed, code := cli(t, dir, "update", "--build", "b2", "--from", from, "--install", install)
	if code != 1 || printed["reason"] != "update_running" || !strings.Contains(printed["error"].(string), "another update holds update.lock (pid 4242)") {
		t.Fatalf("held lock: exit %d, %v", code, printed)
	}
	printed, code = cli(t, dir, "update", "--build", "b2", "--from", from, "--install", install, "--detach")
	if code != 1 || printed["reason"] != "update_running" {
		t.Fatalf("held lock, detached: exit %d, %v", code, printed)
	}
	// update.json is the lock holder's: a refusal for the lock writes nothing there.
	if _, err := os.Stat(filepath.Join(dir, "update.json")); !os.IsNotExist(err) {
		t.Fatalf("a refusal for the lock wrote update.json: %v", err)
	}
}

func TestUpdateInstallsTheReleasedBuildAndRestartsIt(t *testing.T) {
	dir, from, install, restarts := updateSetup(t)
	publish(t, from, "b2", false)
	old := startFake(t, dir, "b1", "open", nil)

	result, err := execute([]string{"update", "--build", "b2", "--from", from, "--install", install})
	if err != nil {
		t.Fatal(err)
	}
	// Drained before the stop, so nothing started in between.
	if got := strings.Join(old.seen(), ","); got != "GET /v1/runtime,POST /v1/control/drain,POST /v1/control/stop" {
		t.Fatalf("old Runtime: %s", got)
	}
	release := filepath.Join(os.Getenv("ATLAS_RUNTIME_RELEASES_DIR"), "b2")
	if target, _ := os.Readlink(install); target != filepath.Join(release, "bin", "atlas-runtime") {
		t.Fatalf("installed command points at %q", target)
	}
	if said, _ := binaryVersion(install + ".previous"); said != "b1" {
		t.Fatalf("the replaced command is kept: %q", said)
	}
	started, _ := result["runtime"].(map[string]any)
	// It drained an open Runtime itself, so it opens the new one again.
	if *restarts != 1 || result["state"] != "updated" || result["previous_build"] != "b1" ||
		started["runtime_build"] != "b2" || started["mode"] != "open" {
		t.Fatalf("result: %v (%d restarts)", result, *restarts)
	}
	if recorded := outcome(t, dir); recorded["state"] != "done" || recorded["build"] != "b2" {
		t.Fatalf("update.json: %v", recorded)
	}

	// The same build again: nothing to do, and the Runtime is not stopped.
	result, err = execute([]string{"update", "--build", "b2", "--from", from, "--install", install})
	if err != nil || result["state"] != "current" || *restarts != 1 {
		t.Fatalf("again: %v, %v", result, err)
	}
}

func TestUpdateLeavesAModeItDidNotSet(t *testing.T) {
	dir, from, install, _ := updateSetup(t)
	publish(t, from, "b2", false)
	startFake(t, dir, "b1", "draining", nil)

	result, err := execute([]string{"update", "--build", "b2", "--from", from, "--install", install})
	if started, _ := result["runtime"].(map[string]any); err != nil || started["mode"] != "draining" {
		t.Fatalf("drained by someone else stays drained: %v, %v", result, err)
	}
}

func TestUpdateWithABadReleaseChangesNothing(t *testing.T) {
	dir, from, install, restarts := updateSetup(t)
	publish(t, from, "b2", true)
	fake := startFake(t, dir, "b1", "open", nil)

	_, err := execute([]string{"update", "--build", "b2", "--from", from, "--install", install})
	var failed *updateFailed
	if !errors.As(err, &failed) || failed.step != "fetch" || !strings.Contains(err.Error(), "does not match its sha256") {
		t.Fatalf("bad sha256: %v", err)
	}
	if got := strings.Join(fake.seen(), ","); got != "GET /v1/runtime,POST /v1/control/drain,POST /v1/control/resume" {
		t.Fatalf("the Runtime is opened again and never stopped: %s", got)
	}
	if said, _ := binaryVersion(install); said != "b1" || *restarts != 0 {
		t.Fatalf("installed command unchanged: %q, %d restarts", said, *restarts)
	}
	if recorded := outcome(t, dir); recorded["state"] != "failed" || recorded["step"] != "fetch" {
		t.Fatalf("update.json: %v", recorded)
	}

	// A release that is another build than it says is refused too.
	publish(t, from, "b3", false)
	os.Rename(filepath.Join(from, "atlas-runtime-b3"), filepath.Join(from, "atlas-runtime-b4"))
	for _, name := range []string{"", ".sha256"} {
		os.Rename(filepath.Join(from, "atlas-runtime-b4", fmt.Sprintf("atlas-runtime-b3-%s-%s.tar.gz%s", runtime.GOOS, runtime.GOARCH, name)),
			filepath.Join(from, "atlas-runtime-b4", fmt.Sprintf("atlas-runtime-b4-%s-%s.tar.gz%s", runtime.GOOS, runtime.GOARCH, name)))
	}
	if _, err = execute([]string{"update", "--build", "b4", "--from", from, "--install", install}); err == nil ||
		!strings.Contains(err.Error(), `the release is build "b3", not "b4"`) {
		t.Fatalf("mislabelled release: %v", err)
	}
}

func TestVersionOfACheckoutBuild(t *testing.T) {
	if got := version(); got["build"] != "checkout" || got["release"] != false {
		t.Fatalf("version: %v", got)
	}
}
