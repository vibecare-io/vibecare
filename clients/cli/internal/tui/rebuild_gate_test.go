package tui

import (
	"testing"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
)

// The gate, asserted from both sides of the build tag. `b` must be bound for
// a plugin in a dev build and bound to nothing at all in a release build —
// a shipped client should not carry a key that runs a program named by a
// file on disk.
//
// Written as one test rather than two tagged files so the two expectations
// sit next to each other and neither can be changed without seeing the other.
func TestRebuildIsDevOnly(t *testing.T) {
	m := testModel(130, 40)
	for m.subject().Kind != SubjectPlugin {
		m = step(m, key("]"))
	}

	b, bound := keymap.Lookup(m.keyCtx(), SubjectPlugin, m.focus, "b")

	if devTUI {
		if !bound {
			t.Fatal("dev build: b is not bound for a plugin, so rebuild is unreachable")
		}
		if b.Action != keymap.ActionPluginRebuild {
			t.Errorf("dev build: b = %q, want %q", b.Action, keymap.ActionPluginRebuild)
		}
		return
	}

	if bound {
		t.Errorf("release build: b is bound to %q; rebuild must not ship", b.Action)
	}
	// And nothing else may have quietly taken the action's place.
	for _, g := range keymap.All(m.keyCtx(), SubjectPlugin, m.focus) {
		for _, bind := range g.Bindings {
			if bind.Action == keymap.ActionPluginRebuild {
				t.Errorf("release build: %q is bound to the rebuild action", bind.Key)
			}
		}
	}
}

// A plugin that declares no build has nothing to rebuild from, and the
// client must say that rather than reporting a missing plugin — the two send
// a reader in completely different directions.
func TestRebuildNeedsADeclaredBuild(t *testing.T) {
	if !devTUI {
		t.Skip("release build: rebuild is not compiled in")
	}
	// Exercised through vc, which owns the distinction; see
	// TestPluginBuildRequiresAManifestEntry in internal/vc.
}
