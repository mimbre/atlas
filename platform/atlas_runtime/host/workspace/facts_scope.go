package workspace

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/eyra/atlas/platform/atlas_runtime/host/snapshot"
)

// Scope facts (S6 A1): the inspections Scope and FolderScope make, reported raw for
// AtlasRuntime.Sandbox.Scope to decide on. Nothing here refuses: an inspection that fails is
// reported as {"error": text} with the text the legacy decision would return, and a fact that
// needs an earlier one it could not get is left out. The Git metadata facts of a dedicated
// root (rev_parse, shared, metadata_link) are null unless the root is canonical with its own
// .git directory: git never runs, and the metadata is never read, where Scope would not.
// Only malformed arguments fail the kind.
//
//	workspace facts dedicated PATH
//	workspace facts folder DEST HOME
func init() {
	Register("dedicated", func(args []string, _ io.Reader) (any, error) {
		if len(args) != 1 {
			return nil, errors.New("workspace facts dedicated requires one path")
		}
		return dedicatedFacts(args[0]), nil
	})
	Register("folder", func(args []string, _ io.Reader) (any, error) {
		if len(args) != 2 {
			return nil, errors.New("workspace facts folder requires destination and Runtime home")
		}
		return folderFacts(args[0], args[1]), nil
	})
}

func factPath(path string, err error) map[string]any {
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	return map[string]any{"path": path}
}

// dedicatedFacts are the inspections of Scope (workspace.go), in its order.
func dedicatedFacts(path string) map[string]any {
	facts := map[string]any{"path": path}
	root, err := workspaceAbsolute(path)
	facts["absolute"] = factPath(root, err)
	if err != nil {
		return facts
	}
	resolved, err := workspaceResolve(root)
	facts["resolved"] = factPath(resolved, err)
	canonical := err == nil && resolved == root

	gitDir := workspacePath(root + "/.git")
	gitFact := map[string]any{"path": gitDir}
	if info, err := os.Lstat(gitDir); err != nil {
		gitFact["error"] = err.Error()
	} else {
		gitFact["type"] = fileType(info.Mode())
	}
	facts["git_dir"] = gitFact

	// The rev-parse triple, with the inherited GIT_* variables scrubbed as Scope does. Git runs
	// only where Scope would run it, at a canonical root with its own .git directory, so
	// collecting facts never makes git follow a .git file or symlink elsewhere; otherwise the
	// fact is null.
	facts["rev_parse"] = nil
	if !canonical || gitFact["type"] != "dir" {
		facts["shared"], facts["metadata_link"] = nil, nil
		facts["codex_config"] = codexConfigFacts(root)
		return facts
	}
	env := []string{}
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "GIT_") {
			env = append(env, entry)
		}
	}
	stdout, stderr, code, err := workspaceRun([]string{"git", "-C", root, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"}, env)
	if err != nil {
		facts["rev_parse"] = map[string]any{"error": err.Error()}
	} else {
		facts["rev_parse"] = map[string]any{"exit": code, "stdout": stdout, "stderr": stderr}
	}

	shared := []any{}
	for _, name := range []string{"commondir", "objects/info/alternates", "objects/info/http-alternates", "worktrees"} {
		exists, err := workspaceExists(filepath.Join(gitDir, name))
		if err != nil {
			shared = append(shared, map[string]any{"name": name, "error": err.Error()})
		} else {
			shared = append(shared, map[string]any{"name": name, "exists": exists})
		}
	}
	facts["shared"] = shared

	// The first symlink or shared hardlink in the Git metadata, in Scope's walk order.
	var link any
	err = filepath.WalkDir(gitDir, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return filepath.SkipDir
		}
		if entry.Type()&os.ModeSymlink != 0 {
			link = map[string]any{"kind": "symlink", "path": path}
			return filepath.SkipAll
		}
		if !entry.IsDir() {
			info, err := entry.Info()
			if err != nil {
				return err
			}
			if info.Mode().IsRegular() && info.Sys().(*syscall.Stat_t).Nlink > 1 {
				link = map[string]any{"kind": "hardlink", "path": path}
				return filepath.SkipAll
			}
		}
		return nil
	})
	if err != nil {
		link = map[string]any{"error": err.Error()}
	}
	facts["metadata_link"] = link
	facts["codex_config"] = codexConfigFacts(root)
	return facts
}

