// Package snapshot materializes a Code snapshot into a new folder and keeps its immutable
// baseline in Runtime-owned storage. It never runs Git.
package snapshot

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
	"unsafe"
)

var (
	snapshotID = regexp.MustCompile(`^sha256:([0-9a-f]{64})$`)
	revisionID = regexp.MustCompile(`^rev_[0-9a-f]{64}$`)
	digest     = regexp.MustCompile(`^[0-9a-f]{64}$`)
	loopback   = regexp.MustCompile(`^http://127\.0\.0\.1:[1-9][0-9]{0,4}$`)
)

// Code gives up on an archive after 60 s without data; Runtime waits as long for each read.
const idleTimeout = 60 * time.Second

// repository is one repository of a snapshot at an opaque Code revision handle.
type repository struct {
	Path       string `json:"path"`
	Repository string `json:"repository"`
	Revision   string `json:"revision"`
}

type entry struct {
	Kind       string  `json:"kind"`
	Mode       string  `json:"mode"`
	Path       string  `json:"path"`
	Repository string  `json:"repository"`
	SHA256     string  `json:"sha256"`
	Size       int64   `json:"size"`
	Target     *string `json:"target,omitempty"`
}

// manifest is Code's version 2 snapshot manifest; older manifests are read only by Rebind.
type manifest struct {
	Entries      []entry      `json:"entries"`
	Repositories []repository `json:"repositories"`
	SnapshotID   string       `json:"snapshot_id"`
	Version      int          `json:"version"`
}

// Materialize downloads snapshot id from Code into the new folder dest, keeps its baseline
// under <home>/snapshots/<hex>/ and records the pair under <home>/materializations/.
func Materialize(home, id, dest string) (map[string]any, error) {
	match := snapshotID.FindStringSubmatch(id)
	if match == nil {
		return nil, errors.New("snapshot must be sha256:<64 lowercase hex characters>")
	}
	dest, err := destination(dest)
	if err != nil {
		return nil, err
	}
	code, err := connect(home)
	if err != nil {
		return nil, err
	}
	m, err := code.manifest(id)
	if err != nil {
		return nil, err
	}
	canonical := m.canonical()
	entries, err := m.check(id, canonical)
	if err != nil {
		return nil, err
	}
	baseline := filepath.Join(home, "snapshots", match[1])
	reuse, err := complete(baseline)
	if err == nil && reuse {
		err = seal(baseline)
	}
	if err != nil {
		return nil, err
	}

	// Private staging next to dest, so publishing is a rename on one filesystem.
	staging, err := os.MkdirTemp(filepath.Dir(dest), ".atlas-snapshot-*")
	if err != nil {
		return nil, err
	}
	defer remove(staging)
	work, err := newTree(filepath.Join(staging, "tree"), false)
	if err != nil {
		return nil, err
	}
	trees := []*tree{work}
	building := ""
	if !reuse {
		if err = os.MkdirAll(filepath.Dir(baseline), 0700); err != nil {
			return nil, err
		}
		if building, err = os.MkdirTemp(filepath.Dir(baseline), ".staging-*"); err != nil {
			return nil, err
		}
		defer func() {
			if building != "" {
				remove(building)
			}
		}()
		base, err := newTree(filepath.Join(building, "tree"), true)
		if err != nil {
			return nil, err
		}
		trees = append(trees, base)
	}

	seen := map[string]bool{}
	for _, r := range m.Repositories {
		for _, t := range trees {
			if err = t.mkdirs(r.Path); err != nil {
				return nil, err
			}
		}
		if err = code.archive(id, r.Path, entries, seen, trees); err != nil {
			return nil, err
		}
	}
	for _, e := range m.Entries {
		if !seen[e.Path] {
			return nil, fmt.Errorf("snapshot %s archives are missing %q", id, e.Path)
		}
	}
	for _, t := range trees {
		if err = t.finish(); err != nil {
			return nil, err
		}
	}

	if !reuse {
		if err = readOnly(filepath.Join(building, "manifest.json"), canonical); err != nil {
			return nil, err
		}
		// The marker distinguishes a published baseline from any other folder at its path.
		if err = readOnly(filepath.Join(building, "complete"), []byte(id+"\n")); err != nil {
			return nil, err
		}
		err = renameExclusive(building, baseline)
		if err == nil {
			building = ""
		} else if !errors.Is(err, fs.ErrExist) {
			return nil, err
		} else if ok, cerr := complete(baseline); !ok {
			// Otherwise a concurrent materialization published the same baseline first.
			return nil, errors.Join(err, cerr)
		}
		if err = seal(baseline); err != nil {
			return nil, err
		}
	}

	if err = renameExclusive(work.root, dest); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return nil, fmt.Errorf("destination %s already exists", dest)
		}
		return nil, fmt.Errorf("cannot publish %s: %v", dest, err)
	}
	// The folder is the user's now: a failed record is reported, never cleaned up.
	if err = record(home, dest, id); err != nil {
		return nil, fmt.Errorf("published %s but could not record its snapshot: %v", dest, err)
	}
	return map[string]any{"snapshot_id": id, "destination": dest, "baseline": baseline, "repositories": m.Repositories}, nil
}

