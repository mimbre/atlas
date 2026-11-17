package host

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// The static Runtime home census (S6 P0). Every entry name the Runtime's code joins to a path is
// extracted from the sources and must be classified in exactly one of censusHome and censusNotHome:
//   - Go: every non-test file of the host module (testdata excluded): each string literal argument of
//     filepath.Join, each string-literal operand of a + concatenation in such an argument, and each
//     const or var of the same package with a string literal value that is such an argument;
//   - Elixir: every .ex file under lib and the host's .exs scripts: each string literal in the arguments
//     of a Path.join (direct, list or piped form) and each module attribute with a string literal value
//     that is used there, in the same file;
//   - the model contract (model/contract/lib): each persisted record's path.
//
// The name is the literal's first path segment, whatever its first character. Names built only by
// interpolation or at run time are not seen; the runtime census (S6 SP2) covers those.
//
// A home name of class denied must be in sensitiveHomeNames, which a Codex managed repository's profile
// denies by path even when absent at launch; a chain name is on a managed repository's ancestor chain,
// and siblingWorkerGlobs deny its other entries. The atomic-write sibling <name>.tmp of a denied home
// file must be in sensitiveHomeNames too, because a deny of <name> does not cover it: fail closed for every
// denied .json file, and for every other denied file joined in a source that writes "… <> \".tmp\"" (Elixir)
// or "… + \".tmp\"" (Go). A .tmp entry of sensitiveHomeNames must be the sibling of a denied home file. Both tables are exact: an entry no source has (other than
// a reserved home name) fails as stale. A slice that adds a home name classifies it here in its own change.

type censusEntry struct {
	class    string // denied or chain
	holds    string
	reserved bool // listed before it has a code site
}

var censusHome = map[string]censusEntry{
	"runtime.sock":          {"denied", "the guidance and journal socket", false},
	"backend.sock":          {"denied", "the work, operations and history contracts socket, which grants operate", false},
	"turns":                 {"denied", "the turn folders and their records", false},
	"code.json":             {"denied", "the Code configuration, naming the Code token", false},
	"server.json":           {"denied", "the Atlas Server configuration", false},
	"backends.json":         {"denied", "the legacy backend preference pair", false},
	"policy.json":           {"denied", "the human-owned backend policy", false},
	"availability.json":     {"denied", "the harness availability", false},
	"service.log":           {"denied", "the daemon log", false},
	"service.lock":          {"denied", "the daemon lock", false},
	"passes":                {"denied", "the flow pass bindings; no code site since S5b B1, deny kept", true},
	"snapshots":             {"denied", "the snapshot store and baselines", false},
	"materializations":      {"denied", "the materialization records", false},
	"scratch":               {"denied", "the workers' scratch (each turn's own is re-allowed)", false},
	"work":                  {"denied", "the work records, key index and change sequence", false},
	"admissions":            {"denied", "the command admissions", false},
	"preparations":          {"denied", "the folder preparation requests, results and logs", false},
	"packets":               {"denied", "the frozen review packets and findings", false},
	"submissions":           {"denied", "the snapshot-submit records", false},
	"rebinds":               {"denied", "the rebind journals and destination backups", false},
	"frozen":                {"denied", "the work core's private frozen results and their blobs (S5a)", false},
	"execution-events.json": {"denied", "the execution-event outbox", false},
	"mode.json":             {"denied", "the persisted Runtime mode (S2)", false},
	"clients.json":          {"denied", "the S3 loopback TCP clients; no code site since work-acquisition M0, deny kept", true},
	"sources":               {"denied", "the work sources' credentials and per-source stores, e.g. sources/<name>/token (work acquisition M2, F4; code site sources/credential.ex, W3)", false},
	"local-source":          {"denied", "the local work source's queue store (work acquisition M2, F4)", false},
	"bases":                 {"denied", "every client's uploaded base records and the import staging (S5c); code site sources/import.ex (work acquisition M2 W5)", false},
	"workers":               {"chain", "the managed repositories' worker directories", false},
}

