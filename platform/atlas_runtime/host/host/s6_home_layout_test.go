package host

// S6 package A2e (review Y4): test/fixtures/s6/home_layout.json is the one checked-in list of the
// Runtime home's top-level names and classes. AtlasRuntime.Sandbox.HomeLayout asserts it on the
// Elixir side (test/sandbox/home_layout_test.exs); this test ties it to the static census
// (censusHome, runtime_home_census_test.go) and to the Go deny list it replaces
// (sensitiveHomeNames, runtimeSockets), so the census keeps a target after C2 removes the Go list.

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"testing"

	"github.com/eyra/atlas/platform/atlas_runtime/host/internal/s6fixture"
)

type homeLayout struct {
	Version int      `json:"version"`
	Note    string   `json:"note"`
	Sockets []string `json:"sockets"`
	Denied  []string `json:"denied"`
	Temps   []string `json:"atomic_temps"`
	Chain   []string `json:"chain"`
	Own     []string `json:"own"`
}

func TestS6HomeLayout(t *testing.T) {
	data, err := os.ReadFile(filepath.Join(s6fixture.Dir(t), "home_layout.json"))
	if err != nil {
		t.Fatal(err)
	}
	var layout homeLayout
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&layout); err != nil || layout.Version != 1 {
		t.Fatalf("home_layout.json: version %d, %v", layout.Version, err)
	}

	t.Run("sockets_are_runtimeSockets", func(t *testing.T) {
		if !slices.Equal(layout.Sockets, runtimeSockets) {
			t.Errorf("sockets %v, runtimeSockets %v", layout.Sockets, runtimeSockets)
		}
	})
	// The fixed P0 lists the census names first and their atomic temps last, so denied followed by
	// atomic_temps is sensitiveHomeNames in order.
	t.Run("denied_and_atomic_temps_are_sensitiveHomeNames_in_order", func(t *testing.T) {
		if got := slices.Concat(layout.Denied, layout.Temps); !slices.Equal(got, sensitiveHomeNames) {
			t.Errorf("denied ++ atomic_temps %v\nsensitiveHomeNames %v", got, sensitiveHomeNames)
		}
	})
	// The temps are what A2g's spec rows deny for a managed repository (withAtomicTemps). They are
	// kept apart from denied, which is the census class, and each is the sibling of a denied file.
	t.Run("atomic_temps_are_atomicHomeTemps_of_denied_files", func(t *testing.T) {
		if !slices.Equal(layout.Temps, atomicHomeTemps) {
			t.Errorf("atomic_temps %v, atomicHomeTemps %v", layout.Temps, atomicHomeTemps)
		}
		for _, name := range layout.Temps {
			base, ok := strings.CutSuffix(name, ".tmp")
			if !ok || !slices.Contains(layout.Denied, base) || slices.Contains(layout.Denied, name) || slices.Contains(layout.Chain, name) {
				t.Errorf("atomic temp %s is not the .tmp sibling of a denied name only", name)
			}
		}
	})
	t.Run("classes_are_the_census_classes", func(t *testing.T) {
		var denied, chain []string
		for name, entry := range censusHome {
			switch entry.class {
			case "denied":
				denied = append(denied, name)
			case "chain":
				chain = append(chain, name)
			default:
				t.Errorf("census name %s has class %q", name, entry.class)
			}
		}
		sort.Strings(denied)
		sort.Strings(chain)
		if got := slices.Sorted(slices.Values(layout.Denied)); !slices.Equal(got, denied) {
			t.Errorf("denied %v, census denied %v", got, denied)
		}
		if got := slices.Sorted(slices.Values(layout.Chain)); !slices.Equal(got, chain) {
			t.Errorf("chain %v, census chain %v", got, chain)
		}
	})
	t.Run("own_is_the_turn_scratch", func(t *testing.T) {
		if !slices.Equal(layout.Own, []string{"scratch/<turn>"}) || !slices.Contains(layout.Denied, "scratch") {
			t.Errorf("own %v", layout.Own)
		}
	})
}