func fileType(mode fs.FileMode) string {
	switch {
	case mode&os.ModeSymlink != 0:
		return "symlink"
	case mode.IsDir():
		return "dir"
	case mode.IsRegular():
		return "file"
	}
	return "other"
}

// codexConfigFacts are the candidates codexConfig checks for root, in its order, and the
// ignored config of the user's own Codex home. Every candidate is inspected, the ignored one
// too; which of them counts is the decision.
func codexConfigFacts(root string) map[string]any {
	facts := map[string]any{}
	codexHome, present := os.LookupEnv("CODEX_HOME")
	if !present {
		home, err := os.UserHomeDir()
		if err != nil {
			facts["ignored"] = map[string]any{"error": err.Error()}
			return facts
		}
		codexHome = filepath.Join(home, ".codex")
	}
	ignored, err := workspaceResolve(codexHome)
	if err != nil {
		facts["ignored"] = map[string]any{"error": err.Error()}
		return facts
	}
	facts["ignored"] = map[string]any{"path": filepath.Join(ignored, "config.toml")}
	candidates := []any{}
	candidate := func(config string) {
		exists, err := workspaceExists(config)
		if err != nil {
			candidates = append(candidates, map[string]any{"path": config, "error": err.Error()})
		} else {
			candidates = append(candidates, map[string]any{"path": config, "exists": exists})
		}
	}
	for directory := root; ; directory = filepath.Dir(directory) {
		candidate(filepath.Join(directory, ".codex/config.toml"))
		if directory == "/" || directory == codexConfigCeiling {
			break
		}
	}
	candidate("/etc/codex/config.toml")
	facts["candidates"] = candidates
	return facts
}

// folderFacts are the inspections of FolderScope and FolderScopeBeforePreparation
// (workspace.go), in their order. Paths that are not absolute are not inspected.
func folderFacts(dest, home string) map[string]any {
	facts := map[string]any{"dest": dest, "home": home,
		"dest_absolute": filepath.IsAbs(dest), "home_absolute": filepath.IsAbs(home)}
	if !filepath.IsAbs(dest) || !filepath.IsAbs(home) {
		return facts
	}
	resolved, err := filepath.EvalSymlinks(home)
	facts["home_resolved"] = factPath(resolved, err)
	if err != nil {
		return facts
	}
	canonical := filepath.Clean(dest)
	if parent, err := filepath.EvalSymlinks(filepath.Dir(canonical)); err == nil {
		canonical = filepath.Join(parent, filepath.Base(canonical))
	}
	facts["dest_canonical"], facts["dest_clean"] = canonical, filepath.Clean(dest)

	scope, err := snapshot.Verified(resolved, dest)
	if err != nil {
		facts["verified"] = map[string]any{"error": err.Error()}
		return facts
	}
	facts["verified"] = map[string]any{"scope": scope}
	root := scope["root"].(string)

	// The first .git here or above the folder.
	var git any
	for directory := root; ; directory = filepath.Dir(directory) {
		if _, err := os.Lstat(filepath.Join(directory, ".git")); err == nil {
			git = map[string]any{"path": filepath.Join(directory, ".git")}
			break
		} else if !errors.Is(err, os.ErrNotExist) {
			git = map[string]any{"error": err.Error()}
			break
		}
		if directory == "/" {
			break
		}
	}
	facts["git"] = git
	facts["codex_config"] = codexConfigFacts(root)

	if id, err := snapshot.RecordedPacket(resolved, root); err != nil {
		facts["packet"] = map[string]any{"error": err.Error()}
	} else {
		facts["packet"] = map[string]any{"id": id}
	}
	// The recorded preparation as LoadPreparation reads (and validates) it; null when none.
	if preparation, err := snapshot.LoadPreparation(resolved, root); err != nil {
		facts["preparation"] = map[string]any{"error": err.Error()}
	} else if preparation != nil {
		facts["preparation"] = map[string]any{"record": preparation}
	} else {
		facts["preparation"] = nil
	}
	return facts
}
