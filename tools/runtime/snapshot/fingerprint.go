package snapshot

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

var fingerprintID = regexp.MustCompile(`^fpr_[0-9a-f]{64}$`)

// requestCanonical is the JSON Code stores as a change's request.json, without change_id:
// Elixir's JSON.encode! of {"base_revision", "entries", "repository", "snapshot_id"} with the
// entries sorted by path, in the encoding of manifest.canonical. A delete is {"op", "path"}; a
// write is {"kind", "mode", "op", "path", "sha256", "size", "target"?}. A clean repository has
// "entries": [].
func requestCanonical(snapshotID, repository, base string, entries []changeEntry) []byte {
	sorted := slices.Clone(entries)
	slices.SortFunc(sorted, func(a, b changeEntry) int { return strings.Compare(a.Path, b.Path) })
	var b bytes.Buffer
	field(&b, `{"base_revision":`, base)
	b.WriteString(`,"entries":[`)
	for i, e := range sorted {
		if i > 0 {
			b.WriteByte(',')
		}
		if e.Op == "delete" {
			field(&b, `{"op":`, e.Op)
			field(&b, `,"path":`, e.Path)
			b.WriteByte('}')
			continue
		}
		field(&b, `{"kind":`, e.Kind)
		field(&b, `,"mode":`, e.Mode)
		field(&b, `,"op":`, e.Op)
		field(&b, `,"path":`, e.Path)
		field(&b, `,"sha256":`, e.SHA256)
		b.WriteString(`,"size":` + strconv.FormatInt(e.Size, 10))
		if e.Target != nil {
			field(&b, `,"target":`, *e.Target)
		}
		b.WriteByte('}')
	}
	b.WriteByte(']')
	field(&b, `,"repository":`, repository)
	field(&b, `,"snapshot_id":`, snapshotID)
	b.WriteByte('}')
	return b.Bytes()
}

// fingerprint is a repository's content identity: "fpr_" + the hex SHA-256 of requestCanonical.
// It is independent of the change ID, so Code can recompute it from request.json.
func fingerprint(snapshotID, repository, base string, entries []changeEntry) string {
	sum := sha256.Sum256(requestCanonical(snapshotID, repository, base, entries))
	return "fpr_" + hex.EncodeToString(sum[:])
}
