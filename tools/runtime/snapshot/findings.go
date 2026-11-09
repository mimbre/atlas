package snapshot

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

// maxFindings bounds findings.json so a findings record fits in a rework assignment with room to
// spare: a command request is at most 128 KiB.
const maxFindings = 64 << 10

var (
	verdicts   = []string{"pass", "changes_required", "uncertain"}
	severities = []string{"blocking", "should-fix", "note"}
	sides      = []string{"new", "old"}
)

// FindingsRefusal is a refused findings ingest with its fixed code: packet_modified,
// findings_missing or findings_invalid. A refusal is never a verdict.
type FindingsRefusal struct {
	Code string
	err  error
}

func (r *FindingsRefusal) Error() string { return r.err.Error() }

// Result is what the CLI reports with the error.
func (r *FindingsRefusal) Result() map[string]any { return map[string]any{"code": r.Code} }

func refuse(code, format string, args ...any) error {
	return &FindingsRefusal{Code: code, err: fmt.Errorf(format, args...)}
}

// packetModified marks a packet whose tree or metadata no longer matches its record.
type packetModified struct{ error }

func (p packetModified) Unwrap() error { return p.error }

// findingsRecord is <home>/packets/<id>/findings/<turn>.json: the review pass's file verbatim, who
// reviewed with which selection, whose work it was, and the hash of the bytes the pass wrote.
type findingsRecord struct {
	Version     int             `json:"version"`
	PacketID    string          `json:"packet_id"`
	Fingerprint string          `json:"fingerprint"`
	ReviewTurn  string          `json:"review_turn"`
	Reviewer    map[string]any  `json:"reviewer"`
	Author      map[string]any  `json:"author"`
	RecordedAt  string          `json:"recorded_at"`
	SHA256      string          `json:"sha256"`
	Findings    json.RawMessage `json:"findings"`
}

// Findings validates P/findings/findings.json, written by the ended review turn that ran in the
// tree of the packet folder path, and records it under <home>/packets/<id>/findings/<turn>.json.
// It holds the tree's lock and checks the tree still has the packet's fingerprint. It never writes
// a verdict itself. A repeat for the same turn and unchanged file returns the recorded record.
func Findings(home, path, turn string) (map[string]any, error) {
	if !savedTurn.MatchString(turn) {
		return nil, errors.New("turn must be turn-<16 lowercase hex characters>")
	}
	home, err := filepath.EvalSymlinks(home)
	if err != nil {
		return nil, err
	}
	dir, err := materialized(path)
	if err != nil {
		return nil, fmt.Errorf("packet folder %s: %v", path, reason(err))
	}
	tree, err := materialized(filepath.Join(dir, "tree"))
	if err != nil || filepath.Dir(tree) != dir {
		return nil, fmt.Errorf("%s is not a review packet folder: it has no tree; pass the folder snapshot freeze made", dir)
	}
	if _, err = os.Stat(recordPath(home, tree)); errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("%s is not a review packet folder: its tree is not recorded under %s", dir, home)
	}
	id, err := RecordedPacket(home, tree)
	if err != nil {
		return nil, err
	}
	if id == "" {
		return nil, fmt.Errorf("%s is not a review packet folder: its tree is a materialized folder, not a frozen packet", dir)
	}
	recordFile := filepath.Join(PacketDir(home, id), "findings", turn+".json")
	if existing, err := repeatedFindings(recordFile, filepath.Join(dir, "findings", "findings.json"), turn); existing != nil || err != nil {
		return existing, err
	}
	reviewer, err := reviewTurn(home, turn, tree, id)
	if err != nil {
		return nil, err
	}

	lock, err := hold(tree, "record the findings of", "nothing was recorded")
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	verified, err := VerifiedPacket(home, tree)
	var modified packetModified
	if errors.As(err, &modified) {
		return nil, refuse("packet_modified", "%v", err)
	} else if err != nil {
		return nil, err
	}
	fingerprint := verified["fingerprint"].(string)
	if scope := reviewer["scope_fingerprint"]; scope != fingerprint {
		return nil, fmt.Errorf("turn %s reviewed fingerprint %v, not packet %s's %s; record the findings of a pass that reviewed this packet", turn, scope, id, fingerprint)
	}
	delete(reviewer, "scope_fingerprint")
	p, err := loadPacket(home, id)
	if err != nil {
		return nil, err
	}

	file := filepath.Join(verified["findings"].(string), "findings.json")
	data, err := readFindings(file)
	if err != nil {
		return nil, err
	}
	t, err := openFolder(home, tree)
	if err != nil {
		return nil, err
	}
	if err = t.validFindings(data, p); err != nil {
		return nil, refuse("findings_invalid", "%s is invalid: %v; nothing was recorded", file, err)
	}

	author := map[string]any{"turn_id": p.Author["turn_id"], "worker_id": p.Author["worker_id"], "backend": p.Author["backend"], "model": p.Author["model"],
		"selection": turnSelection(home, p.Author["turn_id"])}
	sum := sha256.Sum256(data)
	var compact bytes.Buffer
	if err = json.Compact(&compact, data); err != nil {
		return nil, err
	}
	body, err := json.Marshal(findingsRecord{Version: 1, PacketID: id, Fingerprint: fingerprint, ReviewTurn: turn, Reviewer: reviewer, Author: author,
		RecordedAt: time.Now().UTC().Format(time.RFC3339), SHA256: hex.EncodeToString(sum[:]), Findings: compact.Bytes()})
	if err != nil {
		return nil, err
	}
	if err = publish(recordFile, body); errors.Is(err, fs.ErrExist) {
		// A concurrent ingest of the same turn recorded first.
		return repeatedFindings(recordFile, file, turn)
	} else if err != nil {
		return nil, err
	}
	result, err := decodePacket(body)
	if err != nil {
		return nil, err
	}
	result["state"], result["record"] = "recorded", recordFile
	return result, nil
}

