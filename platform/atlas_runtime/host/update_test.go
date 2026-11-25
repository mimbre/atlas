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

// fakeRuntime is a Runtime on backend.sock whose mode follows pause, resume and drain, and
// which goes away on stop.
type fakeRuntime struct {
	mu       sync.Mutex
	info     map[string]any
	requests []string
	server   *httptest.Server
}

func startFakeRuntime(t *testing.T, dir string, info map[string]any) *fakeRuntime {
	t.Helper()
	listener, err := net.Listen("unix", filepath.Join(dir, backendSocket))
	if err != nil {
		t.Fatal(err)
	}
	fake := &fakeRuntime{info: info}
	fake.server = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fake.mu.Lock()
		fake.requests = append(fake.requests, r.Method+" "+r.URL.Path)
		status := http.StatusOK
		switch r.URL.Path {
		case "/v1/control/pause":
			fake.info["mode"] = "paused"
		case "/v1/control/resume":
			fake.info["mode"] = "open"
		case "/v1/control/drain":
			fake.info["mode"] = "draining"
		case "/v1/control/stop":
			status = http.StatusAccepted
			go fake.server.Close()
		}
		reply, _ := json.Marshal(fake.info)
		fake.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		w.Write(reply)
	}))
	fake.server.Listener = listener
	fake.server.Start()
	t.Cleanup(fake.server.Close)
	return fake
}

func (f *fakeRuntime) seen() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string{}, f.requests...)
}

func runtimeInfoWith(build, incarnation, mode string, busy bool) map[string]any {
	return map[string]any{"runtime_build": build, "incarnation": incarnation, "mode": mode, "policy_version": float64(3),
		"slots": []any{map[string]any{"name": "dev1", "busy": busy}, map[string]any{"name": "dev2", "busy": false}}}
}

// publish writes the release BUILD as Atlas publishes it, into releases/atlas-runtime-BUILD/:
// a CLI that says its build and, for service start, leaves a mark in the Runtime home.
func publish(t *testing.T, releases, build string, extra ...*tar.Header) {
	t.Helper()
	script := "#!/bin/sh\ncase \"$1\" in\n  version) echo '{\"build\":\"" + build + "\",\"root\":\"release\"}' ;;\n" +
		"  service) touch \"$ATLAS_RUNTIME_HOME/started\" ;;\nesac\n"
	var archive bytes.Buffer
	gz := gzip.NewWriter(&archive)
	writer := tar.NewWriter(gz)
	files := []struct {
		name, content string
		mode          int64
	}{{"BUILD", build + "\n", 0644}, {"bin/atlas-runtime", script, 0755}, {"platform/README", "tree\n", 0644}}
	for _, file := range files {
		writer.WriteHeader(&tar.Header{Name: file.name, Mode: file.mode, Size: int64(len(file.content)), Typeflag: tar.TypeReg})
		writer.Write([]byte(file.content))
	}
	for _, header := range extra {
		writer.WriteHeader(header)
	}
	writer.Close()
	gz.Close()
	folder := filepath.Join(releases, "atlas-runtime-"+build)
	os.MkdirAll(folder, 0755)
	name := fmt.Sprintf("atlas-runtime-%s-%s-%s.tar.gz", build, runtime.GOOS, runtime.GOARCH)
	digest := sha256.Sum256(archive.Bytes())
	os.WriteFile(filepath.Join(folder, name), archive.Bytes(), 0644)
	os.WriteFile(filepath.Join(folder, name+".sha256"), []byte(hex.EncodeToString(digest[:])+"  "+name+"\n"), 0644)
}

func readRecord(t *testing.T, dir string) updateRecord {
	t.Helper()
	var record updateRecord
	content, err := os.ReadFile(filepath.Join(dir, "update.json"))
	if err != nil || json.Unmarshal(content, &record) != nil {
		t.Fatalf("update.json: %s, %v", content, err)
	}
	return record
}

func updateBench(t *testing.T) (dir, releases, install string) {
	dir = socketDirectory(t)
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	other := t.TempDir()
	t.Setenv("XDG_DATA_HOME", filepath.Join(other, "data"))
	releases = filepath.Join(other, "releases")
	install = filepath.Join(other, "bin", "atlas-runtime")
	saved, savedPoll := restartWait, updatePoll
	restartWait, updatePoll = 10*time.Second, 20*time.Millisecond
	t.Cleanup(func() { restartWait, updatePoll = saved, savedPoll })
	return dir, releases, install
}

