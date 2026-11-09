package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// With ATLAS_RUNTIME_TEST_MAIN set, the test binary is the CLI itself, so a test can run
// `atlas-runtime node …` as a separate process and see what it execs.
func TestMain(m *testing.M) {
	if os.Getenv("ATLAS_RUNTIME_TEST_MAIN") == "1" {
		os.Args = append([]string{"atlas-runtime"}, os.Args[1:]...)
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// fakeCheckout is a folder with a node lifecycle entry, as a checkout has.
func fakeCheckout(t *testing.T) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err = os.MkdirAll(filepath.Join(dir, "tools"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(dir, "tools", "runtime.py"), []byte("# lifecycle\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func lookup(values map[string]string) func(string) string {
	return func(name string) string { return values[name] }
}

func TestNodeLaunchPassesTheOperationToTheCheckout(t *testing.T) {
	checkout := fakeCheckout(t)
	entry := filepath.Join(checkout, "tools", "runtime.py")
	for _, test := range []struct {
		args []string
		want []string
	}{
		{[]string{"start", "--checkout", checkout}, []string{"python3", entry, "runtime-start", checkout, ""}},
		{[]string{"stop", "--env", "test", "--checkout=" + checkout}, []string{"python3", entry, "runtime-stop", checkout, "test"}},
		// --env anywhere; everything else stays in order for the checkout's own options.
		{[]string{"status", "--machine", "m", "--checkout", checkout, "--json", "--env=prod"},
			[]string{"python3", entry, "runtime-status", checkout, "prod", "--machine", "m", "--json"}},
		{[]string{"status", "--checkout", checkout, "--unknown", "x"},
			[]string{"python3", entry, "runtime-status", checkout, "", "--unknown", "x"}},
	} {
		got, err := nodeLaunch(test.args, lookup(nil))
		if err != nil {
			t.Fatalf("%v: %v", test.args, err)
		}
		if !reflect.DeepEqual(got, test.want) {
			t.Fatalf("%v:\n got %q\nwant %q", test.args, got, test.want)
		}
	}
}

func TestNodeLaunchRefusesWhatItCannotRun(t *testing.T) {
	checkout := fakeCheckout(t)
	for _, args := range [][]string{
		nil,
		{"discover", "--machine", "m", "--checkout", checkout},
		{"restart", "--checkout", checkout},
		{"--env", "test"},
		{"status", "--checkout", checkout, "--env"},
		{"status", "--checkout", checkout, "--env="},
		{"status", "--checkout"},
		{"status", "--checkout", t.TempDir()},
	} {
		if got, err := nodeLaunch(args, lookup(nil)); err == nil {
			t.Fatalf("%q launched %q", args, got)
		}
	}
}

func TestNodeLaunchFindsTheCheckout(t *testing.T) {
	flag, root, configured := fakeCheckout(t), fakeCheckout(t), fakeCheckout(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	write := func(path, text string) string {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	record := `{"env":"test","checkout":"` + configured + `"}`
	file := write(filepath.Join(t.TempDir(), "runtime.json"), record)
	instance := t.TempDir()
	write(filepath.Join(instance, "runtime.json"), record)
	write(filepath.Join(home, ".local/share/atlas/test-runtime/runtime.json"), record)
	checkoutOf := func(args []string, env map[string]string) (string, error) {
		argv, err := nodeLaunch(append([]string{"status"}, args...), lookup(env))
		if err != nil {
			return "", err
		}
		return argv[3], nil
	}
	for _, test := range []struct {
		args []string
		env  map[string]string
		want string
	}{
		{[]string{"--checkout", flag}, map[string]string{"ATLAS_ROOT": root, "ATLAS_RUNTIME_FILE": file}, flag},
		{nil, map[string]string{"ATLAS_ROOT": root, "ATLAS_RUNTIME_FILE": file}, root},
		{nil, map[string]string{"ATLAS_RUNTIME_FILE": file}, configured},
		{nil, map[string]string{"ATLAS_RUNTIME_HOME": instance}, configured},
		{[]string{"--env", "test"}, nil, configured},
	} {
		got, err := checkoutOf(test.args, test.env)
		if err != nil || got != test.want {
			t.Fatalf("%v %v: got %q, %v; want %q", test.args, test.env, got, err, test.want)
		}
	}
	// The default node is prod's; with none configured, nothing runs.
	if got, err := checkoutOf(nil, nil); err == nil || !strings.Contains(err.Error(), "--checkout") {
		t.Fatalf("no checkout: got %q, %v", got, err)
	}
	for _, text := range []string{`{"env":"test"}`, `{"checkout":""}`, `{"checkout":7}`, `not json`} {
		write(file, text)
		if got, err := checkoutOf(nil, map[string]string{"ATLAS_RUNTIME_FILE": file}); err == nil {
			t.Fatalf("%s: launched %q", text, got)
		}
	}
	// A relative --checkout is the caller's.
	t.Chdir(filepath.Dir(flag))
	if got, err := checkoutOf([]string{"--checkout", filepath.Base(flag)}, nil); err != nil || got != flag {
		t.Fatalf("relative checkout: got %q, %v", got, err)
	}
}

// The CLI execs the checkout's lifecycle with python3 from PATH, passes its exit status
// through, and keeps the Runtime read grant from it.
func TestNodeExecsTheCheckoutLifecycleWithoutTheReadGrant(t *testing.T) {
	checkout := fakeCheckout(t)
	bin := t.TempDir()
	capture := filepath.Join(t.TempDir(), "capture")
	fake := "#!/bin/sh\n{ printf '%s\\n' \"$@\"; echo \"--\"; env | grep '^ATLAS_' | sort; } > \"$NODE_CAPTURE\"\nexit 7\n"
	if err := os.WriteFile(filepath.Join(bin, "python3"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	run := func(args ...string) (*exec.Cmd, []byte, error) {
		cmd := exec.Command(os.Args[0], args...)
		cmd.Env = append(os.Environ(), "ATLAS_RUNTIME_TEST_MAIN=1", "PATH="+bin+string(os.PathListSeparator)+"/usr/bin:/bin", "NODE_CAPTURE="+capture,
			"ATLAS_RUNTIME_READ_TOKEN=private-read-synthetic", "ATLAS_ROOT=", "ATLAS_RUNTIME_FILE="+filepath.Join(bin, "none.json"))
		output, err := cmd.CombinedOutput()
		return cmd, output, err
	}
	cmd, output, _ := run("node", "stop", "--env", "test", "--machine", "m", "--json", "--checkout", checkout)
	if cmd.ProcessState.ExitCode() != 7 {
		t.Fatalf("exit %d, want the lifecycle's 7: %s", cmd.ProcessState.ExitCode(), output)
	}
	captured, err := os.ReadFile(capture)
	if err != nil {
		t.Fatal(err)
	}
	argv, env, _ := strings.Cut(string(captured), "--\n")
	want := strings.Join([]string{filepath.Join(checkout, "tools", "runtime.py"), "runtime-stop", checkout, "test", "--machine", "m", "--json"}, "\n") + "\n"
	if argv != want {
		t.Fatalf("argv:\n%s\nwant:\n%s", argv, want)
	}
	if !strings.Contains(env, "ATLAS_RUNTIME_TEST_MAIN=1") {
		t.Fatalf("the fake did not capture the environment:\n%s", env)
	}
	if strings.Contains(env, "ATLAS_RUNTIME_READ_TOKEN") || strings.Contains(env, "private-read-synthetic") {
		t.Fatalf("the read grant reached the lifecycle:\n%s", env)
	}
	os.Remove(capture)
	// Without a checkout, nothing runs and the launch exits 2.
	cmd, output, _ = run("node", "status", "--env", "test")
	if cmd.ProcessState.ExitCode() != 2 || !strings.Contains(string(output), "--checkout") {
		t.Fatalf("exit %d: %s", cmd.ProcessState.ExitCode(), output)
	}
	if _, err := os.Stat(capture); !os.IsNotExist(err) {
		t.Fatal("the lifecycle ran without a checkout")
	}
}