// repeatedFindings returns the recorded findings of turn when the file is unchanged since; a
// changed or removed file is a conflict. It returns nothing when turn has no record.
func repeatedFindings(recordFile, file, turn string) (map[string]any, error) {
	body, err := os.ReadFile(recordFile)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	} else if err != nil {
		return nil, fmt.Errorf("cannot read findings record %s: %v", recordFile, reason(err))
	}
	recorded, err := decodePacket(body)
	if err != nil {
		return nil, fmt.Errorf("invalid findings record %s", recordFile)
	}
	data, err := readFindings(file)
	if err != nil {
		return nil, fmt.Errorf("the findings of turn %s were recorded in %s, but now: %v", turn, recordFile, err)
	}
	if sum := sha256.Sum256(data); hex.EncodeToString(sum[:]) != recorded["sha256"] {
		return nil, fmt.Errorf("the findings of turn %s were recorded in %s with sha256 %v, and %s has changed since; a turn's findings are recorded once", turn, recordFile, recorded["sha256"], file)
	}
	recorded["state"], recorded["record"] = "existing", recordFile
	return recorded, nil
}

// reviewTurn reads turn's saved record, which must be an ended review-packet pass of packet id that
// ran in tree, and returns the reviewer identity with the fingerprint its scope names.
func reviewTurn(home, turn, tree, id string) (map[string]any, error) {
	data, err := os.ReadFile(filepath.Join(home, "turns", turn, "turn.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("unknown turn %s", turn)
	} else if err != nil {
		return nil, fmt.Errorf("cannot read turn %s: %v", turn, reason(err))
	}
	var run map[string]any
	if json.Unmarshal(data, &run) != nil || run["id"] != turn {
		return nil, fmt.Errorf("invalid saved turn %s", turn)
	}
	cwd, _ := run["cwd"].(string)
	if canonical, err := materialized(cwd); cwd == "" || cwd != tree && (err != nil || canonical != tree) {
		return nil, fmt.Errorf("turn %s ran in %q, not in %s; record the findings of the review pass in this packet's tree", turn, cwd, tree)
	}
	scope, _ := run["permissions"].(map[string]any)
	if scope["profile"] != "review-packet" || scope["packet_id"] != id {
		return nil, fmt.Errorf("turn %s is not a review-packet pass of packet %s (profile %v, packet %v)", turn, id, scope["profile"], scope["packet_id"])
	}
	if state, _ := run["state"].(string); !slices.Contains(ended, state) {
		return nil, fmt.Errorf("turn %s is %v; findings are recorded only after the review pass finished, stopped or was killed", turn, run["state"])
	}
	return map[string]any{"worker_id": run["worker_id"], "backend": run["backend"], "model": run["model"], "selection": run["selection"],
		"scope_fingerprint": scope["fingerprint"]}, nil
}

// turnSelection is the recorded backend selection of turn, or nil when its record is unreadable.
func turnSelection(home string, turn any) any {
	id, _ := turn.(string)
	if !savedTurn.MatchString(id) {
		return nil
	}
	data, err := os.ReadFile(filepath.Join(home, "turns", id, "turn.json"))
	if err != nil {
		return nil
	}
	var run map[string]any
	if json.Unmarshal(data, &run) != nil || run["id"] != id {
		return nil
	}
	return run["selection"]
}

// readFindings reads the regular file at most maxFindings bytes long, never following a symlink.
func readFindings(name string) ([]byte, error) {
	info, err := os.Lstat(name)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, refuse("findings_missing", "the review pass wrote no %s; nothing was recorded", name)
	} else if err != nil {
		return nil, refuse("findings_invalid", "cannot read %s: %v", name, reason(err))
	}
	if !info.Mode().IsRegular() {
		return nil, refuse("findings_invalid", "%s is not a regular file; nothing was recorded", name)
	}
	file, err := os.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, refuse("findings_invalid", "cannot read %s: %v", name, reason(err))
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxFindings+1))
	if err != nil {
		return nil, refuse("findings_invalid", "cannot read %s: %v", name, reason(err))
	}
	if len(data) > maxFindings {
		return nil, refuse("findings_invalid", "%s is larger than %d bytes (64 KiB); nothing was recorded", name, maxFindings)
	}
	return data, nil
}