// destination is dest's absolute path below its resolved parent; anything already there is refused.
func destination(dest string) (string, error) {
	dest, err := filepath.Abs(dest)
	if err != nil {
		return "", err
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(dest))
	if err == nil {
		var info os.FileInfo
		if info, err = os.Stat(parent); err == nil && !info.IsDir() {
			err = errors.New("not a directory")
		}
	}
	if err != nil {
		return "", fmt.Errorf("destination parent must be an existing directory: %v", err)
	}
	dest = filepath.Join(parent, filepath.Base(dest))
	if _, err = os.Lstat(dest); err == nil {
		return "", fmt.Errorf("destination %s already exists", dest)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}
	return dest, nil
}

type code struct {
	url, token string
	client     *http.Client
}

var errUnavailable = errors.New("Code service unavailable")

func unavailable(format string, args ...any) error {
	return fmt.Errorf("%w: "+format, append([]any{errUnavailable}, args...)...)
}

// connect reads <home>/code.json, the configuration Runtime's Elixir Code client uses.
func connect(home string) (*code, error) {
	path := filepath.Join(home, "code.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, unavailable("not configured; write %s", path)
	} else if err != nil {
		return nil, unavailable("cannot read %s: %v", path, reason(err))
	}
	var config struct {
		URL       string `json:"url"`
		TokenFile string `json:"token_file"`
	}
	// The bearer token only ever goes to loopback.
	if json.Unmarshal(data, &config) != nil || !loopback.MatchString(config.URL) || !filepath.IsAbs(config.TokenFile) {
		return nil, unavailable(`%s must be {"url": "http://127.0.0.1:PORT", "token_file": "/absolute/path"}`, path)
	}
	token, err := os.ReadFile(config.TokenFile)
	if err != nil {
		return nil, unavailable("cannot read token file %s: %v", config.TokenFile, reason(err))
	}
	if strings.TrimSpace(string(token)) == "" {
		return nil, unavailable("empty token file %s", config.TokenFile)
	}
	dialer := &net.Dialer{Timeout: 2 * time.Second}
	transport := &http.Transport{
		// No proxy: the token must reach only the loopback address checked above.
		Proxy:             nil,
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			conn, err := dialer.DialContext(ctx, network, address)
			if err != nil {
				return nil, err
			}
			return idle{conn}, nil
		},
	}
	return &code{url: config.URL, token: strings.TrimSpace(string(token)), client: &http.Client{
		Transport:     transport,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}, nil
}

func reason(err error) error {
	var path *fs.PathError
	if errors.As(err, &path) {
		return path.Err
	}
	return err
}

// idle bounds each read, so a stalled Code fails without capping how long a large archive takes.
type idle struct{ net.Conn }

func (c idle) Read(b []byte) (int, error) {
	if err := c.Conn.SetReadDeadline(time.Now().Add(idleTimeout)); err != nil {
		return 0, err
	}
	return c.Conn.Read(b)
}

