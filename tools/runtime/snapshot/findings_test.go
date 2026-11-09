package snapshot

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

// reviewedPacket freezes the author folder into packet id and saves an ended review turn named
// name that ran in its tree, as Runtime saves a review-packet pass. It returns the packet folder,
// the review turn and the packet's fingerprint.
func reviewedPacket(t *testing.T, f *fixture, dest, author, name, id, previous string) (string, string, string) {
	t.Helper()
	path := packetFolder(t, f.parent, name)
	p, err := Freeze(f.home, dest, author, path, id, previous)
	must(t, err)
	return path, savedReview(t, f.home, filepath.Join(path, "tree"), name, "finished", id, p["fingerprint"].(string)), p["fingerprint"].(string)
}

// savedReview saves a review-packet turn of packet id that ran in tree, and returns its ID.
func savedReview(t *testing.T, home, tree, name, state, id, fingerprint string) string {
	t.Helper()
	turn := fmt.Sprintf("turn-%x", sha256.Sum256([]byte(tree+name+state)))[:21]
	run := map[string]any{"id": turn, "worker_id": "reviewer", "backend": "claude", "model": "model-r", "state": state, "cwd": tree,
		"selection":   map[string]any{"requested": map[string]any{"backend": "claude", "model": nil}, "selected": map[string]any{"backend": "claude", "model": "model-r"}, "reason": "preferred"},
		"permissions": map[string]any{"profile": "review-packet", "root": tree, "packet": filepath.Dir(tree), "packet_id": id, "fingerprint": fingerprint}}
	body, _ := json.Marshal(run)
	must(t, os.MkdirAll(filepath.Join(home, "turns", turn), 0700))
	must(t, os.WriteFile(filepath.Join(home, "turns", turn, "turn.json"), body, 0600))
	return turn
}

// validFindings is a findings file for the authorFolder packet that uses every location form.
func validFindings(id, fingerprint string) map[string]any {
	return map[string]any{"version": 1, "packet_id": id, "fingerprint": fingerprint, "verdict": "changes_required", "summary": "one blocking problem",
		"findings": []any{
			map[string]any{"id": "F1", "severity": "blocking", "repository": "github.com/test/one", "path": "one/a.txt",
				"lines": map[string]any{"side": "new", "start": 1, "end": 2}, "problem": "p", "evidence": "e", "direction": "d"},
			map[string]any{"id": "F2", "severity": "note", "repository": "github.com/test/one", "path": "one/gone.txt",
				"lines": map[string]any{"side": "old", "start": 1, "end": 1}, "problem": "p", "evidence": "", "direction": ""},
			map[string]any{"id": "F3", "severity": "should-fix", "repository": nil, "path": "notes.md", "lines": nil, "problem": "p", "evidence": "e", "direction": "d"},
			map[string]any{"id": "F4", "severity": "note", "repository": "github.com/test/two", "path": nil, "lines": nil, "problem": "p", "evidence": "e", "direction": "d"},
			map[string]any{"id": "F5", "severity": "note", "repository": nil, "path": nil, "lines": nil, "problem": "p", "evidence": "e", "direction": "d"},
		},
		"checked": []any{"tests"}, "not_checked": []any{}}
}

func writeFindings(t *testing.T, packet string, data []byte) {
	t.Helper()
	must(t, os.WriteFile(filepath.Join(packet, "findings", "findings.json"), data, 0600))
}

func marshalFindings(t *testing.T, doc map[string]any) []byte {
	t.Helper()
	data, err := json.MarshalIndent(doc, "", "  ")
	must(t, err)
	return data
}