// validFindings checks data against the fixed findings format for packet p: exact fields, the
// packet's ID and fingerprint, valid enums, paths in the packet and lines within their file.
func (f *folder) validFindings(data []byte, p *packet) error {
	if !utf8.Valid(data) {
		return errors.New("not UTF-8")
	}
	if err := uniqueKeys(data); err != nil {
		return err
	}
	doc, err := fields(data, "findings", "version", "packet_id", "fingerprint", "verdict", "summary", "findings", "checked", "not_checked")
	if err != nil {
		return err
	}
	var version int
	if json.Unmarshal(doc["version"], &version) != nil || version != 1 {
		return fmt.Errorf("version is %s, not 1", doc["version"])
	}
	for key, want := range map[string]string{"packet_id": p.PacketID, "fingerprint": p.Fingerprint} {
		if got, err := textField(doc, key, false); err != nil {
			return err
		} else if got != want {
			return fmt.Errorf("%s is %q, not this packet's %q", key, got, want)
		}
	}
	verdict, err := choice(doc, "verdict", verdicts)
	if err != nil {
		return err
	}
	if _, err = textField(doc, "summary", false); err != nil {
		return err
	}
	for _, key := range []string{"checked", "not_checked"} {
		var list []string
		if json.Unmarshal(doc[key], &list) != nil || list == nil {
			return fmt.Errorf("%s must be an array of strings", key)
		}
	}
	var items []json.RawMessage
	if json.Unmarshal(doc["findings"], &items) != nil || items == nil {
		return errors.New("findings must be an array")
	}
	seen := map[string]bool{}
	for i, raw := range items {
		where := fmt.Sprintf("findings[%d]", i)
		item, err := fields(raw, where, "id", "severity", "repository", "path", "lines", "problem", "evidence", "direction")
		if err != nil {
			return err
		}
		id, err := textField(item, "id", false)
		if err != nil {
			return fmt.Errorf("%s: %v", where, err)
		}
		if seen[id] {
			return fmt.Errorf("%s: id %q is not unique", where, id)
		}
		seen[id] = true
		where = fmt.Sprintf("finding %s", id)
		severity, err := choice(item, "severity", severities)
		if err != nil {
			return fmt.Errorf("%s: %v", where, err)
		}
		if severity == "blocking" && verdict == "pass" {
			return fmt.Errorf("%s is blocking, so the verdict cannot be pass", where)
		}
		if _, err = textField(item, "problem", false); err != nil {
			return fmt.Errorf("%s: %v", where, err)
		}
		for _, key := range []string{"evidence", "direction"} {
			if _, err = textField(item, key, true); err != nil {
				return fmt.Errorf("%s: %v", where, err)
			}
		}
		if err = f.located(item, p); err != nil {
			return fmt.Errorf("%s: %v", where, err)
		}
	}
	return nil
}