// send returns the body of a 200 response; error text never contains the token.
func (c *code) send(method, path string, body io.Reader, size int64, what string) (io.ReadCloser, error) {
	request, err := http.NewRequest(method, c.url+path, body)
	if err != nil {
		return nil, unavailable("%v", err)
	}
	request.ContentLength = size
	request.Header.Set("Authorization", "Bearer "+c.token)
	response, err := c.client.Do(request)
	if err != nil {
		return nil, unavailable("%v", err)
	}
	if response.StatusCode == http.StatusOK {
		return response.Body, nil
	}
	defer response.Body.Close()
	var reply struct {
		Error struct {
			Code    *string `json:"code"`
			Message *string `json:"message"`
		} `json:"error"`
	}
	if json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&reply) == nil && reply.Error.Code != nil && reply.Error.Message != nil {
		return nil, fmt.Errorf("Code refused %s: %d %s: %s", what, response.StatusCode, *reply.Error.Code, *reply.Error.Message)
	}
	return nil, unavailable("HTTP %d", response.StatusCode)
}

func (c *code) manifest(id string) (*manifest, error) {
	body, err := c.send(http.MethodGet, "/v1/snapshots/"+id+"/manifest", nil, 0, "snapshot "+id)
	if err != nil {
		return nil, err
	}
	defer body.Close()
	decoder := json.NewDecoder(body)
	decoder.DisallowUnknownFields()
	var m manifest
	if err = decoder.Decode(&m); err != nil {
		return nil, unavailable("invalid manifest reply: %v", err)
	}
	return &m, nil
}

// canonical is the JSON whose SHA-256 Code uses as snapshot ID: Elixir's JSON.encode! of
// {"entries", "repositories", "version": 2}, i.e. sorted keys, no whitespace, raw UTF-8 and
// '/', and only '"', '\' and control characters escaped (\b \t \n \f \r, otherwise
// upper-case \u00XX).
func (m *manifest) canonical() []byte {
	var b bytes.Buffer
	writeEntries(&b, m.Entries)
	b.WriteString(`,"repositories":[`)
	for i, r := range m.Repositories {
		if i > 0 {
			b.WriteByte(',')
		}
		field(&b, `{"path":`, r.Path)
		field(&b, `,"repository":`, r.Repository)
		field(&b, `,"revision":`, r.Revision)
		b.WriteByte('}')
	}
	b.WriteString(`],"version":2}`)
	return b.Bytes()
}

// writeEntries writes `{"entries":[…]`, the part both manifest versions share byte for byte.
func writeEntries(b *bytes.Buffer, entries []entry) {
	b.WriteString(`{"entries":[`)
	for i, e := range entries {
		if i > 0 {
			b.WriteByte(',')
		}
		field(b, `{"kind":`, e.Kind)
		field(b, `,"mode":`, e.Mode)
		field(b, `,"path":`, e.Path)
		field(b, `,"repository":`, e.Repository)
		field(b, `,"sha256":`, e.SHA256)
		b.WriteString(`,"size":` + strconv.FormatInt(e.Size, 10))
		if e.Target != nil {
			field(b, `,"target":`, *e.Target)
		}
		b.WriteByte('}')
	}
	b.WriteByte(']')
}

func field(b *bytes.Buffer, key, value string) {
	b.WriteString(key)
	b.WriteByte('"')
	for i := range len(value) {
		c := value[i]
		short := strings.IndexByte("\b\t\n\f\r", c)
		switch {
		case c == '"' || c == '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c >= 0x20:
			b.WriteByte(c)
		case short >= 0:
			b.WriteByte('\\')
			b.WriteByte("btnfr"[short])
		default:
			fmt.Fprintf(b, `\u%04X`, c)
		}
	}
	b.WriteByte('"')
}

