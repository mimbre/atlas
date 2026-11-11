package snapshot

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// discarded is <home>/packets/<id>/discarded.json, the stamp a discard leaves in the kept record.
type discarded struct {
	PacketID    string `json:"packet_id"`
	Packet      string `json:"packet"`
	Tree        string `json:"tree"`
	Fingerprint string `json:"fingerprint"`
	DiscardedAt string `json:"discarded_at"`
}

// Discard removes the folder of a frozen review packet, named by its packet ID or by its path,
// with the tree's materialization record and preparation copy, and stamps discarded_at in the
// packet's record. It refuses while a review pass holds the tree's lock. <home>/packets/<id>/
// (packet.json, diff.json and the findings records) is kept. A repeat reports the same discard.
func Discard(home, path, id string) (map[string]any, error) {
	switch {
	case (path == "") == (id == ""):
		return nil, errors.New("name the packet by exactly one of its path or its packet ID")
	case id != "" && !changeID.MatchString(id):
		return nil, errors.New("packet ID must be a lowercase UUID")
	}
	home, err := filepath.EvalSymlinks(home)
	if err != nil {
		return nil, err
	}
	var p *packet
	if id != "" {
		if p, err = recordedPacket(home, id); err != nil {
			return nil, err
		}
	} else if p, err = packetAt(home, path); err != nil {
		return nil, err
	}
	if stamp, err := readDiscarded(home, p.PacketID); stamp != nil || err != nil {
		return stamp, err
	}

	tree, folder := p.Tree, filepath.Dir(p.Tree)
	if _, err := os.Lstat(folder); err == nil {
		// Only the folder this packet's record names, still recorded as its tree, is removed.
		info, err := os.Lstat(tree)
		if err != nil || !info.IsDir() {
			return nil, fmt.Errorf("%s is not the folder of packet %s: it has no tree directory; nothing was discarded", folder, p.PacketID)
		}
		lock, err := hold(tree, "discard", "nothing was discarded")
		if err != nil {
			return nil, err
		}
		defer lock.Close()
		if recorded, err := RecordedPacket(home, tree); err != nil || recorded != p.PacketID {
			return nil, fmt.Errorf("%s is not the folder of packet %s: its tree is not recorded as that packet's; nothing was discarded", folder, p.PacketID)
		}
		if err = removeTree(folder); err != nil {
			return nil, fmt.Errorf("cannot discard %s: %v; run the command again", folder, reason(err))
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("cannot discard %s: %v", folder, reason(err))
	}
	// The folder is gone; a failure from here on is completed by a repeat.
	if err = os.Remove(recordPath(home, tree)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	if err = os.RemoveAll(preparationDir(home, tree)); err != nil {
		return nil, err
	}
	return stampDiscarded(home, discarded{PacketID: p.PacketID, Packet: folder, Tree: tree, Fingerprint: p.Fingerprint,
		DiscardedAt: time.Now().UTC().Format(time.RFC3339)})
}

// recordedPacket reads the authoritative packet.json of packet id.
func recordedPacket(home, id string) (*packet, error) {
	data, err := os.ReadFile(filepath.Join(PacketDir(home, id), "packet.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("packet %s does not exist under %s", id, filepath.Join(home, "packets"))
	} else if err != nil {
		return nil, fmt.Errorf("cannot read packet %s: %v", id, reason(err))
	}
	var p packet
	if json.Unmarshal(data, &p) != nil || p.PacketID != id || !fingerprintID.MatchString(p.Fingerprint) || !filepath.IsAbs(p.Tree) || filepath.Base(p.Tree) != "tree" {
		return nil, fmt.Errorf("invalid packet record %s", id)
	}
	return &p, nil
}

// packetAt finds the recorded packet frozen into the folder path, which need not exist any more.
// After a discard a later freeze may reuse the path; the packet not yet discarded is chosen then.
func packetAt(home, path string) (*packet, error) {
	folder, err := packetPath(path)
	if err != nil {
		return nil, err
	}
	if canonical, err := materialized(folder); err == nil {
		folder = canonical
	}
	entries, err := os.ReadDir(filepath.Join(home, "packets"))
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	var live, gone *packet
	goneAt := ""
	for _, e := range entries {
		if !e.IsDir() || !changeID.MatchString(e.Name()) {
			continue
		}
		p, err := recordedPacket(home, e.Name())
		if err != nil {
			return nil, err
		}
		if filepath.Dir(p.Tree) != folder {
			continue
		}
		stamp, err := readDiscarded(home, p.PacketID)
		switch {
		case err != nil:
			return nil, err
		case stamp == nil && live != nil:
			return nil, fmt.Errorf("packets %s and %s both name %s; discard by packet ID", live.PacketID, p.PacketID, folder)
		case stamp == nil:
			live = p
		case stamp["discarded_at"].(string) >= goneAt:
			gone, goneAt = p, stamp["discarded_at"].(string)
		}
	}
	if live != nil {
		return live, nil
	}
	if gone != nil {
		return gone, nil
	}
	return nil, fmt.Errorf("no recorded packet was frozen into %s", folder)
}

// readDiscarded returns the discard result recorded for packet id, or nothing before its discard.
func readDiscarded(home, id string) (map[string]any, error) {
	data, err := os.ReadFile(filepath.Join(PacketDir(home, id), "discarded.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	} else if err != nil {
		return nil, fmt.Errorf("cannot read the discard of packet %s: %v", id, reason(err))
	}
	var d discarded
	if json.Unmarshal(data, &d) != nil || d.PacketID != id || d.DiscardedAt == "" {
		return nil, fmt.Errorf("invalid discard record of packet %s", id)
	}
	return discardResult(home, d), nil
}

// stampDiscarded adds discarded.json to the read-only record of the packet without replacing an
// existing stamp; a concurrent discard that stamped first is reported instead.
func stampDiscarded(home string, d discarded) (map[string]any, error) {
	dir := PacketDir(home, d.PacketID)
	body, err := json.Marshal(d)
	if err != nil {
		return nil, err
	}
	if err = os.Chmod(dir, 0700); err != nil {
		return nil, err
	}
	defer os.Chmod(dir, 0555)
	file, err := os.CreateTemp(dir, ".discarded-*")
	if err != nil {
		return nil, err
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
		return nil, err
	}
	if err = renameExclusive(file.Name(), filepath.Join(dir, "discarded.json")); errors.Is(err, fs.ErrExist) {
		return readDiscarded(home, d.PacketID)
	} else if err != nil {
		return nil, err
	}
	return discardResult(home, d), nil
}

func discardResult(home string, d discarded) map[string]any {
	return map[string]any{"state": "discarded", "packet_id": d.PacketID, "packet": d.Packet, "tree": d.Tree,
		"fingerprint": d.Fingerprint, "discarded_at": d.DiscardedAt, "record": PacketDir(home, d.PacketID)}
}

// removeTree deletes a packet folder whose tree was made read-only. Like the host's scratch
// cleanup it first gives the owner write (and, for directories, read and search) permission on
// every directory and file, then removes the folder. Symbolic links are never followed or changed:
// the walk skips them, and every change goes through an os.Root confined to the folder, so a link
// put in place of a directory in between still cannot reach outside it.
func removeTree(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return errors.New("not a directory")
	}
	if info.Mode().Perm()&0700 != 0700 {
		if err = os.Chmod(path, info.Mode().Perm()|0700); err != nil {
			return err
		}
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return err
	}
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
		if current, err := root.Lstat(name); err == nil && current.Mode().Type() == entry.Type() && current.Mode().Perm()&want != want {
			root.Chmod(name, current.Mode().Perm()|want)
		}
		return nil
	})
	root.Close()
	return os.RemoveAll(path)
}