func TestFindingsAreRecordedWithBothSelectionsAndRepeat(t *testing.T) {
	f, _, _, dest := authorFolder(t)
	author := authorTurn(t, f.home, dest, "finished")
	path, review, fingerprint := reviewedPacket(t, f, dest, author, "packet", packetA, "")
	data := marshalFindings(t, validFindings(packetA, fingerprint))
	writeFindings(t, path, data)

	// Reached through a symlinked home, the record is still reported at its canonical path.
	home := filepath.Join(f.parent, "home-link")
	must(t, os.Symlink(f.home, home))
	result, err := Findings(home, path, review)
	must(t, err)
	record := filepath.Join(PacketDir(realPath(t, f.home), packetA), "findings", review+".json")
	if result["state"] != "recorded" || result["record"] != record {
		t.Fatalf("result %v", result)
	}
	if contend(t, filepath.Join(path, "tree")) == false {
		t.Fatal("findings kept the tree lock")
	}
	saved := readPacket(t, record)
	sum := sha256.Sum256(data)
	var file any
	must(t, json.Unmarshal(data, &file))
	want := map[string]any{"version": float64(1), "packet_id": packetA, "fingerprint": fingerprint, "review_turn": review, "sha256": hex.EncodeToString(sum[:]),
		"reviewer": map[string]any{"worker_id": "reviewer", "backend": "claude", "model": "model-r",
			"selection": map[string]any{"requested": map[string]any{"backend": "claude", "model": nil}, "selected": map[string]any{"backend": "claude", "model": "model-r"}, "reason": "preferred"}},
		"author":   map[string]any{"turn_id": author, "worker_id": "author", "backend": "codex", "model": "model-x", "selection": map[string]any{"reason": "explicit"}},
		"findings": file, "recorded_at": saved["recorded_at"]}
	if !reflect.DeepEqual(saved, want) {
		t.Fatalf("record\n%v\nwant\n%v", saved, want)
	}
	if info, err := os.Stat(record); err != nil || info.Mode().Perm() != 0444 {
		t.Fatalf("record mode %v %v", info, err)
	}
	delete(result, "state")
	delete(result, "record")
	if !reflect.DeepEqual(result, saved) {
		t.Fatalf("result %v, record %v", result, saved)
	}

	// A repeat returns the same record; the file changed afterwards is a conflict, not a new record.
	again, err := Findings(f.home, path, review)
	must(t, err)
	if again["state"] != "existing" {
		t.Fatalf("repeat %v", again)
	}
	delete(again, "state")
	delete(again, "record")
	if !reflect.DeepEqual(again, saved) {
		t.Fatalf("repeat %v, record %v", again, saved)
	}
	before := mustRead(t, record)
	writeFindings(t, path, marshalFindings(t, map[string]any{"verdict": "pass"}))
	if _, err = Findings(f.home, path, review); err == nil || !strings.Contains(err.Error(), "has changed since") {
		t.Fatalf("changed after recording: %v", err)
	}
	if string(mustRead(t, record)) != string(before) {
		t.Fatal("the record was replaced")
	}

	// Exactly 64 KiB is accepted for another review pass of the same packet.
	doc := validFindings(packetA, fingerprint)
	doc["verdict"], doc["findings"], doc["summary"] = "pass", []any{}, ""
	size := len(marshalFindings(t, doc))
	doc["summary"] = strings.Repeat("s", maxFindings-size)
	exact := marshalFindings(t, doc)
	if len(exact) != maxFindings {
		t.Fatalf("fixture is %d bytes", len(exact))
	}
	writeFindings(t, path, exact)
	second := savedReview(t, f.home, filepath.Join(path, "tree"), "second", "stopped", packetA, fingerprint)
	if result, err = Findings(f.home, path, second); err != nil || result["state"] != "recorded" {
		t.Fatalf("64 KiB: %v %v", result, err)
	}
}

