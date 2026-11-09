package snapshot

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

// canonicalDirectory opens the absolute dest itself, never following a final symlink, and takes
// its canonical path (ancestor symlinks resolved) from the kernel. Unlike resolving the parent
// through symlinks it never stats an ancestor, so a worker whose sandbox denies reading the user
// home above its folder (Codex's denied HOME) still resolves the folder.
func canonicalDirectory(dest string) (string, error) {
	fd, err := syscall.Open(dest, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if errors.Is(err, syscall.ELOOP) || errors.Is(err, syscall.ENOTDIR) {
		// A symlink or file at dest itself; a non-directory ancestor means dest does not exist.
		if _, statErr := os.Lstat(dest); statErr == nil {
			return "", fmt.Errorf("destination %s is not a directory", dest)
		}
	}
	if err != nil {
		return "", fmt.Errorf("destination %s does not exist: %v", dest, err)
	}
	defer syscall.Close(fd)
	path := make([]byte, 1024) // MAXPATHLEN, the size F_GETPATH writes.
	if _, _, errno := syscall.Syscall(syscall.SYS_FCNTL, uintptr(fd), syscall.F_GETPATH, uintptr(unsafe.Pointer(&path[0]))); errno != 0 {
		return "", fmt.Errorf("destination %s does not resolve: %v", dest, errno)
	}
	return string(path[:bytes.IndexByte(path, 0)]), nil
}

// clone creates the new file to as an APFS copy-on-write clone of the regular file from, with its
// mode, through clonefileat(2) (syscall 462), never following a symlink at from. Only metadata is
// written; blocks are shared until either side changes. A filesystem without clones gives ENOTSUP
// and another volume EXDEV, which the caller answers with a streamed copy.
func clone(from, to string) error {
	source, err := syscall.BytePtrFromString(from)
	if err != nil {
		return err
	}
	target, err := syscall.BytePtrFromString(to)
	if err != nil {
		return err
	}
	atFDCWD, cloneNoFollow := -2, 0x0001 // AT_FDCWD on macOS, CLONE_NOFOLLOW
	if _, _, errno := syscall.Syscall6(462, uintptr(atFDCWD), uintptr(unsafe.Pointer(source)), uintptr(atFDCWD), uintptr(unsafe.Pointer(target)), uintptr(cloneNoFollow), 0); errno != 0 {
		return &os.LinkError{Op: "clonefile", Old: from, New: to, Err: errno}
	}
	return nil
}

// freeBytes is the space available to this user on the filesystem holding path.
func freeBytes(path string) (int64, error) {
	var s syscall.Statfs_t
	if err := syscall.Statfs(path, &s); err != nil {
		return 0, err
	}
	return int64(s.Bavail) * int64(s.Bsize), nil
}