// located checks a finding's repository, path and lines, each of which may be null: the repository
// is one of the packet's, as diff.json names it; the path, relative to the tree as in diff.json, is in
// the tree or the baseline and in that repository; lines lie within the new (tree) or old (baseline)
// file.
func (f *folder) located(item map[string]json.RawMessage, p *packet) error {
	var repository, path *string
	if json.Unmarshal(item["repository"], &repository) != nil {
		return errors.New("repository must be a string or null")
	}
	if json.Unmarshal(item["path"], &path) != nil {
		return errors.New("path must be a string or null")
	}
	if repository != nil && !slices.ContainsFunc(p.Repositories, func(r packetRepository) bool { return r.Repository == *repository }) {
		return fmt.Errorf("repository %q is not a repository of the packet", *repository)
	}
	if path != nil {
		if !safe(*path) {
			return fmt.Errorf("path %q is not a relative path in the packet", *path)
		}
		if !f.inTree(*path) && f.entries[*path] == nil {
			return fmt.Errorf("path %q is neither in the packet tree nor in its baseline", *path)
		}
		owned := ""
		if r := owner(f.m.Repositories, *path); r != nil {
			owned = r.Repository
		}
		if repository != nil && *repository != owned {
			return fmt.Errorf("path %q is not in repository %q", *path, *repository)
		}
	}
	if string(item["lines"]) == "null" {
		return nil
	}
	lines, err := fields(item["lines"], "lines", "side", "start", "end")
	if err != nil {
		return err
	}
	side, err := choice(lines, "side", sides)
	if err != nil {
		return fmt.Errorf("lines: %v", err)
	}
	var start, end int
	if json.Unmarshal(lines["start"], &start) != nil || json.Unmarshal(lines["end"], &end) != nil || start < 1 || end < start {
		return errors.New("lines needs integers 1 <= start <= end")
	}
	if path == nil {
		return errors.New("lines need a path")
	}
	name := filepath.Join(f.dest, filepath.FromSlash(*path))
	if side == "new" && !f.inTree(*path) {
		return fmt.Errorf("lines on the new side need a file in the tree, and %q is not one", *path)
	}
	if side == "old" {
		e := f.entries[*path]
		if e == nil || e.Kind != "file" {
			return fmt.Errorf("lines on the old side need a file in the baseline, and %q is not one", *path)
		}
		name = filepath.Join(f.baseline, "tree", filepath.FromSlash(*path))
	}
	count, err := countLines(name)
	if err != nil {
		return fmt.Errorf("lines on the %s side need a file, and %q is not one", side, *path)
	}
	if end > count {
		return fmt.Errorf("lines %d-%d are outside the %s side of %q, which has %d lines", start, end, side, *path, count)
	}
	return nil
}

