package snapshot

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

// TestFingerprintGolden checks the canonical bytes and fingerprints against testdata generated
// with Elixir's JSON.encode!, which Code uses for request.json; Code's tests read the same file.
func TestFingerprintGolden(t *testing.T) {
	var golden struct {
		Cases []struct {
			Name    string `json:"name"`
			Request struct {
				BaseRevision string        `json:"base_revision"`
				Entries      []changeEntry `json:"entries"`
				Repository   string        `json:"repository"`
				SnapshotID   string        `json:"snapshot_id"`
			} `json:"request"`
			Canonical   string `json:"canonical"`
			Fingerprint string `json:"fingerprint"`
		} `json:"cases"`
	}
	must(t, json.Unmarshal(mustRead(t, filepath.Join("testdata", "fingerprints.json")), &golden))
	names := []string{}
	for _, c := range golden.Cases {
		names = append(names, c.Name)
		r := c.Request
		got := requestCanonical(r.SnapshotID, r.Repository, r.BaseRevision, r.Entries)
		if string(got) != c.Canonical {
			t.Errorf("%s: canonical\n%q\nwant\n%q", c.Name, got, c.Canonical)
		}
		sum := sha256.Sum256([]byte(c.Canonical))
		if f := fingerprint(r.SnapshotID, r.Repository, r.BaseRevision, r.Entries); f != c.Fingerprint || f != "fpr_"+hex.EncodeToString(sum[:]) || !fingerprintID.MatchString(f) {
			t.Errorf("%s: fingerprint %s, want %s", c.Name, f, c.Fingerprint)
		}
	}
	slices.Sort(names)
	if !slices.Equal(names, []string{"add", "binary", "clean", "delete", "escapes", "mode", "symlink"}) {
		t.Fatalf("golden cases: %v", names)
	}
}

// The fingerprint is of the content alone: neither the entry order nor a nil slice changes it.
func TestFingerprintIgnoresEntryOrder(t *testing.T) {
	a := changeEntry{Path: "b", Op: "delete"}
	b := changeEntry{Path: "a", Op: "write", Kind: "file", Mode: "100644", Size: 1, SHA256: hex.EncodeToString(make([]byte, 32))}
	if fingerprint("s", "r", "v", []changeEntry{a, b}) != fingerprint("s", "r", "v", []changeEntry{b, a}) ||
		fingerprint("s", "r", "v", nil) != fingerprint("s", "r", "v", []changeEntry{}) {
		t.Fatal("fingerprint depends on entry order or nil entries")
	}
}

// approve returns the fingerprint Code would compute from a change request body Submit sent,
// after checking that the hashed form holds exactly that request without change_id.
func approve(t *testing.T, body []byte) string {
	t.Helper()
	var request struct {
		SnapshotID   string        `json:"snapshot_id"`
		Repository   string        `json:"repository"`
		BaseRevision string        `json:"base_revision"`
		Entries      []changeEntry `json:"entries"`
	}
	must(t, json.Unmarshal(body, &request))
	canonical := requestCanonical(request.SnapshotID, request.Repository, request.BaseRevision, request.Entries)
	var sent, hashed map[string]any
	must(t, json.Unmarshal(body, &sent))
	must(t, json.Unmarshal(canonical, &hashed))
	delete(sent, "change_id")
	entries := sent["entries"].([]any)
	slices.SortFunc(entries, func(a, b any) int {
		return strings.Compare(a.(map[string]any)["path"].(string), b.(map[string]any)["path"].(string))
	})
	if !reflect.DeepEqual(sent, hashed) {
		t.Fatalf("canonical %s differs from the request %s", canonical, body)
	}
	sum := sha256.Sum256(canonical)
	return "fpr_" + hex.EncodeToString(sum[:])
}
