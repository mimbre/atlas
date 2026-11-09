// Package testseam holds hooks that this module's tests use to keep product walks inside
// test-owned roots. Production code never calls them; internal/ keeps them out of other modules.
package testseam

// SetCodexConfigCeiling, installed by package workspace, stops its Codex-config ancestor walk
// at directory instead of "/" and returns a function that restores the previous ceiling.
var SetCodexConfigCeiling func(directory string) (restore func())
