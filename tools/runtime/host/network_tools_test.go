package host

import (
	"slices"
	"testing"
)

func TestNetworkProfilesSelectCodexWebSearchOnStartAndResume(t *testing.T) {
	// Permission rendering needs no repository or native Codex process.
	t.Setenv("PATH", "/usr/bin")
	t.Setenv("CODEX_HOME", "")
	scope := map[string]any{
		"root": "/project", "home": "/runtime", "record": "/runtime/record.json",
		"baseline": "/runtime/baseline", "repositories": []any{"repo"},
	}
	folder, err := folderArguments(scope, "/runtime/scratch/turn", "/worker-home", "/usr/bin/atlas-runtime")
	if err != nil {
		t.Fatal(err)
	}
	scope["root"], scope["packet"], scope["findings"] = "/packet/tree", "/packet", "/packet/findings"
	packet, err := packetArguments(scope, "/runtime/scratch/turn", "/worker-home", "/usr/bin/atlas-runtime")
	if err != nil {
		t.Fatal(err)
	}
	repository, err := repositoryArguments(map[string]any{"root": "/repository"})
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name, mode  string
		permissions []string
	}{
		{"read-only", `web_search="disabled"`, []string{"--sandbox", "read-only"}},
		{"workspace-write", `web_search="disabled"`, []string{"--sandbox", "workspace-write"}},
		{"folder", `web_search="disabled"`, folder},
		{"review", `web_search="disabled"`, packet},
		{"repository", `web_search="live"`, repository},
	} {
		for _, session := range []string{"", "confirmed-session"} {
			command := codexCommand("codex", "/project", "/artifacts", "next", test.permissions, session, "")
			index := slices.Index(command, test.mode)
			if index < 1 || command[index-1] != "-c" {
				t.Fatalf("%s session %q: missing web search config in %q", test.name, session, command)
			}
			last := ""
			for i, value := range command {
				if i > 0 && command[i-1] == "-c" && (value == `web_search="disabled"` || value == `web_search="live"`) {
					last = value
				}
			}
			if last != test.mode {
				t.Fatalf("%s session %q: effective web search config %q, want %q", test.name, session, last, test.mode)
			}
		}
	}
}