// check verifies the manifest's identity and safety and indexes its entries by path.
func (m *manifest) check(id string, canonical []byte) (map[string]*entry, error) {
	if m.Version != 2 {
		return nil, fmt.Errorf("snapshot %s is manifest version %d, not 2", id, m.Version)
	}
	if sum := sha256.Sum256(canonical); m.SnapshotID != id || "sha256:"+hex.EncodeToString(sum[:]) != id {
		return nil, fmt.Errorf("snapshot identity mismatch: Code's manifest for %s has ID %q and hashes to sha256:%x", id, m.SnapshotID, sum)
	}
	if len(m.Repositories) == 0 {
		return nil, errors.New("snapshot has no repositories")
	}
	for i, r := range m.Repositories {
		if !safe(r.Path) {
			return nil, fmt.Errorf("unsafe repository path %q", r.Path)
		}
		if !revisionID.MatchString(r.Revision) {
			return nil, fmt.Errorf("repository %q has no valid revision", r.Path)
		}
		for _, other := range m.Repositories[:i] {
			if within(r.Path, other.Path) || within(other.Path, r.Path) {
				return nil, fmt.Errorf("overlapping repository paths %q and %q", other.Path, r.Path)
			}
		}
	}

	entries := make(map[string]*entry, len(m.Entries))
	roots := make(map[string]string, len(m.Entries))
	links := map[string]string{}
	folded := map[string]string{}
	for i := range m.Entries {
		e := &m.Entries[i]
		for _, r := range m.Repositories {
			if within(r.Path, e.Path) && e.Path != r.Path {
				roots[e.Path] = r.Path
				if e.Repository != r.Repository {
					return nil, fmt.Errorf("unsafe manifest entry %q: repository does not match its path", e.Path)
				}
			}
		}
		if why := e.problem(roots[e.Path]); why != "" || entries[e.Path] != nil {
			if why == "" {
				why = "duplicate path"
			}
			return nil, fmt.Errorf("unsafe manifest entry %q: %s", e.Path, why)
		}
		entries[e.Path] = e
		if e.Target != nil {
			links[e.Path] = *e.Target
			if _, ok := folded[strings.ToLower(e.Path)]; ok {
				folded[strings.ToLower(e.Path)] = "\x00" // ambiguous on case-insensitive filesystems
			} else {
				folded[strings.ToLower(e.Path)] = *e.Target
			}
		}
	}
	for _, e := range m.Entries {
		path, root := e.Path, roots[e.Path]
		for dir := parent(path); len(dir) > len(root); dir = parent(dir) {
			if entries[dir] != nil {
				return nil, fmt.Errorf("unsafe manifest entry %q: inside file or symlink %q", path, dir)
			}
		}
		if e.Target != nil && !resolvesInside(links, folded, root, path, *e.Target) {
			return nil, fmt.Errorf("unsafe manifest entry %q: symlink target %q leaves its repository or loops", path, *e.Target)
		}
	}
	return entries, nil
}

// problem describes why an entry under repository root is unsafe or inconsistent, if it is.
func (e *entry) problem(root string) string {
	switch {
	case !safe(e.Path):
		return "path must be relative and normalized, without .git, backslashes or control characters"
	case root == "":
		return "path is outside every repository"
	case !digest.MatchString(e.SHA256) || e.Size < 0:
		return "size or sha256 is invalid"
	case e.Kind == "file" && (e.Mode == "100644" || e.Mode == "100755") && e.Target == nil:
		return ""
	case e.Kind != "symlink" || e.Mode != "120000" || e.Target == nil:
		return "kind, mode and target are inconsistent"
	}
	target := *e.Target
	sum := sha256.Sum256([]byte(target))
	switch {
	case target == "" || strings.HasPrefix(target, "/") || strings.ContainsRune(target, 0):
		return "symlink target must be relative and nonempty"
	case e.Size != int64(len(target)) || e.SHA256 != hex.EncodeToString(sum[:]):
		return "symlink size or sha256 does not match its target"
	}
	return ""
}

// safe is Code's path rule: UTF-8, relative, normalized, no backslash, control
// character or .git segment in any case.
func safe(path string) bool {
	if !utf8.ValidString(path) || strings.ContainsAny(path, "\\\x7f") {
		return false
	}
	for i := range len(path) {
		if path[i] < 0x20 {
			return false
		}
	}
	for _, segment := range strings.Split(path, "/") {
		if segment == "" || segment == "." || segment == ".." || strings.EqualFold(segment, ".git") {
			return false
		}
	}
	return true
}

func within(dir, path string) bool { return path == dir || strings.HasPrefix(path, dir+"/") }

func parent(path string) string {
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		return path[:i]
	}
	return ""
}