func TestUpdateInstallsTheReleaseAndRestartsOnIt(t *testing.T) {
	dir, releases, install := updateBench(t)
	publish(t, releases, "b2")
	before := startFakeRuntime(t, dir, runtimeInfoWith("b1", "inc-1", "open", false))

	// The new CLI's service start: the Runtime comes back on b2, in a new incarnation, still
	// paused (the mode outlasts a restart).
	var after *fakeRuntime
	go func() {
		for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
			if _, err := os.Stat(filepath.Join(dir, "started")); err == nil {
				after = startFakeRuntime(t, dir, runtimeInfoWith("b2", "inc-2", "paused", false))
				return
			}
		}
	}()

	result, err := execute([]string{"service", "update", "--build", "b2", "--upgrade", "RU-01",
		"--releases", releases, "--install", install, "--restart", "direct"})
	if err != nil {
		t.Fatal(err)
	}
	if result["update"] != "installed" || result["incarnation"] != "inc-2" || result["mode"] != "open" || result["from_build"] != "b1" {
		t.Fatalf("result: %#v", result)
	}
	target, err := os.Readlink(install)
	if err != nil || target != filepath.Join(dataDir(), "releases", "b2", "bin", "atlas-runtime") {
		t.Fatalf("install points at %q (%v)", target, err)
	}
	if got := strings.Join(before.seen(), ","); !strings.Contains(got, "POST /v1/control/pause") || !strings.HasSuffix(got, "POST /v1/control/stop") {
		t.Fatalf("before the restart: %s", got)
	}
	if got := after.seen(); got[len(got)-1] != "POST /v1/control/resume" {
		t.Fatalf("after the restart: %v", got)
	}
	if record := readRecord(t, dir); record.State != "installed" || record.Step != "restart" || record.Upgrade != "RU-01" || record.Build != "b2" {
		t.Fatalf("record: %#v", record)
	}
}

func TestUpdateRefusesWhileASlotIsBusy(t *testing.T) {
	dir, releases, install := updateBench(t)
	publish(t, releases, "b2")
	fake := startFakeRuntime(t, dir, runtimeInfoWith("b1", "inc-1", "open", true))

	_, err := execute([]string{"service", "update", "--build", "b2", "--releases", releases, "--install", install})
	var failure *updateFailure
	if !errors.As(err, &failure) || failure.state != "refused" || !strings.HasPrefix(err.Error(), "slot busy: dev1;") {
		t.Fatalf("err: %v", err)
	}
	if got := fake.seen(); len(got) != 1 || got[0] != "GET /v1/runtime" {
		t.Fatalf("a busy Runtime is only asked its status: %v", got)
	}
	if _, err := os.Lstat(install); !os.IsNotExist(err) {
		t.Fatalf("nothing is installed: %v", err)
	}
	if record := readRecord(t, dir); record.State != "refused" || record.Step != "update" || !strings.Contains(record.Reason, "dev1") {
		t.Fatalf("record: %#v", record)
	}

	// As the CLI prints it: the refusal, its step and the slot, exit 1.
	printed, code := cli(t, dir, "service", "update", "--build", "b2", "--releases", releases, "--install", install)
	if code != 1 || printed["update"] != "refused" || printed["step"] != "update" || !strings.Contains(printed["error"].(string), "slot busy: dev1") {
		t.Fatalf("cli: %#v, %d", printed, code)
	}
}

func TestUpdateRefusesWhileAnotherUpdateHoldsTheLock(t *testing.T) {
	dir, releases, install := updateBench(t)
	lock, err := os.OpenFile(filepath.Join(dir, "update.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	lock.WriteString("upgrade RU-01 to build b2 (pid 1, since now)\n")

	_, err = execute([]string{"service", "update", "--build", "b3", "--releases", releases, "--install", install})
	if err == nil || err.Error() != "another update holds the lock: upgrade RU-01 to build b2 (pid 1, since now)" {
		t.Fatalf("err: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "update.json")); !os.IsNotExist(err) {
		t.Fatalf("the holder's record is left alone: %v", err)
	}
}

func TestUpdateOfAStoppedRuntimeOnlyInstalls(t *testing.T) {
	dir, releases, install := updateBench(t)
	publish(t, releases, "b2")
	result, err := execute([]string{"service", "update", "--build", "b2", "--releases", releases, "--install", install})
	if err != nil || result["update"] != "installed" || result["service"] != "stopped" {
		t.Fatalf("%#v, %v", result, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "started")); !os.IsNotExist(err) {
		t.Fatal("a stopped Runtime is not started")
	}
}

func TestUpdateRefusesAReleaseItCannotCheck(t *testing.T) {
	for name, setup := range map[string]func(releases string){
		"missing": func(string) {},
		"bad sum": func(releases string) {
			publish(t, releases, "b2")
			path := filepath.Join(releases, "atlas-runtime-b2", archiveName("b2")+".sha256")
			os.WriteFile(path, []byte(strings.Repeat("0", 64)+"\n"), 0644)
		},
		"escapes": func(releases string) {
			publish(t, releases, "b2", &tar.Header{Name: "../evil", Typeflag: tar.TypeSymlink, Linkname: "x"})
		},
	} {
		t.Run(name, func(t *testing.T) {
			dir, releases, install := updateBench(t)
			setup(releases)
			_, err := execute([]string{"service", "update", "--build", "b2", "--releases", releases, "--install", install})
			var failure *updateFailure
			if !errors.As(err, &failure) || failure.state != "failed" || !strings.HasPrefix(err.Error(), "release b2: ") {
				t.Fatalf("err: %v", err)
			}
			if _, err := os.Lstat(install); !os.IsNotExist(err) {
				t.Fatal("nothing is installed")
			}
			if readRecord(t, dir).State != "failed" {
				t.Fatal("recorded failed")
			}
		})
	}
}

func TestUpdateNeedsABuild(t *testing.T) {
	updateBench(t)
	for _, args := range [][]string{{"service", "update"}, {"service", "update", "--build", "../x"}, {"service", "update", "--build", "b2", "extra"}} {
		if _, err := execute(args); err == nil || err.Error() != updateUsage {
			t.Fatalf("%q: %v", args, err)
		}
	}
}