// censusNotHome are the joined names that are not Runtime home entries, with where they live.
var censusNotHome = map[string]string{
	// The user home and the toolchains' own files.
	".local":          "user home (~/.local/state/atlas-runtime, the default Runtime home)",
	"state":           "user home (~/.local/state/atlas-runtime, the default Runtime home)",
	"atlas-runtime":   "user home (~/.local/state/atlas-runtime, the default Runtime home)",
	".codex":          "user home, or a project's Codex configuration",
	".claude":         "user home (Claude configuration)",
	"shell-snapshots": "Claude configuration directory",
	"session-env":     "Claude configuration directory",
	"config.toml":     "a Codex configuration directory",
	// Projects, repositories and folders.
	".git":              "a project, repository or folder root",
	".agents":           "a dedicated repository root",
	".aws":              "a dedicated repository root",
	"package.json":      "a materialized folder's package",
	"package-lock.json": "a materialized folder's package",
	// Turn folders (<home>/turns/<turn>).
	"answer.txt":          "turn folder",
	"stderr.log":          "turn folder",
	"stream.jsonl":        "turn folder",
	"process.json":        "turn folder, or a preparation's diagnostics directory",
	"turn.json":           "turn folder",
	"claude-context.json": "turn folder",
	"handoff.json":        "turn folder",
	"questions":           "turn folder",
	"peer-questions":      "turn folder",
	".json":               "suffix of a question record name in a turn folder",
	// The private temp and the Claude temporary roots.
	"claude-": "prefix of a Claude temporary root in the private temp",
	".ac-":    "prefix of the private temp in the system temp",
	// Snapshot baselines, packets, rebinds and preparations (below snapshots, packets, rebinds, preparations).
	"tree":           "snapshot baseline, packet or its staging",
	"manifest.json":  "snapshot baseline",
	"complete":       "snapshot baseline marker",
	"entries.json":   "base import staging (<home>/bases/.staging-*, S5c): line 1 of the base stream",
	"findings":       "packet",
	"packet.json":    "packet",
	"discarded.json": "packet",
	"findings.json":  "packet findings directory",
	"done":           "rebind directory",
	"journal.json":   "rebind directory",
	"backup":         "rebind directory",
	"result.json":    "preparation directory",
	"private":        "preparation directory",
	"request.json":   "preparation directory",
	"npm-run":        "preparation diagnostics directory",
	"outcome.json":   "preparation diagnostics directory",
	// A worker directory (<home>/workers/<worker>), on a managed repository's ancestor chain.
	"admission-latch.json": "worker directory",
	"work-<name>":          "a placeholder for a Runtime work folder <home>/workers/work-<name> in compose's refusal message (snapshot/compose.go)",
	"work-":                "prefix of a Runtime work folder <home>/workers/work-<work_id> (work/folders.ex, S5a P7a)",
	"/":                    "the filesystem root, from which work/folders.ex resolves a path component by component",
	// Below work (<home>/work).
	"sequence": "work directory",
	"*.tmp":    "work directory (temporary-file glob)",
	"*.json":   "work or frozen directory (record glob)",
	// Below frozen (<home>/frozen, S5a P7b/P8: work/frozen_store.ex).
	"blobs":      "frozen directory (the frozen results' blob folder); base import staging (<home>/bases/.staging-*, S5c): the blobs by sha256",
	"*.json.tmp": "frozen directory (temporary-file glob)",
	// Codex sessions, the fake inbox and the source tree.
	"sessions":      "Codex home (~/.codex/sessions)",
	"inbox.dets":    "the fake inbox's own directory",
	"identity.json": "the fake inbox's own directory",
	"build":         "the host's build directory",
	// Below the host's build directory (<home>/build), which the service runs from without Mix
	// (host/main.go serviceCommands, host/boot.exs): <build>/lib/*/ebin and <build>/consolidated.
	"lib":          "the host's build directory (<home>/build/lib)",
	"*":            "the host's build directory (the ebin wildcard <home>/build/lib/*/ebin, which elixir expands)",
	"ebin":         "the host's build directory (<home>/build/lib/<app>/ebin)",
	"consolidated": "the host's build directory (<home>/build/consolidated)",
	"products":     "the repository root (software_factory)",
	"platform":     "the repository root (service.exs)",
	// verify_sandbox.exs: its own test directory.
	"workspace":     "verify_sandbox.exs test directory",
	"codex-home":    "verify_sandbox.exs test directory",
	"proof.txt":     "verify_sandbox.exs workspace",
	"sandbox-probe": "verify_sandbox.exs test directory",
	"native":        "verify_sandbox.exs test directory",
	// The S6 fixture tables (host/internal/s6fixture, a test helper): the module root and its fixtures.
	"go.mod":   "the host module root (s6fixture.Dir finds it upwards)",
	"test":     "the S6 fixture tables (platform/atlas_runtime/test/fixtures/s6)",
	"fixtures": "the S6 fixture tables (platform/atlas_runtime/test/fixtures/s6)",
	"s6":       "the S6 fixture tables (platform/atlas_runtime/test/fixtures/s6)",
	"s6-":      "prefix of an S6 fixture root in the system temp (s6fixture.NewRoot)",
	// The native facts helper's private directory (sandbox/facts.ex: atlas-facts-<hex> in the system temp).
	"stdin":  "the facts helper's private temp directory",
	"stderr": "the facts helper's private temp directory",
	// Below sources (<home>/sources/<name>, work acquisition M2 W3: sources/credential.ex).
	"token": "source directory (<home>/sources/<name>/token, sources/credential.ex)",
}

