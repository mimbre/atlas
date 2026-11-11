//go:build !darwin

package snapshot

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// canonicalDirectory resolves the absolute dest's parent through symlinks and requires a real
// directory, not a symlink, at dest itself.
func canonicalDirectory(dest string) (string, error) {
	parent, err := filepath.EvalSymlinks(filepath.Dir(dest))
	if err != nil {
		return "", fmt.Errorf("destination %s does not exist: %v", dest, reason(err))
	}
	dest = filepath.Join(parent, filepath.Base(dest))
	info, err := os.Lstat(dest)
	if err != nil {
		return "", fmt.Errorf("destination %s does not exist: %v", dest, reason(err))
	}
	if !info.IsDir() {
		return "", fmt.Errorf("destination %s is not a directory", dest)
	}
	return dest, nil
}

// clone has no copy-on-write implementation here; the caller falls back to a streamed copy.
func clone(from, to string) error {
	return &os.LinkError{Op: "clonefile", Old: from, New: to, Err: syscall.ENOTSUP}
}

// freeBytes is the space available to this user on the filesystem holding path.
func freeBytes(path string) (int64, error) {
	var s syscall.Statfs_t
	if err := syscall.Statfs(path, &s); err != nil {
		return 0, err
	}
	return int64(s.Bavail) * int64(s.Bsize), nil
}
