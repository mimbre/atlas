//go:build !darwin

package host

import (
	"errors"
	"os/exec"
	"strconv"
	"strings"
	"testing"
)

// processState reads pid's state through ps; any failure other than "no such process" fails the test.
func processState(t *testing.T, pid int) processStatus {
	t.Helper()
	out, err := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "stat=").Output()
	state := strings.TrimSpace(string(out))
	var exit *exec.ExitError
	switch {
	case err == nil && strings.HasPrefix(state, "Z"):
		return processZombie
	case err == nil && state != "":
		return processLive
	case errors.As(err, &exit) && exit.ExitCode() == 1 && state == "":
		return processGone
	}
	t.Fatalf("process state of %d unreadable: %v %q", pid, err, state)
	return processGone
}