// resolvesInside reports whether the symlink at path stays inside root when the snapshot's
// other symlinks are followed like the filesystem would. Code checks each target only
// lexically, which a chain such as `t -> s/..` with `s -> d/e` and `d/e -> ..` escapes.
// Names are also matched case-insensitively; an ambiguous match or a loop is refused.
func resolvesInside(links, folded map[string]string, root, path, target string) bool {
	stack := strings.Split(strings.TrimPrefix(parent(path), root), "/")[1:]
	queue := strings.Split(target, "/")
	for hops := 0; len(queue) > 0; {
		segment := queue[0]
		queue = queue[1:]
		switch segment {
		case "", ".":
		case "..":
			if len(stack) == 0 {
				return false
			}
			stack = stack[:len(stack)-1]
		default:
			stack = append(stack, segment)
			name := root + "/" + strings.Join(stack, "/")
			next, ok := links[name]
			if !ok {
				next, ok = folded[strings.ToLower(name)]
			}
			if !ok {
				continue
			}
			if hops++; hops > 40 || next == "\x00" {
				return false
			}
			stack = stack[:len(stack)-1]
			queue = append(strings.Split(next, "/"), queue...)
		}
	}
	return true
}

// complete reports whether the baseline exists with its completion marker; an unmarked
// folder at that path is refused rather than reused or replaced.
func complete(baseline string) (bool, error) {
	if _, err := os.Lstat(filepath.Join(baseline, "complete")); err == nil {
		return true, nil
	}
	if _, err := os.Lstat(baseline); errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	return false, fmt.Errorf("baseline %s exists without its completion marker", baseline)
}

func (c *code) archive(id, root string, entries map[string]*entry, seen map[string]bool, trees []*tree) error {
	what := "snapshot " + id + " archive " + root
	body, err := c.send(http.MethodGet, "/v1/snapshots/"+id+"/archive?path="+url.QueryEscape(root), nil, 0, what)
	if err != nil {
		return err
	}
	defer body.Close()
	archive := tar.NewReader(body)
	for {
		header, err := archive.Next()
		if err == io.EOF {
			return nil
		} else if err != nil {
			return fmt.Errorf("%s: %v", what, err)
		}
		// Manifest paths are normalized, so traversal or absolute names never match one.
		path := root + "/" + header.Name
		e := entries[path]
		if e == nil || seen[path] {
			return fmt.Errorf("%s: unexpected or duplicate member %q", what, header.Name)
		}
		seen[path] = true
		if err = extract(archive, header, e, trees); err != nil {
			return fmt.Errorf("%s: member %q: %v", what, header.Name, err)
		}
	}
}

func extract(archive io.Reader, header *tar.Header, e *entry, trees []*tree) error {
	switch {
	case header.Typeflag == tar.TypeSymlink && e.Kind == "symlink":
		if header.Linkname != *e.Target {
			return errors.New("symlink target differs from the manifest")
		}
		for _, t := range trees {
			if err := t.symlink(e.Path, *e.Target); err != nil {
				return err
			}
		}
		return nil
	case header.Typeflag == tar.TypeReg && e.Kind == "file":
		mode := os.FileMode(0644)
		if e.Mode == "100755" {
			mode = 0755
		}
		if header.Mode != int64(mode) || header.Size != e.Size {
			return fmt.Errorf("mode %o or size %d differs from the manifest", header.Mode, header.Size)
		}
		return write(archive, e, mode, trees)
	}
	return fmt.Errorf("type %q differs from the manifest kind %s", header.Typeflag, e.Kind)
}

// write streams one file into every tree while hashing it.
func write(archive io.Reader, e *entry, mode os.FileMode, trees []*tree) (err error) {
	hash := sha256.New()
	writers := []io.Writer{hash}
	files := []*os.File{}
	defer func() {
		for _, file := range files {
			if cerr := file.Close(); err == nil {
				err = cerr
			}
		}
	}()
	for _, t := range trees {
		file, err := t.create(e.Path)
		if err != nil {
			return err
		}
		files = append(files, file)
		writers = append(writers, file)
	}
	if _, err = io.Copy(io.MultiWriter(writers...), archive); err != nil {
		return err
	}
	if hex.EncodeToString(hash.Sum(nil)) != e.SHA256 {
		return errors.New("sha256 differs from the manifest")
	}
	for i, file := range files {
		if err = file.Chmod(trees[i].perm(mode)); err != nil {
			return err
		}
	}
	return nil
}

// tree is a folder built from scratch: every directory in it is created here, so nothing is
// written through an existing symlink or a name the filesystem folds onto another one.
type tree struct {
	root     string
	readOnly bool
	dirs     map[string]bool
}