// inTree reports whether path names something in the tree below real directories only, so a
// symlink in the tree never leads a finding outside it.
func (f *folder) inTree(path string) bool {
	name := f.dest
	for _, segment := range strings.Split(path, "/") {
		if info, err := os.Lstat(name); err != nil || !info.IsDir() {
			return false
		}
		name = filepath.Join(name, segment)
	}
	_, err := os.Lstat(name)
	return err == nil
}

// countLines counts the lines of the regular file name as diffs do: a last line without a
// newline counts. Symlinks are never followed.
func countLines(name string) (int, error) {
	file, err := os.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return 0, err
	}
	defer file.Close()
	if info, err := file.Stat(); err != nil || !info.Mode().IsRegular() {
		return 0, errors.New("not a regular file")
	}
	count, last := 0, byte('\n')
	reader := bufio.NewReader(file)
	buffer := make([]byte, 32<<10)
	for {
		n, err := reader.Read(buffer)
		count += bytes.Count(buffer[:n], []byte{'\n'})
		if n > 0 {
			last = buffer[n-1]
		}
		if err == io.EOF {
			break
		} else if err != nil {
			return 0, err
		}
	}
	if last != '\n' {
		count++
	}
	return count, nil
}

// fields decodes the JSON object raw, which must have exactly the keys named.
func fields(raw []byte, what string, keys ...string) (map[string]json.RawMessage, error) {
	var object map[string]json.RawMessage
	if json.Unmarshal(raw, &object) != nil || object == nil {
		return nil, fmt.Errorf("%s must be a JSON object", what)
	}
	for _, key := range keys {
		if _, ok := object[key]; !ok {
			return nil, fmt.Errorf("%s has no %q (use null where the format allows it)", what, key)
		}
	}
	for key := range object {
		if !slices.Contains(keys, key) {
			return nil, fmt.Errorf("%s has the unknown field %q", what, key)
		}
	}
	return object, nil
}

// textField is the string field key; a blank one is refused unless empty is allowed.
func textField(object map[string]json.RawMessage, key string, empty bool) (string, error) {
	var value string
	if json.Unmarshal(object[key], &value) != nil || string(object[key]) == "null" {
		return "", fmt.Errorf("%s must be a string", key)
	}
	if !empty && strings.TrimSpace(value) == "" {
		return "", fmt.Errorf("%s must not be empty", key)
	}
	return value, nil
}

func choice(object map[string]json.RawMessage, key string, allowed []string) (string, error) {
	var value string
	if json.Unmarshal(object[key], &value) != nil || !slices.Contains(allowed, value) {
		return "", fmt.Errorf("%s is %s, not one of %q", key, object[key], allowed)
	}
	return value, nil
}

