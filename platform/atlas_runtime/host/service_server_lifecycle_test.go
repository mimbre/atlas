package main

import (
	"bufio"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// The service as `service start` builds and runs it, with server.json in its home: the
// lifecycle reporter checks the model service.exs wires before the service is ready. Its Bus
// endpoint is a closed port, so the link only retries; no Server is needed. The test waits on
// the service's own output, never on a timer, and kills its process group when it ends.
func TestServiceStartsWithServerLifecycleAndItsModel(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	saved := repoRoot
	repoRoot = root
	t.Cleanup(func() { repoRoot = saved })

	dir := socketDirectory(t)
	closed, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := closed.Addr().(*net.TCPAddr).Port
	closed.Close()
	server := fmt.Sprintf(`{"environment":"test","host":"127.0.0.1","port":%d,"machine":"lifecycle-test",`+
		`"token_file":"server.token","workers":["w1"]}`, port)
	if err = os.WriteFile(filepath.Join(dir, "server.json"), []byte(server), 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(dir, "server.token"), []byte("token\n"), 0600); err != nil {
		t.Fatal(err)
	}

	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	build, run := serviceCommands(dir, executable)
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("Runtime build: %v\n%s", err, output)
	}

	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	run.Stdout, run.Stderr = writer, writer
	run.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	err = run.Start()
	writer.Close()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		syscall.Kill(-run.Process.Pid, syscall.SIGKILL)
		run.Wait()
	})

	output := []string{}
	for lines := bufio.NewScanner(reader); lines.Scan(); {
		output = append(output, lines.Text())
		if lines.Text() == "Runtime ready; Atlas core services remain stopped" {
			// runtime.sock keeps guidance only: the operations moved to backend.sock (S2).
			if _, err := request(dir, map[string]any{"command": "service-status"}); err == nil ||
				!strings.Contains(err.Error(), "backend.sock") {
				t.Fatalf("runtime.sock service-status: %v", err)
			}
			// The work contract is served on backend.sock.
			capacity, err := callBackend(dir, workCall{method: "GET", path: "/v1/capacity"})
			if err != nil || capacity["accepting"] != true {
				t.Fatalf("backend.sock capacity = %v, %v", capacity, err)
			}
			// Flow no longer delivers passes: no pass receiver runs beside it, so nothing
			// creates a pass journal under the home.
			if _, err := os.Lstat(filepath.Join(dir, "passes")); !errors.Is(err, fs.ErrNotExist) {
				t.Fatalf("pass journal present after start: %v", err)
			}
			return
		}
	}
	t.Fatalf("the service ended before it was ready:\n%s", strings.Join(output, "\n"))
}
