package s6fixture

import (
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// The fs spec (test/fixtures/s6/README.md): a list of entries, built in order under the root.
// Every message below is shared byte for byte with test/support/s6_fixture.ex.
var (
	entryFields = []string{"path", "type", "mode", "content", "target", "head"}
	typeFields  = map[string][]string{
		"dir":      {"mode"},
		"file":     {"mode", "content"},
		"symlink":  {"target"},
		"hardlink": {"target"},
		"socket":   {"mode"},
		"git":      {"head"},
	}
	defaultModes = map[string]string{"dir": "0755", "file": "0644", "socket": "0755"}
	modePattern  = regexp.MustCompile(`^0[0-7]{3}$`)
	headPattern  = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`)
)

// SpecError is a refusal of the spec itself, with the text both builders share.
type SpecError struct{ text string }

func (e *SpecError) Error() string { return e.text }

// socketPathLimit is the longest socket path the BSD sockaddr_un holds (104 bytes with NUL).
const socketPathLimit = 103

const gitConfig = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n"

// Build creates the fs spec under root, which must exist and be canonical. It never follows a
// symlink it meets on the way, so a spec cannot write outside root. A spec error is returned
// with the shared text; an unexpected I/O error is returned as is.
func Build(root string, places Places, spec []any) error {
	taken := map[string]bool{}
	dirModes := map[string]string{}
	for i, raw := range spec {
		if err := buildEntry(root, places, i, raw, taken, dirModes); err != nil {
			return err
		}
	}
	dirs := make([]string, 0, len(dirModes))
	for rel := range dirModes {
		dirs = append(dirs, rel)
	}
	// Children before parents, so a restrictive parent mode is applied last.
	sort.Sort(sort.Reverse(sort.StringSlice(dirs)))
	for _, rel := range dirs {
		if err := chmod(filepath.Join(root, rel), dirModes[rel]); err != nil {
			return err
		}
	}
	return nil
}

func buildEntry(root string, places Places, i int, raw any, taken map[string]bool, dirModes map[string]string) error {
	fail := func(format string, args ...any) error {
		return &SpecError{fmt.Sprintf("fs[%d]: %s", i, fmt.Sprintf(format, args...))}
	}
	entry, ok := raw.(map[string]any)
	if !ok {
		return fail("entry is not an object")
	}
	keys := make([]string, 0, len(entry))
	for key := range entry {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		if !contains(entryFields, key) {
			return fail("unknown field: %s", key)
		}
	}
	fields := map[string]string{}
	for _, key := range entryFields {
		if value, present := entry[key]; present {
			text, isString := value.(string)
			if !isString {
				return fail("field %s is not a string", key)
			}
			fields[key] = text
		}
	}
	pathSpec, hasPath := fields["path"]
	if !hasPath {
		return fail("path is required")
	}
	kind, hasType := fields["type"]
	if !hasType {
		return fail("type is required")
	}
	allowed, known := typeFields[kind]
	if !known {
		return fail("unknown type: %s", kind)
	}
	rel, valid := relative(root, places.Substitute(pathSpec))
	if !valid {
		return fail("invalid path: %s", pathSpec)
	}
	key := rel
	if kind == "git" {
		key = rel + "/.git"
	}
	if taken[key] {
		return fail("duplicate path: %s", pathSpec)
	}
	taken[key] = true
	for _, field := range entryFields[2:] {
		if _, present := fields[field]; present && !contains(allowed, field) {
			return fail("field %s is not allowed for type %s", field, kind)
		}
	}
	mode, hasMode := fields["mode"]
	if !hasMode {
		mode = defaultModes[kind]
	}
	if contains(allowed, "mode") && !modePattern.MatchString(mode) {
		return fail("invalid mode: %s", mode)
	}
	target, hasTarget := fields["target"]
	if (kind == "symlink" || kind == "hardlink") && !hasTarget {
		return fail("type %s requires a target", kind)
	}
	head, hasHead := fields["head"]
	if !hasHead {
		head = "develop"
	}
	if kind == "git" && !headPattern.MatchString(head) {
		return fail("invalid head: %s", head)
	}

	if parent, ok, err := ensureParents(root, rel); err != nil {
		return err
	} else if !ok {
		return fail("parent is not a directory: %s", parent)
	}
	path := filepath.Join(root, rel)
	info, err := os.Lstat(path)
	exists := err == nil
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	isDir := exists && info.Mode().IsDir()
	if exists && !((kind == "dir" || kind == "git") && isDir) {
		return fail("path exists: %s", pathSpec)
	}

	switch kind {
	case "dir":
		if !exists {
			if err := mkdir(path); err != nil {
				return err
			}
		}
		dirModes[rel] = mode
	case "file":
		file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			return err
		}
		if _, err := file.WriteString(fields["content"]); err != nil {
			file.Close()
			return err
		}
		if err := file.Close(); err != nil {
			return err
		}
		return chmod(path, mode)
	case "symlink":
		return os.Symlink(places.Substitute(target), path)
	case "hardlink":
		targetRel, valid := relative(root, places.Substitute(target))
		if !valid {
			return fail("invalid target: %s", target)
		}
		targetInfo, err := lstatInside(root, targetRel)
		if err != nil {
			return err
		}
		if targetInfo == nil || !targetInfo.Mode().IsRegular() {
			return fail("hardlink target is not a file: %s", target)
		}
		return os.Link(filepath.Join(root, targetRel), path)
	case "socket":
		if len(path) > socketPathLimit {
			return fail("socket path is too long: %s", pathSpec)
		}
		listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
		if err != nil {
			return err
		}
		listener.SetUnlinkOnClose(false)
		if err := listener.Close(); err != nil {
			return err
		}
		return chmod(path, mode)
	case "git":
		if !exists {
			if err := mkdir(path); err != nil {
				return err
			}
		}
		git := filepath.Join(path, ".git")
		if _, err := os.Lstat(git); err == nil {
			return fail("path exists: %s", pathSpec+"/.git")
		} else if !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		for _, dir := range []string{"", "objects", "refs", "refs/heads", "refs/tags"} {
			if err := mkdir(filepath.Join(git, dir)); err != nil {
				return err
			}
		}
		for name, content := range map[string]string{"HEAD": "ref: refs/heads/" + head + "\n", "config": gitConfig} {
			if err := os.WriteFile(filepath.Join(git, name), []byte(content), 0o600); err != nil {
				return err
			}
			if err := chmod(filepath.Join(git, name), "0644"); err != nil {
				return err
			}
		}
	}
	return nil
}

// relative turns a substituted path into a clean path relative to root, or reports it invalid:
// empty, root itself, absolute outside root, or with an empty, "." or ".." component.
func relative(root, path string) (string, bool) {
	if strings.HasPrefix(path, "/") {
		if !strings.HasPrefix(path, root+"/") {
			return "", false
		}
		path = path[len(root)+1:]
	}
	if path == "" {
		return "", false
	}
	for _, part := range strings.Split(path, "/") {
		if part == "" || part == "." || part == ".." {
			return "", false
		}
	}
	return path, true
}

// ensureParents creates each missing parent of rel as a 0755 directory. It stops at the first
// existing parent that is not a real directory and returns it (ok false).
func ensureParents(root, rel string) (string, bool, error) {
	parts := strings.Split(rel, "/")
	for n := 1; n < len(parts); n++ {
		parent := strings.Join(parts[:n], "/")
		info, err := os.Lstat(filepath.Join(root, parent))
		switch {
		case errors.Is(err, fs.ErrNotExist):
			if err := mkdir(filepath.Join(root, parent)); err != nil {
				return "", false, err
			}
		case err != nil:
			return "", false, err
		case !info.Mode().IsDir():
			return parent, false, nil
		}
	}
	return "", true, nil
}

// lstatInside lstats rel without following a symlink on the way; nil means absent or not
// reachable through real directories.
func lstatInside(root, rel string) (os.FileInfo, error) {
	parts := strings.Split(rel, "/")
	for n := 1; n < len(parts); n++ {
		info, err := os.Lstat(filepath.Join(root, strings.Join(parts[:n], "/")))
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsDir() {
			return nil, nil
		}
	}
	info, err := os.Lstat(filepath.Join(root, rel))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	return info, err
}

func mkdir(path string) error {
	if err := os.Mkdir(path, 0o700); err != nil {
		return err
	}
	return chmod(path, "0755")
}

func chmod(path, mode string) error {
	bits, err := strconv.ParseUint(mode, 8, 32)
	if err != nil {
		return err
	}
	return os.Chmod(path, fs.FileMode(bits))
}

func contains(list []string, item string) bool {
	for _, value := range list {
		if value == item {
			return true
		}
	}
	return false
}
