package snapshot

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

// canonical resolves path through its nearest existing ancestor, so /var and /private/var compare equal
// for a path that no longer exists.
func canonical(t *testing.T, path string) string {
	t.Helper()
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	} else if !errors.Is(err, fs.ErrNotExist) || filepath.Dir(path) == path {
		t.Fatal(err)
	}
	return filepath.Join(canonical(t, filepath.Dir(path)), filepath.Base(path))
}

func gone(t *testing.T, paths ...string) {
	t.Helper()
	for _, path := range paths {
		if _, err := os.Lstat(path); !errors.Is(err, fs.ErrNotExist) {
			t.Errorf("%s exists: %v", path, err)
		}
	}
}

// frozen freezes the author folder into a new packet folder and returns the fixture, folder and packet folder.
func frozen(t *testing.T, id string) (*fixture, string, string) {
	t.Helper()
	f, _, _, dest := authorFolder(t)
	path := packetFolder(t, f.parent, "packet")
	_, err := Freeze(f.home, dest, authorTurn(t, f.home, dest, "finished"), path, id, "")
	must(t, err)
	return f, dest, path
}

func TestDiscardRemovesThePacketFolderAndKeepsItsHistory(t *testing.T) {
	f, dest, path := frozen(t, packetA)
	tree := filepath.Join(path, "tree")
	record := PacketDir(f.home, packetA)
	// A findings record, as snapshot findings keeps it, and what a review pass may leave in P/findings.
	must(t, os.WriteFile(filepath.Join(record, "findings", "turn-00000000000000bb.json"), []byte("{}\n"), 0444))
	outside := t.TempDir()
	must(t, os.WriteFile(filepath.Join(outside, "file"), []byte("keep\n"), 0444))
	must(t, os.Mkdir(filepath.Join(outside, "dir"), 0555))
	must(t, os.Symlink(filepath.Join(outside, "file"), filepath.Join(path, "findings", "file-link")))
	must(t, os.Symlink(filepath.Join(outside, "dir"), filepath.Join(path, "findings", "dir-link")))
	must(t, os.MkdirAll(filepath.Join(path, "findings", "nested", "deeper"), 0755))
	must(t, os.WriteFile(filepath.Join(path, "findings", "nested", "deeper", "findings.json"), []byte("{}"), 0444))
	must(t, os.Chmod(filepath.Join(path, "findings", "nested", "deeper"), 0500))
	must(t, os.Chmod(filepath.Join(path, "findings", "nested"), 0500))
	t.Cleanup(func() { os.Chmod(filepath.Join(outside, "dir"), 0755) })
	if _, err := os.Stat(preparationDir(f.home, tree)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		t.Fatal(err)
	}
	must(t, os.MkdirAll(preparationDir(f.home, tree), 0700))
	kept, folder, outsideBefore := state(t, record), state(t, dest), state(t, outside)

	// The packet is named through another spelling of its parent, as a caller on macOS may pass /var/….
	alias := filepath.Join(t.TempDir(), "alias")
	must(t, os.Symlink(f.parent, alias))
	result, err := Discard(f.home, filepath.Join(alias, "packet"), "")
	must(t, err)
	gone(t, path, recordPath(f.home, tree), preparationDir(f.home, tree))
	if left, _ := filepath.Glob(filepath.Join(f.parent, ".atlas-packet-*")); len(left) != 0 {
		t.Errorf("staging left: %v", left)
	}
	stamp := filepath.Join(record, "discarded.json")
	after := state(t, record)
	if _, ok := after[stamp]; !ok {
		t.Fatalf("no discard stamp in %v", after)
	}
	delete(after, stamp)
	delete(after, record) // the folder's mtime moves with the stamp
	delete(kept, record)
	equal(t, after, kept)
	equal(t, state(t, dest), folder)
	equal(t, state(t, outside), outsideBefore)
	if result["state"] != "discarded" || result["packet_id"] != packetA || result["discarded_at"] == "" ||
		canonical(t, result["packet"].(string)) != canonical(t, path) || canonical(t, result["tree"].(string)) != canonical(t, tree) ||
		canonical(t, result["record"].(string)) != canonical(t, record) {
		t.Fatalf("result %v", result)
	}
	if p := readPacket(t, filepath.Join(record, "packet.json")); result["fingerprint"] != p["fingerprint"] {
		t.Fatalf("fingerprint %v, packet %v", result["fingerprint"], p["fingerprint"])
	}

	// A repeat, by path or by ID, reports the same discard and changes nothing.
	stamped := state(t, f.home)
	for _, args := range [][2]string{{path, ""}, {"", packetA}} {
		again, err := Discard(f.home, args[0], args[1])
		must(t, err)
		if !reflect.DeepEqual(again, result) {
			t.Fatalf("repeat %q: %v, first %v", args, again, result)
		}
	}
	equal(t, state(t, f.home), stamped)
}

