package tui

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/vibecare-io/vibecare/clients/cli/internal/logtail"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// rosterOf builds a roster of plugins named after their ids, so a test can
// say which rows the sidebar has without describing plugins it does not care
// about.
func rosterOf(ids ...string) vc.Roster {
	r := vc.Roster{BaseURL: "http://127.0.0.1:51234"}
	for _, id := range ids {
		r.Plugins = append(r.Plugins, vc.Plugin{ID: id, Name: id, State: vc.StateUp})
	}
	return r
}

// selectSubjectByID walks the cursor to a subject the way a user would.
func selectSubjectByID(t *testing.T, m model, id string) model {
	t.Helper()
	for i := 0; i < len(m.subjects); i++ {
		if m.subject().ID == id {
			return m
		}
		m = step(m, key("]"))
	}
	t.Fatalf("subject %q never became selected; subjects = %+v", id, m.subjects)
	return m
}

// A plugin vanishing from the roster must not drag the cursor onto whatever
// row inherited its index. The cursor names a plugin, not a position.
func TestRosterShrinkKeepsTheSelectedPlugin(t *testing.T) {
	m := step(newModel(nil, Options{}),
		tea.WindowSizeMsg{Width: 120, Height: 40},
		RosterMsg{Roster: rosterOf("a", "b", "c")},
	)
	m = selectSubjectByID(t, m, "b")

	// "a" leaves; "b" is still there, one row higher.
	m = step(m, RosterMsg{Roster: rosterOf("b", "c")})

	if got := m.subject().ID; got != "b" {
		t.Fatalf("cursor moved to %q; %q is still in the roster", got, "b")
	}
	if got := m.subjects[m.subjIdx].ID; got != "b" {
		t.Errorf("subjIdx %d points at %q, want b", m.subjIdx, got)
	}
}

// The selected plugin disappearing is a view change, not a bookkeeping fix:
// whatever that view was tailing has to be cancelled, or its goroutine keeps
// polling a dead plugin's log for the rest of the session.
func TestRosterDropOfSelectedPluginTearsDownItsView(t *testing.T) {
	m := step(newModel(nil, Options{}),
		tea.WindowSizeMsg{Width: 120, Height: 40},
		RosterMsg{Roster: rosterOf("a", "b", "c")},
	)
	m = selectSubjectByID(t, m, "b")
	m = step(m, key("2")) // Logs

	cancelled := 0
	old := m.scope
	old.cancel = func() { cancelled++ }
	m.logCh = &stream[logtail.Line]{}

	m = step(m, RosterMsg{Roster: rosterOf("a", "c")})

	if got := m.subject().ID; got != allID {
		t.Fatalf("subject = %q, want ALL after the selected plugin left", got)
	}
	if cancelled != 1 {
		t.Errorf("previous view cancelled %d times, want 1", cancelled)
	}
	if m.scope == old {
		t.Error("model kept the old scope; the new view has nothing to cancel")
	}
	if m.logCh != nil {
		t.Error("log handle survived the subject change; the tail re-arms forever")
	}
	if m.tabIdx != 0 {
		t.Errorf("tabIdx = %d, want 0 after falling back to ALL", m.tabIdx)
	}
}

// Growing the roster must leave the cursor alone too — the same read-order
// bug shows up as a silent jump when rows are inserted above the cursor.
func TestRosterGrowthKeepsTheSelectedPlugin(t *testing.T) {
	m := step(newModel(nil, Options{}),
		tea.WindowSizeMsg{Width: 120, Height: 40},
		RosterMsg{Roster: rosterOf("b", "c")},
	)
	m = selectSubjectByID(t, m, "c")

	m = step(m, RosterMsg{Roster: rosterOf("a", "b", "c")})

	if got := m.subject().ID; got != "c" {
		t.Errorf("cursor moved to %q, want c", got)
	}
}

// A roster that changes nothing must not restart the current view: doing so
// would re-tail the log every two seconds.
func TestUnchangedRosterDoesNotRetune(t *testing.T) {
	m := step(newModel(nil, Options{}),
		tea.WindowSizeMsg{Width: 120, Height: 40},
		RosterMsg{Roster: rosterOf("a", "b")},
	)
	m = selectSubjectByID(t, m, "b")
	m = step(m, key("2")) // Logs

	cancelled := 0
	m.scope.cancel = func() { cancelled++ }

	m = step(m, RosterMsg{Roster: rosterOf("a", "b")})

	if cancelled != 0 {
		t.Errorf("an unchanged roster cancelled %d views, want 0", cancelled)
	}
	if m.tabIdx != 1 {
		t.Errorf("tabIdx = %d, want the Logs tab kept", m.tabIdx)
	}
}