func TestFindingsRefusals(t *testing.T) {
	f, _, _, dest := authorFolder(t)
	author := authorTurn(t, f.home, dest, "finished")
	path, review, fingerprint := reviewedPacket(t, f, dest, author, "packet", packetA, "")
	tree := filepath.Join(path, "tree")
	records := filepath.Join(PacketDir(f.home, packetA), "findings")
	refused := func(t *testing.T, turn, code, want string) {
		t.Helper()
		_, err := Findings(f.home, path, turn)
		var refusal *FindingsRefusal
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Fatalf("got %v, want %q", err, want)
		}
		if errors.As(err, &refusal) != (code != "") || code != "" && refusal.Code != code {
			t.Fatalf("code of %v: want %q", err, code)
		}
		if left, _ := os.ReadDir(records); len(left) != 0 {
			t.Fatalf("recorded %v", left)
		}
	}
	file := func(change func(map[string]any)) []byte {
		doc := validFindings(packetA, fingerprint)
		change(doc)
		return marshalFindings(t, doc)
	}
	finding := func(i int, key string, value any) []byte {
		return file(func(doc map[string]any) { doc["findings"].([]any)[i].(map[string]any)[key] = value })
	}
	lines := func(side string, start, end int) map[string]any {
		return map[string]any{"side": side, "start": start, "end": end}
	}

	t.Run("missing", func(t *testing.T) { refused(t, review, "findings_missing", "wrote no") })
	for _, c := range []struct {
		name, want string
		data       []byte
	}{
		{"over 64 KiB", "larger than 65536 bytes", file(func(doc map[string]any) { doc["summary"] = strings.Repeat("s", maxFindings) })},
		{"array", "findings must be a JSON object", []byte("[]")},
		{"not JSON", "not one JSON value", []byte(`{"version": 1,`)},
		{"trailing data", "not one JSON value", append(file(func(map[string]any) {}), []byte(" {}")...)},
		{"not UTF-8", "not UTF-8", []byte("{\"summary\": \"\xff\"}")},
		{"repeated key", `"verdict" appears twice`, []byte(strings.Replace(string(file(func(map[string]any) {})), `"verdict"`, `"verdict": "pass", "verdict"`, 1))},
		{"unknown field", `unknown field "score"`, file(func(doc map[string]any) { doc["score"] = 1 })},
		{"missing field", `has no "not_checked"`, file(func(doc map[string]any) { delete(doc, "not_checked") })},
		{"version", "version is 2", file(func(doc map[string]any) { doc["version"] = 2 })},
		{"other packet", "packet_id is", file(func(doc map[string]any) { doc["packet_id"] = packetB })},
		{"other fingerprint", "fingerprint is", file(func(doc map[string]any) { doc["fingerprint"] = "fpr_" + strings.Repeat("0", 64) })},
		{"verdict", "verdict is", file(func(doc map[string]any) { doc["verdict"] = "approved" })},
		{"empty summary", "summary must not be empty", file(func(doc map[string]any) { doc["summary"] = " " })},
		{"checked", "checked must be an array of strings", file(func(doc map[string]any) { doc["checked"] = []any{1} })},
		{"null findings", "findings must be an array", file(func(doc map[string]any) { doc["findings"] = nil })},
		{"severity", "severity is", finding(0, "severity", "major")},
		{"pass with blocking", "is blocking, so the verdict cannot be pass", file(func(doc map[string]any) { doc["verdict"] = "pass" })},
		{"duplicate id", `id "F1" is not unique`, finding(1, "id", "F1")},
		{"missing lines key", `has no "lines"`, file(func(doc map[string]any) { delete(doc["findings"].([]any)[2].(map[string]any), "lines") })},
		{"null problem", "problem must be a string", finding(0, "problem", nil)},
		{"unknown repository", `repository "github.com/test/three" is not`, finding(3, "repository", "github.com/test/three")},
		{"path in another repository", `is not in repository "github.com/test/two"`, finding(0, "repository", "github.com/test/two")},
		{"outside path with a repository", `path "notes.md" is not in repository`, finding(2, "repository", "github.com/test/one")},
		{"path not in the packet", "neither in the packet tree nor in its baseline", finding(0, "path", "one/nope.txt")},
		{"escaping path", "is not a relative path", finding(2, "path", "../work/notes.md")},
		{"absolute path", "is not a relative path", finding(2, "path", "/etc/hosts")},
		{"through a symlink", "neither in the packet tree", finding(2, "path", "one/link/x")},
		{"new lines past the end", "outside the new side of \"one/a.txt\", which has 2 lines", finding(0, "lines", lines("new", 2, 3))},
		{"old lines past the end", "outside the old side of \"one/a.txt\", which has 1 lines", finding(0, "lines", lines("old", 1, 2))},
		{"old lines of an added file", "need a file in the baseline", finding(2, "lines", lines("old", 1, 1))},
		{"new lines of a deleted file", "lines on the new side need a file", finding(1, "lines", lines("new", 1, 1))},
		{"lines of a directory", "need a file", file(func(doc map[string]any) {
			item := doc["findings"].([]any)[0].(map[string]any)
			item["path"], item["lines"] = "one/bin", lines("new", 1, 1)
		})},
		{"lines without a path", "lines need a path", finding(4, "lines", lines("new", 1, 1))},
		{"start after end", "1 <= start <= end", finding(0, "lines", lines("new", 2, 1))},
		{"zero start", "1 <= start <= end", finding(0, "lines", lines("new", 0, 1))},
		{"side", "side is", finding(0, "lines", lines("both", 1, 1))},
	} {
		t.Run(c.name, func(t *testing.T) {
			writeFindings(t, path, c.data)
			refused(t, review, "findings_invalid", c.want)
		})
	}
	t.Run("symlinked file", func(t *testing.T) {
		outside := filepath.Join(f.parent, "elsewhere.json")
		must(t, os.WriteFile(outside, file(func(map[string]any) {}), 0600))
		name := filepath.Join(path, "findings", "findings.json")
		os.Remove(name)
		must(t, os.Symlink(outside, name))
		t.Cleanup(func() { os.Remove(name) })
		refused(t, review, "findings_invalid", "is not a regular file")
	})

	// The rest have a valid file; the turn, the lock or the packet is wrong.
	valid := file(func(map[string]any) {})
	t.Run("running turn", func(t *testing.T) {
		writeFindings(t, path, valid)
		refused(t, savedReview(t, f.home, tree, "running", "running", packetA, fingerprint), "", "is running")
	})
	t.Run("author turn", func(t *testing.T) { refused(t, author, "", "not in "+tree) })
	t.Run("turn of another profile", func(t *testing.T) {
		other := savedReview(t, f.home, tree, "folder", "finished", packetA, fingerprint)
		turnFile := filepath.Join(f.home, "turns", other, "turn.json")
		var run map[string]any
		must(t, json.Unmarshal(mustRead(t, turnFile), &run))
		run["permissions"].(map[string]any)["profile"] = "materialized-folder"
		body, _ := json.Marshal(run)
		must(t, os.WriteFile(turnFile, body, 0600))
		refused(t, other, "", "is not a review-packet pass of packet")
	})
	t.Run("turn of another packet", func(t *testing.T) {
		refused(t, savedReview(t, f.home, tree, "other", "finished", packetB, fingerprint), "", "is not a review-packet pass of packet")
	})
	t.Run("turn that reviewed another fingerprint", func(t *testing.T) {
		refused(t, savedReview(t, f.home, tree, "stale", "finished", packetA, "fpr_"+strings.Repeat("1", 64)), "", "reviewed fingerprint")
	})
	t.Run("unknown turn", func(t *testing.T) { refused(t, "turn-00000000000000ff", "", "unknown turn") })
	t.Run("lock held", func(t *testing.T) {
		owner, err := os.Open(tree)
		must(t, err)
		defer owner.Close()
		must(t, syscall.Flock(int(owner.Fd()), syscall.LOCK_EX|syscall.LOCK_NB))
		refused(t, review, "", "has an active Runtime owner")
	})
	t.Run("not a packet", func(t *testing.T) {
		if _, err := Findings(f.home, dest, review); err == nil || !strings.Contains(err.Error(), "is not a review packet folder") {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("packet.json changed", func(t *testing.T) {
		name := filepath.Join(path, "packet.json")
		original := mustRead(t, name)
		must(t, os.Chmod(path, 0700))
		must(t, os.Chmod(name, 0644))
		must(t, os.WriteFile(name, append(original, ' '), 0644))
		refused(t, review, "packet_modified", "packet.json was changed")
		must(t, os.WriteFile(name, original, 0444))
	})
	t.Run("tree modified", func(t *testing.T) {
		name := filepath.Join(tree, "one", "a.txt")
		must(t, os.Chmod(filepath.Dir(name), 0755))
		must(t, os.Chmod(name, 0644))
		must(t, os.WriteFile(name, []byte("changed after review\n"), 0644))
		refused(t, review, "packet_modified", "the tree was modified after the freeze")
	})
}

func TestPacketsListsTheChainInOrderWithItsFindings(t *testing.T) {
	f, _, _, dest := authorFolder(t)
	// IDs sort opposite to the chain, so only the previous links can give the order.
	first, second, third := "5c0ffee0-0000-4000-8000-0000000000cc", "5c0ffee0-0000-4000-8000-0000000000bb", "5c0ffee0-0000-4000-8000-0000000000aa"
	recorded := func(path, id, turn, fingerprint, verdict string) {
		doc := validFindings(id, fingerprint)
		doc["verdict"] = verdict
		if verdict == "pass" {
			doc["findings"] = []any{}
		}
		writeFindings(t, path, marshalFindings(t, doc))
		_, err := Findings(f.home, path, turn)
		must(t, err)
	}
	p1, r1, f1 := reviewedPacket(t, f, dest, authorTurn(t, f.home, dest, "finished"), "first", first, "")
	recorded(p1, first, r1, f1, "changes_required")
	must(t, os.WriteFile(filepath.Join(dest, "one", "a.txt"), []byte("rework 1\nmore\n"), 0644))
	p2, r2, f2 := reviewedPacket(t, f, dest, authorTurn(t, f.home, dest, "stopped"), "second", second, first)
	recorded(p2, second, r2, f2, "changes_required")
	must(t, os.WriteFile(filepath.Join(dest, "one", "a.txt"), []byte("rework 2\nmore\n"), 0644))
	p3, _, f3 := reviewedPacket(t, f, dest, authorTurn(t, f.home, dest, "killed"), "third", third, second)

	listed, err := Packets(f.home, dest)
	must(t, err)
	if listed["destination"] != realPath(t, dest) {
		t.Fatalf("destination %v", listed["destination"])
	}
	packets := jsonValue(t, listed["packets"]).([]any)
	want := []struct {
		id, path, fingerprint, previous string
		verdicts                        []string
	}{{first, p1, f1, "", []string{"changes_required"}}, {second, p2, f2, first, []string{"changes_required"}}, {third, p3, f3, second, nil}}
	if len(packets) != len(want) {
		t.Fatalf("packets %v", packets)
	}
	for i, w := range want {
		p := packets[i].(map[string]any)
		if p["packet_id"] != w.id || p["packet"] != realPath(t, w.path) || p["fingerprint"] != w.fingerprint || p["author"].(map[string]any)["dest"] != realPath(t, dest) {
			t.Fatalf("packet %d: %v", i, p)
		}
		if previous, _ := p["previous"].(map[string]any); w.previous == "" && previous != nil || w.previous != "" && (previous["packet_id"] != w.previous || previous["fingerprint"] != packets[i-1].(map[string]any)["fingerprint"]) {
			t.Fatalf("packet %d previous %v", i, p["previous"])
		}
		verdicts := []string{}
		for _, r := range p["findings"].([]any) {
			r := r.(map[string]any)
			if r["packet_id"] != w.id {
				t.Fatalf("packet %d lists findings of %v", i, r["packet_id"])
			}
			verdicts = append(verdicts, r["findings"].(map[string]any)["verdict"].(string))
		}
		if len(verdicts) != len(w.verdicts) || len(verdicts) > 0 && !reflect.DeepEqual(verdicts, w.verdicts) {
			t.Fatalf("packet %d verdicts %v, want %v", i, verdicts, w.verdicts)
		}
	}

	// Other folders list nothing, and listing writes nothing.
	before := state(t, f.home)
	other, err := Packets(f.home, filepath.Join(f.parent, "never"))
	must(t, err)
	if len(other["packets"].([]any)) != 0 {
		t.Fatalf("other folder %v", other)
	}
	if _, err = Packets(f.home, p1+"/tree"); err != nil {
		t.Fatal(err)
	}
	equal(t, state(t, f.home), before)
	empty, err := Packets(filepath.Join(f.parent, "no-home"), dest)
	if err != nil || len(empty["packets"].([]any)) != 0 {
		t.Fatalf("no home: %v %v", empty, err)
	}
}

// realPath is path with every symlink resolved: the form Runtime reports paths in. A test
// temporary directory can lie below a symlink (macOS /var is /private/var).
func realPath(t *testing.T, path string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(path)
	must(t, err)
	return resolved
}
