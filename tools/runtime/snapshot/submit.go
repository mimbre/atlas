package snapshot

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"syscall"
)

// maxChange is Code's limit for a POST /v1/changes body.
const maxChange = 1 << 20

var (
	changeID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	// maxBlob is Code's blob limit; a variable so tests need not write 64 MiB.
	maxBlob int64 = 64 << 20
	// afterCapture runs between capturing the blobs and the second scan; tests change the folder there.
	afterCapture = func() {}
)

// changeEntry is one entry of a Code change request; paths are relative to the repository.
type changeEntry struct {
	Path   string  `json:"path"`
	Op     string  `json:"op"`
	Kind   string  `json:"kind"`
	Mode   string  `json:"mode"`
	Size   int64   `json:"size"`
	SHA256 string  `json:"sha256"`
	Target *string `json:"target,omitempty"`
}

func (e changeEntry) MarshalJSON() ([]byte, error) {
	if e.Op == "delete" {
		return json.Marshal(map[string]string{"path": e.Path, "op": e.Op})
	}
	type plain changeEntry
	return json.Marshal(plain(e))
}

// Submit sends the changes of one repository in the folder dest, published by Materialize,
// to Code as change id and seals them into a private revision. path selects the repository and
// may be empty when there is only one. It writes to neither the folder nor its baseline;
// a clean repository makes no request. A folder with an active Runtime owner is refused.
func Submit(home, dest, path, id string) (map[string]any, error) {
	if !changeID.MatchString(id) {
		return nil, errors.New("change ID must be a lowercase UUID")
	}
	f, err := openFolder(home, dest)
	if err != nil {
		return nil, err
	}
	lock, err := own(f.dest)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	if path == "" {
		if len(f.m.Repositories) != 1 {
			known := []string{}
			for _, r := range f.m.Repositories {
				known = append(known, r.Path)
			}
			return nil, fmt.Errorf("--path is required: %s has repositories %q", f.dest, known)
		}
		path = f.m.Repositories[0].Path
	}
	changes, err := f.changes([]string{path}, false)
	if err != nil {
		return nil, err
	}
	var r repository
	for _, r = range f.m.Repositories {
		if r.Path == path {
			break
		}
	}
	if err = f.ancestors(r); err != nil {
		return nil, err
	}
	result := map[string]any{"snapshot_id": f.id, "repository": r.Repository, "path": r.Path, "base_revision": r.Revision, "change_id": id, "state": "clean", "revision": nil}
	if len(changes) == 0 {
		return result, nil
	}
	code, err := connect(home)
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(filepath.Join(home, "submissions"), 0700); err != nil {
		return nil, err
	}
	blobs, err := os.MkdirTemp(filepath.Join(home, "submissions"), "tmp-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(blobs)
	entries, err := f.convert(r, changes, blobs)
	if err != nil {
		return nil, err
	}
	afterCapture()
	// Metadata and uploads come from the captured copies. A second scan that hashes the folder
	// again must agree with them, so a request never mixes versions from before and after an edit.
	if changes, err = f.changes([]string{path}, false); err != nil {
		return nil, err
	}
	if err = f.ancestors(r); err != nil {
		return nil, err
	}
	again, err := f.convert(r, changes, "")
	if err != nil {
		return nil, err
	}
	if !reflect.DeepEqual(again, entries) {
		return nil, fmt.Errorf("folder %s changed during submission; nothing was sent to Code, run the command again", f.dest)
	}
	body, err := json.Marshal(map[string]any{"change_id": id, "snapshot_id": f.id, "repository": r.Repository, "base_revision": r.Revision, "entries": entries})
	if err != nil {
		return nil, err
	}
	if len(body) > maxChange {
		return nil, fmt.Errorf("the change request for %s is %d bytes, over Code's 1 MiB limit; nothing was sent to Code", r.Path, len(body))
	}
	revision, err := code.submit(id, body, blobs)
	if err != nil {
		return nil, err
	}
	result["state"], result["revision"] = "sealed", revision
	return result, nil
}

// own takes the exclusive flock a Runtime host holds on its folder until its process group is
// reaped, so the folder is not captured while a worker may write to it. It never waits; closing
// the returned directory releases the lock.
func own(dest string) (*os.File, error) {
	lock, err := os.OpenFile(dest, os.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("cannot submit %s: %v", dest, reason(err))
	}
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, fmt.Errorf("folder %s has an active Runtime owner; nothing was sent to Code, run the command again after it stops", dest)
		}
		return nil, err
	}
	return lock, nil
}