// uniqueKeys refuses one JSON value with a repeated object key anywhere, or trailing data: a
// duplicate would let readers disagree on the verdict.
func uniqueKeys(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var walk func() error
	walk = func() error {
		token, err := decoder.Token()
		if err != nil {
			return errors.New("not one JSON value")
		}
		switch token {
		case json.Delim('{'):
			seen := map[string]bool{}
			for decoder.More() {
				key, err := decoder.Token()
				if err != nil {
					return errors.New("not one JSON value")
				}
				if seen[key.(string)] {
					return fmt.Errorf("the key %q appears twice in one object", key)
				}
				seen[key.(string)] = true
				if err = walk(); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
			return err
		case json.Delim('['):
			for decoder.More() {
				if err = walk(); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
			return err
		}
		return nil
	}
	if err := walk(); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return errors.New("not one JSON value")
	}
	return nil
}

// publish writes the new read-only file name with body; an existing file is never replaced.
func publish(name string, body []byte) error {
	file, err := os.CreateTemp(filepath.Dir(name), ".record-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, err = file.Write(append(body, '\n'))
	if cerr := file.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Chmod(file.Name(), 0444)
	}
	if err != nil {
		return err
	}
	return renameExclusive(file.Name(), name)
}

// Packets lists the packets frozen from the folder dest, oldest first along their previous links,
// each with its recorded findings. It only reads.
func Packets(home, dest string) (map[string]any, error) {
	if canonical, err := materialized(dest); err == nil {
		dest = canonical
	} else if dest, err = packetPath(dest); err != nil {
		return nil, err
	}
	result := map[string]any{"destination": dest, "packets": []any{}}
	home, err := filepath.EvalSymlinks(home)
	if errors.Is(err, fs.ErrNotExist) {
		return result, nil
	} else if err != nil {
		return nil, err
	}
	names, err := os.ReadDir(filepath.Join(home, "packets"))
	if errors.Is(err, fs.ErrNotExist) {
		return result, nil
	} else if err != nil {
		return nil, err
	}
	all := map[string]*packet{}
	for _, name := range names {
		// Staging folders and anything else that is not a packet ID are not packets.
		if !changeID.MatchString(name.Name()) {
			continue
		}
		p, err := loadPacket(home, name.Name())
		if err != nil {
			return nil, err
		}
		all[p.PacketID] = p
	}
	// depth is the number of recorded packets before p along previous links.
	depth := func(p *packet) int {
		n, seen := 0, map[string]bool{p.PacketID: true}
		for p.Previous != nil && all[p.Previous.PacketID] != nil && !seen[p.Previous.PacketID] {
			p = all[p.Previous.PacketID]
			seen[p.PacketID] = true
			n++
		}
		return n
	}
	mine := []*packet{}
	for _, p := range all {
		if p.Author["dest"] == dest {
			mine = append(mine, p)
		}
	}
	sort.Slice(mine, func(i, j int) bool {
		a, b := mine[i], mine[j]
		if da, db := depth(a), depth(b); da != db {
			return da < db
		}
		if a.CreatedAt != b.CreatedAt {
			return a.CreatedAt < b.CreatedAt
		}
		return a.PacketID < b.PacketID
	})
	listed := []any{}
	for _, p := range mine {
		findings, err := findingsOf(home, p.PacketID)
		if err != nil {
			return nil, err
		}
		listed = append(listed, map[string]any{"packet_id": p.PacketID, "fingerprint": p.Fingerprint, "previous": p.Previous, "snapshot_id": p.SnapshotID,
			"created_at": p.CreatedAt, "author": p.Author, "packet": filepath.Dir(p.Tree), "findings": findings})
	}
	result["packets"] = listed
	return result, nil
}

// findingsOf is every findings record of packet id, oldest first.
func findingsOf(home, id string) ([]any, error) {
	dir := filepath.Join(PacketDir(home, id), "findings")
	names, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return []any{}, nil
	} else if err != nil {
		return nil, err
	}
	records := []map[string]any{}
	for _, name := range names {
		turn, ok := strings.CutSuffix(name.Name(), ".json")
		if !ok || !savedTurn.MatchString(turn) {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, name.Name()))
		if err != nil {
			return nil, fmt.Errorf("cannot read findings record %s: %v", name.Name(), reason(err))
		}
		record, err := decodePacket(data)
		if err != nil || record["review_turn"] != turn {
			return nil, fmt.Errorf("invalid findings record %s", filepath.Join(dir, name.Name()))
		}
		records = append(records, record)
	}
	sort.Slice(records, func(i, j int) bool {
		a, b := fmt.Sprint(records[i]["recorded_at"]), fmt.Sprint(records[j]["recorded_at"])
		if a != b {
			return a < b
		}
		return fmt.Sprint(records[i]["review_turn"]) < fmt.Sprint(records[j]["review_turn"])
	})
	listed := make([]any, len(records))
	for i, r := range records {
		listed[i] = r
	}
	return listed, nil
}
