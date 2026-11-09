package host

import (
	"errors"
	"fmt"
	"os"
	"sync"
	"syscall"
	"testing"
	"unsafe"
)

// struct kinfo_proc begins with struct extern_proc. On darwin LP64 the p_un union (two proc
// pointers, or a 16-byte timeval), the p_vmspace and p_sigacts pointers (8 bytes each) and the
// 4-byte int p_flag precede char p_stat, so p_stat sits at offset 16+8+8+4 = 36.
const (
	kinfoProcSize        = 648 // sizeof(struct kinfo_proc) on darwin LP64
	externProcStatOffset = 36  // offsetof(struct extern_proc, p_stat)
	processStatRunnable  = 2   // SRUN
	processStatZombie    = 5   // SZOMB
)

var processLayout struct {
	once sync.Once
	err  error
}

// processState reads pid's p_stat through sysctl kern.proc.pid, which a sandbox allows where it
// denies exec of the setuid ps. Any failure to read the state fails the test.
func processState(t *testing.T, pid int) processStatus {
	t.Helper()
	processLayout.once.Do(func() {
		// Layout self-check: this live test process must read as SRUN.
		stat, err := kernelProcessStat(os.Getpid())
		if err == nil && stat != processStatRunnable {
			err = fmt.Errorf("the test process reads as p_stat %d, not SRUN: the kinfo_proc layout is wrong", stat)
		}
		processLayout.err = err
	})
	if processLayout.err != nil {
		t.Fatalf("process state unreadable: %v", processLayout.err)
	}
	stat, err := kernelProcessStat(pid)
	if err != nil {
		t.Fatalf("process state of %d unreadable: %v", pid, err)
	}
	switch {
	case stat < 0:
		return processGone
	case stat == processStatZombie:
		return processZombie
	}
	return processLive
}

// kernelProcessStat is pid's p_stat, or -1 when the kernel has no entry for pid.
func kernelProcessStat(pid int) (int, error) {
	mib := [4]int32{1, 14, 1, int32(pid)} // CTL_KERN, KERN_PROC, KERN_PROC_PID
	var info [kinfoProcSize]byte
	size := uintptr(len(info))
	if _, _, errno := syscall.Syscall6(syscall.SYS___SYSCTL, uintptr(unsafe.Pointer(&mib[0])), uintptr(len(mib)),
		uintptr(unsafe.Pointer(&info[0])), uintptr(unsafe.Pointer(&size)), 0, 0); errno != 0 {
		return 0, fmt.Errorf("sysctl kern.proc.pid: %w", errno)
	}
	switch size {
	case 0:
		return -1, nil
	case kinfoProcSize:
		return int(info[externProcStatOffset]), nil
	}
	return 0, errors.New("sysctl kern.proc.pid returned an unexpected kinfo_proc size")
}