func TestDiscardRefusesWhileTheTreeLockIsHeld(t *testing.T) {
	f, _, path := frozen(t, packetA)
	tree := filepath.Join(path, "tree")
	owner, err := os.Open(tree)
	must(t, err)
	must(t, syscall.Flock(int(owner.Fd()), syscall.LOCK_EX|syscall.LOCK_NB))
	before := state(t, path, f.home)
	for _, args := range [][2]string{{path, ""}, {"", packetA}} {
		_, err = Discard(f.home, args[0], args[1])
		if err == nil || err.Error() != "folder "+canonical(t, tree)+" has an active Runtime owner; nothing was discarded, run the command again after it stops" {
			t.Fatalf("%q: %v", args, err)
		}
	}
	equal(t, state(t, path, f.home), before)
	must(t, owner.Close())
	_, err = Discard(f.home, "", packetA)
	must(t, err)
	gone(t, path, recordPath(f.home, tree))
}

func TestDiscardRefusesWhatIsNotARecordedPacketFolder(t *testing.T) {
	f, dest, path := frozen(t, packetA)
	tree := filepath.Join(path, "tree")
	for _, c := range []struct{ path, id, want string }{
		{"", "", "name the packet by exactly one of its path or its packet ID"},
		{path, packetA, "name the packet by exactly one of its path or its packet ID"},
		{"", "NOT-A-UUID", "packet ID must be a lowercase UUID"},
		{"", packetB, "packet " + packetB + " does not exist under " + filepath.Join(canonical(t, f.home), "packets")},
		{dest, "", "no recorded packet was frozen into " + canonical(t, dest)},
		{tree, "", "no recorded packet was frozen into " + canonical(t, tree)},
	} {
		if _, err := Discard(f.home, c.path, c.id); err == nil || err.Error() != c.want {
			t.Fatalf("%q %q: %v, want %s", c.path, c.id, err, c.want)
		}
	}

	// A folder at the packet's path whose tree is no longer recorded as the packet is kept.
	data := mustRead(t, recordPath(f.home, tree))
	must(t, os.Remove(recordPath(f.home, tree)))
	before := state(t, path)
	if _, err := Discard(f.home, "", packetA); err == nil || err.Error() != canonical(t, path)+" is not the folder of packet "+packetA+": its tree is not recorded as that packet's; nothing was discarded" {
		t.Fatalf("unrecorded tree: %v", err)
	}
	equal(t, state(t, path), before)
	gone(t, filepath.Join(PacketDir(f.home, packetA), "discarded.json"))
	must(t, os.WriteFile(recordPath(f.home, tree), data, 0600))

	// A folder there without a tree directory is kept too.
	must(t, os.Chmod(path, 0755))
	remove(tree)
	must(t, os.Symlink(dest, tree))
	if _, err := Discard(f.home, path, ""); err == nil || err.Error() != canonical(t, path)+" is not the folder of packet "+packetA+": it has no tree directory; nothing was discarded" {
		t.Fatalf("tree symlink: %v", err)
	}
	if info, err := os.Lstat(tree); err != nil || info.Mode().Type() != fs.ModeSymlink {
		t.Fatalf("tree link: %v %v", info, err)
	}
}

