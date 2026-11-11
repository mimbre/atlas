//go:build !darwin

package snapshot

import (
	"fmt"
	"os"
	"path/filepath"
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