func newTree(root string, readOnly bool) (*tree, error) {
	if err := os.Mkdir(root, 0700); err != nil {
		return nil, err
	}
	return &tree{root: root, readOnly: readOnly, dirs: map[string]bool{"": true}}, nil
}

func (t *tree) perm(mode os.FileMode) os.FileMode {
	if t.readOnly {
		return mode &^ 0222
	}
	return mode
}

// mkdirs creates dir and its missing ancestors; an existing name this tree did not create is refused.
func (t *tree) mkdirs(dir string) error {
	for i := range len(dir) + 1 {
		if i < len(dir) && dir[i] != '/' || t.dirs[dir[:i]] {
			continue
		}
		if err := os.Mkdir(filepath.Join(t.root, dir[:i]), 0700); err != nil {
			return fmt.Errorf("cannot create directory %q: %v", dir[:i], err)
		}
		t.dirs[dir[:i]] = true
	}
	return nil
}

func (t *tree) create(path string) (*os.File, error) {
	if err := t.mkdirs(parent(path)); err != nil {
		return nil, err
	}
	return os.OpenFile(filepath.Join(t.root, path), os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0600)
}

func (t *tree) symlink(path, target string) error {
	if err := t.mkdirs(parent(path)); err != nil {
		return err
	}
	return os.Symlink(target, filepath.Join(t.root, path))
}

// finish gives every directory its final mode: 0755, or 0555 in a read-only tree.
func (t *tree) finish() error {
	for dir := range t.dirs {
		if err := os.Chmod(filepath.Join(t.root, dir), t.perm(0755)); err != nil {
			return err
		}
	}
	return nil
}

func readOnly(path string, data []byte) error {
	if err := os.WriteFile(path, data, 0600); err != nil {
		return err
	}
	return os.Chmod(path, 0444)
}

// seal makes a published baseline folder read-only. It runs only after the rename, because
// macOS 15 refuses to rename a directory without write permission, and again on every reuse,
// so a crash between the two never leaves a complete baseline writable for long.
func seal(baseline string) error {
	return os.Chmod(baseline, 0555)
}

// remove deletes a staging folder, first making its read-only directories writable again.
func remove(path string) {
	filepath.WalkDir(path, func(name string, d fs.DirEntry, err error) error {
		if err == nil && d.IsDir() {
			os.Chmod(name, 0700)
		}
		return nil
	})
	os.RemoveAll(path)
}

// record maps the published folder to its snapshot for the later offline diff.
func record(home, dest, id string) error {
	return writeRecord(home, dest, map[string]string{"destination": dest, "snapshot_id": id, "materialized_at": time.Now().UTC().Format(time.RFC3339)})
}

// writeRecord replaces the materialization record of dest with fields.
func writeRecord(home, dest string, fields map[string]string) error {
	dir := filepath.Join(home, "materializations")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	body, err := json.Marshal(fields)
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(dir, ".record-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, err = file.Write(body)
	if cerr := file.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	return os.Rename(file.Name(), recordPath(home, dest))
}

// renameExclusive renames atomically and fails with EEXIST instead of replacing anything at
// to. Platforms without such a rename are refused rather than racing an existence check.
func renameExclusive(from, to string) error {
	var trap, flag uintptr
	cwd := -100 // AT_FDCWD on Linux
	switch runtime.GOOS + "/" + runtime.GOARCH {
	case "darwin/amd64", "darwin/arm64":
		trap, flag, cwd = 488, 4, -2 // renameatx_np(RENAME_EXCL), the call behind renamex_np
	case "linux/amd64":
		trap, flag = 316, 1 // renameat2(RENAME_NOREPLACE)
	case "linux/arm64":
		trap, flag = 276, 1
	default:
		return errors.New("an atomic no-replace rename is not supported on this platform")
	}
	source, err := syscall.BytePtrFromString(from)
	if err != nil {
		return err
	}
	target, err := syscall.BytePtrFromString(to)
	if err != nil {
		return err
	}
	if _, _, errno := syscall.Syscall6(trap, uintptr(cwd), uintptr(unsafe.Pointer(source)), uintptr(cwd), uintptr(unsafe.Pointer(target)), flag, 0); errno != 0 {
		return &os.LinkError{Op: "rename", Old: from, New: to, Err: errno}
	}
	return nil
}
