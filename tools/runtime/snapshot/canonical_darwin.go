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