// ancestors refuses an existing folder above repository r that is no longer a real directory:
// the walk would not enter it, so every base file of r would become a deletion. A missing
// folder is a deletion of the repository's content. Nothing is followed.
func (f *folder) ancestors(r repository) error {
	for i := range len(r.Path) {
		if r.Path[i] != '/' {
			continue
		}
		dir := r.Path[:i]
		info, err := os.Lstat(filepath.Join(f.dest, filepath.FromSlash(dir)))
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		} else if err != nil {
			return fmt.Errorf("cannot submit %s: %v", r.Path, reason(err))
		} else if !info.IsDir() {
			return fmt.Errorf("cannot submit %s: its folder %s is no longer a directory", r.Path, dir)
		}
	}
	return nil
}

// convert turns repository r's changes into Code change entries in path order. With blobs set,
// every written file is copied there under its sha256; otherwise it is only hashed. Content
// Code cannot represent is refused, never left out.
func (f *folder) convert(r repository, changes []change, blobs string) ([]changeEntry, error) {
	result := []changeEntry{}
	for _, c := range changes {
		refuse := func(format string, args ...any) error {
			return fmt.Errorf("cannot submit %s: "+format, append([]any{c.Path}, args...)...)
		}
		if c.Path == r.Path {
			return nil, refuse("the repository folder itself is no longer a directory")
		}
		kind := "file"
		switch {
		case c.Change == "deleted":
			kind = ""
		case c.Change == "kind":
			kind = c.NewKind
		case c.NewKind == "other":
			kind = "other"
		case c.Change == "symlink" || c.Change == "added" && c.NewTarget != "":
			kind = "symlink"
		}
		rel := strings.TrimPrefix(c.Path, r.Path+"/")
		e := entry{Kind: kind, Path: c.Path, Repository: r.Repository}
		switch kind {
		case "", "directory":
			// Deleted, or a base file or symlink replaced by a directory whose files are listed
			// on their own. Base files under a path replaced by a file are listed as deleted.
			// Empty directories cannot be represented and are not changes.
			result = append(result, changeEntry{Path: rel, Op: "delete"})
			continue
		case "symlink":
			sum := sha256.Sum256([]byte(c.NewTarget))
			e.Mode, e.Size, e.SHA256, e.Target = "120000", int64(len(c.NewTarget)), hex.EncodeToString(sum[:]), &c.NewTarget
		case "file":
			var err error
			if e.SHA256, e.Size, e.Mode, err = blob(filepath.Join(f.dest, c.Path), blobs); err != nil {
				return nil, refuse("%v", err)
			}
		default:
			return nil, refuse("only files, symlinks and directories can be submitted, not a FIFO, socket or device")
		}
		// Code's own rules: path, mode and digest, then a target that stays inside the repository.
		if why := e.problem(r.Path); why != "" {
			return nil, refuse("%s", why)
		}
		if e.Target != nil && !resolvesInside(nil, nil, r.Path, e.Path, *e.Target) {
			return nil, refuse("symlink target %q leaves the repository", *e.Target)
		}
		result = append(result, changeEntry{Path: rel, Op: "write", Kind: e.Kind, Mode: e.Mode, Size: e.Size, SHA256: e.SHA256, Target: e.Target})
	}
	return result, nil
}

