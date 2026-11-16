package workspace

import "testing"

// limitCodexConfigWalk stops codexConfig's ancestor walk at the test-owned root for this test.
func limitCodexConfigWalk(t *testing.T, root string) {
	t.Helper()
	previous := codexConfigCeiling
	codexConfigCeiling = root
	t.Cleanup(func() { codexConfigCeiling = previous })
}
