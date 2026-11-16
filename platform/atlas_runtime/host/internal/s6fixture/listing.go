package s6fixture

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"syscall"
)

// Item is one entry of a built tree, as the self-test compares it. Fields that do not apply
// to the type are null: mode for symlinks, target for everything but symlinks, and
// nlink/size/sha256 for everything but regular files.
type Item struct {
	Path   string  `json:"path"`
	Type   string  `json:"type"`
	Mode   *string `json:"mode"`
	Target *string `json:"target"`
	Nlink  *uint64 `json:"nlink"`
	Size   *int64  `json:"size"`
	SHA256 *string `json:"sha256"`
}

// Listing lists every entry under root (root excluded) in byte order of its relative path,
// without following symlinks. Symlink targets are abstracted with places.
func Listing(root string, places Places) ([]Item, error) {
	items := []Item{}
	err := filepath.WalkDir(root, func(path string, _ fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path == root {
			return nil
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		item := Item{Path: filepath.ToSlash(rel)}
		mode := fmt.Sprintf("%04o", info.Mode().Perm())
		switch info.Mode().Type() {
		case fs.ModeDir:
			item.Type, item.Mode = "dir", &mode
		case 0:
			content, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			sum := sha256.Sum256(content)
			digest := hex.EncodeToString(sum[:])
			size := info.Size()
			links := uint64(info.Sys().(*syscall.Stat_t).Nlink)
			item.Type, item.Mode, item.Nlink, item.Size, item.SHA256 = "file", &mode, &links, &size, &digest
		case fs.ModeSymlink:
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			target = places.Abstract(target)
			item.Type, item.Target = "symlink", &target
		case fs.ModeSocket:
			item.Type, item.Mode = "socket", &mode
		default:
			item.Type, item.Mode = "other", &mode
		}
		items = append(items, item)
		return nil
	})
	sort.Slice(items, func(i, j int) bool { return items[i].Path < items[j].Path })
	return items, err
}

// Result is the self-test's verdict for one fs spec: {"error": text} when Build refuses it,
// else {"listing": items}.
func Result(root string, places Places, spec []any) (map[string]any, error) {
	if err := Build(root, places, spec); err != nil {
		var refusal *SpecError
		if errors.As(err, &refusal) {
			return map[string]any{"error": refusal.Error()}, nil
		}
		return nil, err
	}
	items, err := Listing(root, places)
	if err != nil {
		return nil, err
	}
	return map[string]any{"listing": items}, nil
}