// blob hashes the regular file name, never following a symlink, and returns its sha256, size and
// Git mode. With dir set it also copies the file to dir/<sha256>. Files over maxBlob are refused.
func blob(name, dir string) (sum string, size int64, mode string, err error) {
	// O_NONBLOCK: a FIFO swapped in after the scan must not hang the submission.
	file, err := os.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return "", 0, "", reason(err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", 0, "", err
	}
	if !info.Mode().IsRegular() {
		return "", 0, "", errors.New("is no longer a regular file")
	}
	hash := sha256.New()
	out := io.Writer(hash)
	var kept *os.File
	if dir != "" {
		if kept, err = os.CreateTemp(dir, ".blob-*"); err != nil {
			return "", 0, "", err
		}
		defer kept.Close()
		out = io.MultiWriter(hash, kept)
	}
	if size, err = io.Copy(out, io.LimitReader(file, maxBlob+1)); err != nil {
		return "", 0, "", err
	}
	if size > maxBlob {
		return "", 0, "", fmt.Errorf("is larger than Code's blob limit of %d bytes", maxBlob)
	}
	sum, mode = hex.EncodeToString(hash.Sum(nil)), "100644"
	if info.Mode()&0111 != 0 {
		mode = "100755"
	}
	if kept != nil {
		if err = kept.Close(); err == nil {
			err = os.Rename(kept.Name(), filepath.Join(dir, sum))
		}
	}
	return sum, size, mode, err
}

type changeState struct {
	ChangeID string   `json:"change_id"`
	State    string   `json:"state"`
	Missing  []string `json:"missing"`
	Revision string   `json:"revision"`
}

// submit creates change id from body, uploads the blobs Code reports missing from dir and seals
// it, returning its revision. A repeat of a sealed change returns it without uploading.
func (c *code) submit(id string, body []byte, dir string) (string, error) {
	s, err := c.change(http.MethodPost, "/v1/changes", bytes.NewReader(body), int64(len(body)), id)
	if errors.Is(err, errUnavailable) {
		return "", incomplete(id, err) // Code may have stored the change
	} else if err != nil {
		return "", err
	}
	for _, sum := range s.Missing {
		if err = c.upload(id, dir, sum); err != nil {
			return "", incomplete(id, err)
		}
	}
	if s.State == "open" {
		if s, err = c.change(http.MethodPost, "/v1/changes/"+id+"/seal", nil, 0, id); err == nil && s.State != "sealed" {
			err = unavailable("seal of change %s replied state %q", id, s.State)
		}
		if err != nil {
			return "", incomplete(id, err)
		}
	}
	return s.Revision, nil
}

func incomplete(id string, err error) error {
	return fmt.Errorf("%w; change %s is not confirmed sealed and nothing was published: repeat the same command with --change-id %s to resume", err, id, id)
}

// change sends one change request and validates Code's state reply.
func (c *code) change(method, path string, body io.Reader, size int64, id string) (*changeState, error) {
	reply, err := c.send(method, path, body, size, "change "+id)
	if err != nil {
		return nil, err
	}
	defer reply.Close()
	var s changeState
	if json.NewDecoder(io.LimitReader(reply, maxChange)).Decode(&s) != nil || s.ChangeID != id ||
		s.State != "open" && s.State != "sealed" || s.State == "sealed" && !revisionID.MatchString(s.Revision) {
		return nil, unavailable("invalid reply to %s %s", method, path)
	}
	return &s, nil
}

func (c *code) upload(id, dir, sum string) error {
	if !digest.MatchString(sum) {
		return unavailable("Code asked for blob %q, which change %s does not write", sum, id)
	}
	file, err := os.Open(filepath.Join(dir, sum))
	if err != nil {
		return unavailable("Code asked for blob %s, which change %s does not write", sum, id)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	reply, err := c.send(http.MethodPut, "/v1/changes/"+id+"/blobs/"+sum, file, info.Size(), "change "+id+" blob "+sum)
	if err != nil {
		return err
	}
	return reply.Close()
}
