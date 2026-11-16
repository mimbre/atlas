package host

import (
	"errors"
	"io/fs"
	"os"
)

// removeScratch deletes an owned scratch or private temporary tree that a worker may have made
// read-only. It first gives the owner write (and, for directories, read and search) permission
// on every directory and file in the tree, then removes it. Symbolic links are never followed
// or changed: the walk skips them, and every change goes through an os.Root confined to the
// tree, so a link replaced in between still cannot reach outside it. A missing tree is removed.
func removeScratch(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err == nil && info.IsDir() {
		// The tree itself is owned by this host, beneath a parent the worker cannot write.
		if info.Mode().Perm()&0700 != 0700 {
			os.Chmod(path, info.Mode().Perm()|0700)
		}
		if root, openErr := os.OpenRoot(path); openErr == nil {
			fs.WalkDir(root.FS(), ".", func(name string, entry fs.DirEntry, walkErr error) error {
				if walkErr != nil || name == "." || entry.Type()&fs.ModeSymlink != 0 {
					return nil
				}
				want := fs.FileMode(0200)
				if entry.IsDir() {
					want = 0700
				} else if !entry.Type().IsRegular() {
					return nil
				}
				if current, statErr := root.Lstat(name); statErr == nil && current.Mode().Type() == entry.Type() &&
					current.Mode().Perm()&want != want {
					root.Chmod(name, current.Mode().Perm()|want)
				}
				return nil
			})
			root.Close()
		}
	}
	return os.RemoveAll(path)
}