type censusSite struct {
	file string // relative to platform/atlas_runtime
	line int
	how  string
}

func (s censusSite) String() string { return fmt.Sprintf("%s:%d (%s)", s.file, s.line, s.how) }

// censusName is the entry a joined literal names: its first path segment.
func censusName(literal string) string {
	if first, _, _ := strings.Cut(literal, "/"); first != "" {
		return first
	}
	return literal
}

// goCensus extracts the joined names of every non-test Go file of the host module.
func goCensus(t *testing.T, module, base string, sites map[string][]censusSite) (files int) {
	t.Helper()
	packages := map[string][]string{}
	err := filepath.WalkDir(module, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() && entry.Name() == "testdata" {
			return filepath.SkipDir
		}
		if !entry.IsDir() && strings.HasSuffix(path, ".go") && !strings.HasSuffix(path, "_test.go") {
			packages[filepath.Dir(path)] = append(packages[filepath.Dir(path)], path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, paths := range packages {
		fileset := token.NewFileSet()
		var parsed []*ast.File
		constants := map[string][]string{}
		for _, path := range paths {
			file, err := parser.ParseFile(fileset, path, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			files++
			parsed = append(parsed, file)
			ast.Inspect(file, func(node ast.Node) bool {
				if spec, ok := node.(*ast.ValueSpec); ok {
					for i, name := range spec.Names {
						if i < len(spec.Values) {
							if literal, ok := spec.Values[i].(*ast.BasicLit); ok && literal.Kind == token.STRING {
								value, _ := strconv.Unquote(literal.Value)
								constants[name.Name] = append(constants[name.Name], value)
							}
						}
					}
				}
				return true
			})
		}
		for _, file := range parsed {
			ast.Inspect(file, func(node ast.Node) bool {
				call, ok := node.(*ast.CallExpr)
				if !ok {
					return true
				}
				selector, ok := call.Fun.(*ast.SelectorExpr)
				if !ok || selector.Sel.Name != "Join" {
					return true
				}
				if pkg, ok := selector.X.(*ast.Ident); !ok || pkg.Name != "filepath" {
					return true
				}
				var collect func(ast.Expr)
				collect = func(argument ast.Expr) {
					position := fileset.Position(argument.Pos())
					relative, _ := filepath.Rel(base, position.Filename)
					switch argument := argument.(type) {
					case *ast.BasicLit:
						if argument.Kind == token.STRING {
							value, _ := strconv.Unquote(argument.Value)
							name := censusName(value)
							sites[name] = append(sites[name], censusSite{relative, position.Line, "filepath.Join literal"})
						}
					case *ast.Ident:
						for _, value := range constants[argument.Name] {
							name := censusName(value)
							sites[name] = append(sites[name], censusSite{relative, position.Line, "filepath.Join of " + argument.Name})
						}
					case *ast.BinaryExpr:
						if argument.Op == token.ADD {
							collect(argument.X)
							collect(argument.Y)
						}
					case *ast.ParenExpr:
						collect(argument.X)
					}
				}
				for _, argument := range call.Args {
					collect(argument)
				}
				return true
			})
		}
	}
	return files
}

var (
	elixirAttribute = regexp.MustCompile(`(?m)^[ \t]*@([a-z_][A-Za-z0-9_]*)[ \t]+"((?:[^"\\]|\\.)*)"[ \t]*(?:#.*)?$`)
	elixirString    = regexp.MustCompile(`"((?:[^"\\]|\\.)*)"`)
	elixirUse       = regexp.MustCompile(`@([a-z_][A-Za-z0-9_]*)`)
	modelPersist    = regexp.MustCompile(`persist:\s*\[[^\]]*?\bpath:\s*"([^"]+)"`)
	// An atomic write's temporary sibling: path <> ".tmp" (Elixir) or path + ".tmp" (Go).
	temporarySuffix = regexp.MustCompile(`(?:<>|\+)\s*"\.tmp"`)
)

// elixirArguments returns the text between the parenthesis at open and its match, skipping strings.
func elixirArguments(source string, open int) string {
	depth := 0
	for i := open; i < len(source); i++ {
		switch source[i] {
		case '"':
			for i++; i < len(source) && source[i] != '"'; i++ {
				if source[i] == '\\' {
					i++
				}
			}
		case '(':
			depth++
		case ')':
			if depth--; depth == 0 {
				return source[open+1 : i]
			}
		}
	}
	return source[open+1:]
}

// elixirAccess reports whether the string literal at [start, end) of arguments is a map key in an
// access such as scope["packet"], whose value, not the key, is the joined path.
func elixirAccess(arguments string, start, end int) bool {
	if start < 2 || end >= len(arguments) || arguments[start-1] != '[' || arguments[end] != ']' {
		return false
	}
	before := arguments[start-2]
	return before == '_' || before == ')' || before == ']' || before >= 'a' && before <= 'z' ||
		before >= 'A' && before <= 'Z' || before >= '0' && before <= '9'
}

// elixirCensus extracts the joined names of one Elixir source.
func elixirCensus(t *testing.T, path, base string, sites map[string][]censusSite) {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	source := string(body)
	relative, _ := filepath.Rel(base, path)
	attributes := map[string][]string{}
	for _, match := range elixirAttribute.FindAllStringSubmatch(source, -1) {
		attributes[match[1]] = append(attributes[match[1]], match[2])
	}
	for offset := 0; ; {
		index := strings.Index(source[offset:], "Path.join(")
		if index < 0 {
			break
		}
		start := offset + index
		open := start + len("Path.join")
		arguments := elixirArguments(source, open)
		line := func(at int) int { return strings.Count(source[:open+1+at], "\n") + 1 }
		for _, match := range elixirString.FindAllStringSubmatchIndex(arguments, -1) {
			if elixirAccess(arguments, match[0], match[1]) {
				continue
			}
			if value := arguments[match[2]:match[3]]; !strings.Contains(value, "#{") {
				name := censusName(value)
				sites[name] = append(sites[name], censusSite{relative, line(match[0]), "Path.join literal"})
			}
		}
		for _, match := range elixirUse.FindAllStringSubmatchIndex(arguments, -1) {
			for _, value := range attributes[arguments[match[2]:match[3]]] {
				name := censusName(value)
				sites[name] = append(sites[name], censusSite{relative, line(match[0]), "Path.join of @" + arguments[match[2]:match[3]]})
			}
		}
		offset = open + 1
	}
	if strings.Contains(relative, filepath.Join("model", "contract")) {
		for _, match := range modelPersist.FindAllStringSubmatchIndex(source, -1) {
			name := censusName(source[match[2]:match[3]])
			sites[name] = append(sites[name], censusSite{relative, strings.Count(source[:match[2]], "\n") + 1, "persisted path"})
		}
	}
}

// temporaryWriters are the scanned sources (relative to platform/atlas_runtime) that write an atomic
// write's .tmp sibling, with the line of each such write.
func temporaryWriters(t *testing.T, base string, paths []string) map[string][]int {
	t.Helper()
	writers := map[string][]int{}
	for _, path := range paths {
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		relative, _ := filepath.Rel(base, path)
		for _, match := range temporarySuffix.FindAllIndex(body, -1) {
			writers[relative] = append(writers[relative], strings.Count(string(body[:match[0]]), "\n")+1)
		}
	}
	return writers
}

// homeCensus is every joined name with its sites, the number of Go and Elixir files scanned and the
// temporaryWriters of those sources.
func homeCensus(t *testing.T) (map[string][]censusSite, int, int, map[string][]int) {
	t.Helper()
	base, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	sites := map[string][]censusSite{}
	goFiles := goCensus(t, filepath.Join(base, "host"), base, sites)
	var elixir []string
	for _, root := range []string{filepath.Join(base, "lib"), filepath.Join(base, "model", "contract", "lib")} {
		err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err == nil && !entry.IsDir() && strings.HasSuffix(path, ".ex") {
				elixir = append(elixir, path)
			}
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	scripts, err := filepath.Glob(filepath.Join(base, "host", "*.exs"))
	if err != nil {
		t.Fatal(err)
	}
	elixir = append(elixir, scripts...)
	for _, path := range elixir {
		elixirCensus(t, path, base, sites)
	}
	var goSources []string
	err = filepath.WalkDir(filepath.Join(base, "host"), func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() && entry.Name() == "testdata" {
			return filepath.SkipDir
		}
		if !entry.IsDir() && strings.HasSuffix(path, ".go") && !strings.HasSuffix(path, "_test.go") {
			goSources = append(goSources, path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return sites, goFiles, len(elixir), temporaryWriters(t, base, append(goSources, elixir...))
}

// temporarySibling reports whether the denied home name is a file whose atomic-write sibling name+".tmp"
// must be denied by path, and the writer sites that make it so: every .json file, and every other
// non-socket file joined in a source that writes a .tmp sibling.
func temporarySibling(name string, found []censusSite, writers map[string][]int) (bool, []string) {
	var why []string
	seen := map[string]bool{}
	for _, site := range found {
		if seen[site.file] {
			continue
		}
		seen[site.file] = true
		for _, line := range writers[site.file] {
			why = append(why, fmt.Sprintf("%s:%d (.tmp write)", site.file, line))
		}
	}
	file := strings.Contains(name, ".") && !strings.HasSuffix(name, ".sock")
	return file && (strings.HasSuffix(name, ".json") || len(why) > 0), why
}

// TestS6HomeCensus classifies every name the Runtime joins to a path (see censusHome) and checks the
// denied home names against sensitiveHomeNames, one subtest per classified name.
func TestS6HomeCensus(t *testing.T) {
	sites, goFiles, elixirFiles, writers := homeCensus(t)
	if goFiles == 0 || elixirFiles == 0 {
		t.Fatalf("census scanned %d Go and %d Elixir files", goFiles, elixirFiles)
	}
	var unclassified []string
	for name, found := range sites {
		_, home := censusHome[name]
		_, notHome := censusNotHome[name]
		if !home && !notHome {
			var where []string
			for _, site := range found {
				where = append(where, site.String())
			}
			unclassified = append(unclassified, fmt.Sprintf("%q at %s", name, strings.Join(where, ", ")))
		}
	}
	sort.Strings(unclassified)
	for _, entry := range unclassified {
		t.Errorf("unclassified Runtime home census name %s: classify it in runtime_home_census_test.go (a home entry also goes in sensitiveHomeNames)", entry)
	}
	var siblings []string
	for _, name := range sensitiveHomeNames {
		if base, ok := strings.CutSuffix(name, ".tmp"); ok {
			siblings = append(siblings, name)
			if entry, ok := censusHome[base]; !ok || entry.class != "denied" {
				t.Errorf("sensitiveHomeNames entry %q is not the atomic-write sibling of a denied home name of the census", name)
			} else if required, _ := temporarySibling(base, sites[base], writers); !required {
				t.Errorf("sensitiveHomeNames entry %q is the sibling of %q, which is not a home file written atomically", name, base)
			}
			continue
		}
		if entry, ok := censusHome[name]; !ok || entry.class != "denied" {
			t.Errorf("sensitiveHomeNames entry %q is not a denied home name of the census", name)
		}
	}
	sort.Strings(siblings)
	for _, name := range siblings {
		t.Run(name, func(t *testing.T) {
			base := strings.TrimSuffix(name, ".tmp")
			_, why := temporarySibling(base, sites[base], writers)
			t.Logf("atomic-write sibling of the denied home file %q; writers: %v", base, why)
		})
	}
	var names []string
	for name := range censusHome {
		names = append(names, name)
	}
	for name := range censusNotHome {
		names = append(names, name)
	}
	sort.Strings(names)
	t.Logf("census: %d Go files, %d Elixir files, %d names (%d home, %d not home)", goFiles, elixirFiles, len(sites), len(censusHome), len(censusNotHome))
	for _, name := range names {
		t.Run(name, func(t *testing.T) {
			found := sites[name]
			for _, site := range found {
				t.Logf("%s", site)
			}
			entry, home := censusHome[name]
			if _, notHome := censusNotHome[name]; home && notHome {
				t.Fatalf("%q is classified both as a home entry and as not a home entry", name)
			}
			switch {
			case !home && len(found) == 0:
				t.Fatalf("stale: no source joins %q any more; drop it from censusNotHome", name)
			case !home:
				return
			case entry.reserved && len(found) > 0:
				t.Fatalf("%q is reserved but has a code site now (%s); it is no longer reserved", name, found[0])
			case !entry.reserved && len(found) == 0:
				t.Fatalf("stale: no source joins the home entry %q any more; drop it or mark it reserved", name)
			}
			listed := slices.Contains(sensitiveHomeNames, name)
			switch entry.class {
			case "denied":
				if !listed {
					t.Fatalf("home entry %q (%s) is missing from sensitiveHomeNames, so a Codex managed repository does not deny it when it is absent at launch; sites: %v", name, entry.holds, found)
				}
				if required, why := temporarySibling(name, found, writers); required && !slices.Contains(sensitiveHomeNames, name+".tmp") {
					t.Fatalf("the atomic-write sibling %q of the home file %q (%s) is missing from sensitiveHomeNames, so a Codex managed repository leaves the content readable before the rename; writers: %v", name+".tmp", name, entry.holds, why)
				}
			case "chain":
				if listed {
					t.Fatalf("chain entry %q is in sensitiveHomeNames, which would refuse every managed repository below it", name)
				}
			default:
				t.Fatalf("home entry %q has the unknown class %q", name, entry.class)
			}
		})
	}
}