func TestDiscardCompletesAfterThePacketFolderIsGone(t *testing.T) {
	f, _, path := frozen(t, packetA)
	tree := filepath.Join(path, "tree")
	// As after a discard interrupted between removing the folder and its record.
	remove(path)
	result, err := Discard(f.home, path, "")
	must(t, err)
	gone(t, recordPath(f.home, tree))
	if result["state"] != "discarded" {
		t.Fatalf("result %v", result)
	}
}

func TestDiscardByPathSelectsThePacketNotYetDiscarded(t *testing.T) {
	f, dest, path := frozen(t, packetA)
	first, err := Discard(f.home, path, "")
	must(t, err)
	_, err = Freeze(f.home, dest, authorTurn(t, f.home, dest, "stopped"), path, packetB, packetA)
	must(t, err)
	second, err := Discard(f.home, path, "")
	must(t, err)
	if second["packet_id"] != packetB {
		t.Fatalf("discarded %v, want %s", second["packet_id"], packetB)
	}
	gone(t, path)
	// With both discarded, a repeat by path reports the later discard; by ID, each its own.
	for _, c := range []struct {
		path, id string
		want     map[string]any
	}{{path, "", second}, {"", packetA, first}, {"", packetB, second}} {
		got, err := Discard(f.home, c.path, c.id)
		must(t, err)
		if !reflect.DeepEqual(got, c.want) {
			t.Fatalf("%q %q: %v, want %v", c.path, c.id, got, c.want)
		}
	}
}

func TestDiscardAndFindingsCoordinate(t *testing.T) {
	f, _, _, dest := authorFolder(t)
	author := authorTurn(t, f.home, dest, "finished")
	path, review, fingerprint := reviewedPacket(t, f, dest, author, "packet", packetA, "")
	tree := filepath.Join(path, "tree")
	writeFindings(t, path, marshalFindings(t, validFindings(packetA, fingerprint)))

	// While discard holds the tree's lock, findings refuse and record nothing.
	lock, err := hold(tree, "discard", "nothing was discarded")
	must(t, err)
	if _, err = Findings(f.home, path, review); err == nil || !strings.Contains(err.Error(), "has an active Runtime owner; nothing was recorded") {
		lock.Close()
		t.Fatalf("findings under the discard lock: %v", err)
	}
	lock.Close()
	gone(t, filepath.Join(PacketDir(f.home, packetA), "findings", review+".json"))
	_, err = Findings(f.home, path, review)
	must(t, err)

	// A stamped packet takes no more findings, even with its folder still in place.
	second := savedReview(t, f.home, tree, "second", "stopped", packetA, fingerprint)
	_, err = stampDiscarded(f.home, discarded{PacketID: packetA, Packet: path, Tree: tree, Fingerprint: fingerprint, DiscardedAt: "2026-01-01T00:00:00Z"})
	must(t, err)
	var refusal *FindingsRefusal
	if _, err = Findings(f.home, path, second); !errors.As(err, &refusal) || refusal.Code != "packet_discarded" {
		t.Fatalf("findings of a discarded packet: %v", err)
	}
	gone(t, filepath.Join(PacketDir(f.home, packetA), "findings", second+".json"))
	must(t, os.Chmod(PacketDir(f.home, packetA), 0700))
	must(t, os.Remove(filepath.Join(PacketDir(f.home, packetA), "discarded.json")))
	must(t, os.Chmod(PacketDir(f.home, packetA), 0555))

	// After the discard, packets still lists the packet and its findings, with discarded_at.
	result, err := Discard(f.home, "", packetA)
	must(t, err)
	gone(t, path)
	if _, err = Findings(f.home, path, second); err == nil {
		t.Fatal("findings recorded after the discard")
	}
	listed, err := Packets(f.home, dest)
	must(t, err)
	packets := listed["packets"].([]any)
	if len(packets) != 1 {
		t.Fatalf("packets %v", packets)
	}
	p := packets[0].(map[string]any)
	if p["packet_id"] != packetA || p["discarded_at"] != result["discarded_at"] || len(p["findings"].([]any)) != 1 {
		t.Fatalf("listed %v", p)
	}
}
