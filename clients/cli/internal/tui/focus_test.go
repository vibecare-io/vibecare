package tui

import (
	"os"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// focusModel is a sized model with a roster, starting from a known focus and
// subject so each case below asserts one transition rather than a history.
func focusModel(t *testing.T) model {
	t.Helper()
	m := testModel(130, 40)
	if m.focus != FocusSidebar {
		t.Fatalf("focus starts at %v, want the sidebar — the subject list is where a\nuser lands and j/k must move it without any prior keypress", m.focus)
	}
	return m
}

// j/k drive the sidebar when it has focus. This is the whole point: the
// previous binding put subject movement on [ and ] and gave j/k to the pane,
// so a vim user's first two keystrokes did nothing visible.
func TestSidebarVimKeysMoveSubject(t *testing.T) {
	tests := []struct {
		key  string
		from int
		want int
	}{
		{"j", 0, 1},
		{"k", 1, 0},
		{"down", 0, 1},
		{"up", 1, 0},
		// Subject movement wraps, which is the behaviour the list already
		// had under [ and ]. j/k are an additional way to drive it, not a
		// different rule for driving it.
		{"k", 0, 3},
	}

	for _, tc := range tests {
		t.Run(tc.key, func(t *testing.T) {
			m := focusModel(t)
			m.subjIdx = tc.from
			m = step(m, key(tc.key))
			if m.subjIdx != tc.want {
				t.Errorf("%s from %d -> subjIdx %d, want %d", tc.key, tc.from, m.subjIdx, tc.want)
			}
			if m.focus != FocusSidebar {
				t.Errorf("%s moved focus off the sidebar", tc.key)
			}
		})
	}
}

// tab and l cross into the detail panel; that is what "focus goes to the
// right" means.
func TestTabAndLFocusDetail(t *testing.T) {
	for _, k := range []string{"tab", "l", "right"} {
		t.Run(k, func(t *testing.T) {
			m := step(focusModel(t), key(k))
			if m.focus != FocusDetail {
				t.Errorf("%q left focus on the sidebar", k)
			}
			// Crossing over must not also change the subject or the tab —
			// one keypress, one effect.
			if m.subjIdx != 0 || m.tabIdx != 0 {
				t.Errorf("%q changed selection: subjIdx=%d tabIdx=%d, want 0/0", k, m.subjIdx, m.tabIdx)
			}
		})
	}
}

// With the panel focused, h/l walk the tab strip — Overview, Logs, Alerts…
func TestDetailVimKeysMoveTabs(t *testing.T) {
	m := step(focusModel(t), key("tab"))
	tabs := keymap.Tabs(m.subject().Kind)
	if len(tabs) < 3 {
		t.Fatalf("need at least 3 tabs to test movement, got %d", len(tabs))
	}

	m = step(m, key("l"))
	if m.tabIdx != 1 {
		t.Fatalf("l -> tabIdx %d, want 1", m.tabIdx)
	}
	m = step(m, key("l"))
	if m.tabIdx != 2 {
		t.Fatalf("l l -> tabIdx %d, want 2", m.tabIdx)
	}
	m = step(m, key("h"))
	if m.tabIdx != 1 {
		t.Fatalf("h -> tabIdx %d, want 1", m.tabIdx)
	}
	// The arrows keep working: this adds vim keys, it does not take away
	// the keys someone already learned from the footer.
	m = step(m, key("right"))
	if m.tabIdx != 2 {
		t.Errorf("right -> tabIdx %d, want 2", m.tabIdx)
	}
	m = step(m, key("left"))
	if m.tabIdx != 1 {
		t.Errorf("left -> tabIdx %d, want 1", m.tabIdx)
	}
	if m.focus != FocusDetail {
		t.Error("tab movement dropped focus back to the sidebar")
	}
}

// The pane keeps j/k while the panel is focused, because that is where
// scrolling a log or walking a schedule list belongs.
func TestDetailVimKeysDoNotMoveSubject(t *testing.T) {
	m := step(focusModel(t), key("tab"))
	before := m.subjIdx

	m = step(m, key("j"), key("j"))
	if m.subjIdx != before {
		t.Errorf("j moved the subject (%d -> %d) while the panel had focus; it belongs to the pane", before, m.subjIdx)
	}
}

// esc is the way back to the subject list.
func TestEscReturnsFocusToSidebar(t *testing.T) {
	m := step(focusModel(t), key("tab"))
	if m.focus != FocusDetail {
		t.Fatal("setup failed: tab did not focus the detail panel")
	}

	m = step(m, key("esc"))
	if m.focus != FocusSidebar {
		t.Error("esc did not return focus to the subject list")
	}
	// It returns focus without discarding where the user was.
	if m.tabIdx != 0 {
		t.Errorf("esc reset the tab to %d; leaving the panel should not lose your place", m.tabIdx)
	}
}

// tab toggles rather than only going one way, so the key that got you there
// gets you back without reaching for another one.
func TestTabTogglesFocus(t *testing.T) {
	m := step(focusModel(t), key("tab"))
	if m.focus != FocusDetail {
		t.Fatal("first tab did not focus the panel")
	}
	m = step(m, key("tab"))
	if m.focus != FocusSidebar {
		t.Error("second tab did not return focus to the sidebar")
	}
}

// esc has three jobs and they must resolve in the right order: dismiss a
// modal first, and only fall through to focus once nothing is open. Popping
// focus out from under an open help screen would leave the user looking at
// help with no idea their selection moved.
func TestEscClosesModalsBeforeChangingFocus(t *testing.T) {
	m := step(focusModel(t), key("tab"), key("?"))
	if !m.help {
		t.Fatal("? did not open help")
	}
	m = step(m, key("esc"))
	if m.help {
		t.Error("esc did not close help")
	}
	if m.focus != FocusDetail {
		t.Error("esc closed help AND moved focus; one key, one effect")
	}

	m = step(m, key(" "))
	if !m.tr.open {
		t.Fatal("space did not open the transient")
	}
	m = step(m, key("esc"))
	if m.tr.open {
		t.Error("esc did not close the transient")
	}
	if m.focus != FocusDetail {
		t.Error("esc closed the transient AND moved focus")
	}
}

// [ and ] change subject from inside the panel, so a user comparing two
// plugins' logs does not have to leave the panel and come back.
func TestBracketsChangeSubjectFromDetail(t *testing.T) {
	m := step(focusModel(t), key("tab"))
	m = step(m, key("]"))

	if m.subjIdx != 1 {
		t.Errorf("] -> subjIdx %d, want 1", m.subjIdx)
	}
	if m.focus != FocusDetail {
		t.Error("] threw focus back to the sidebar")
	}
}

// The footer is the only place most users will learn these keys, so it has
// to describe the focus they are actually in.
func TestFooterFollowsFocus(t *testing.T) {
	m := focusModel(t)
	side := renderFooter(m.keyCtx(), m.focus, 200, m.theme)
	if !strings.Contains(side, "j") || !strings.Contains(side, "subject") {
		t.Errorf("sidebar footer does not advertise j/k for subjects:\n%s", side)
	}

	m = step(m, key("tab"))
	det := renderFooter(m.keyCtx(), m.focus, 200, m.theme)
	if !strings.Contains(det, "tab") {
		t.Errorf("detail footer does not advertise how to get back:\n%s", det)
	}
	if side == det {
		t.Error("the footer reads identically in both focuses; it is not focus-aware")
	}
}

// The sidebar must look focused when it is, or the user cannot tell which
// half their next keystroke will drive.
func TestSidebarShowsFocus(t *testing.T) {
	m := focusModel(t)
	focused := m.sidebarView(24, 10)
	blurred := step(m, key("tab")).sidebarView(24, 10)

	if focused == blurred {
		t.Error("the sidebar renders identically focused and blurred; focus is invisible")
	}
}

// Whatever the focus, the keys shown must be the keys that work.
func TestEveryFooterKeyResolvesInItsFocus(t *testing.T) {
	for _, f := range []keymap.Focus{keymap.FocusSidebar, keymap.FocusDetail} {
		for _, c := range []keymap.Ctx{keymap.CtxOverview, keymap.CtxLogs, keymap.CtxSchedules} {
			for _, b := range keymap.Footer(c, f) {
				for _, k := range b.Keys() {
					got, ok := keymap.Lookup(c, keymap.SubjectPlugin, f, k)
					if !ok {
						t.Errorf("focus=%v ctx=%s: footer shows %q but Lookup does not resolve it", f, c, k)
						continue
					}
					if got.Action != b.Action {
						t.Errorf("focus=%v ctx=%s key %q: footer says %q, Lookup says %q",
							f, c, k, b.Action, got.Action)
					}
				}
			}
		}
	}
}

// A roster arriving must not silently yank focus around under the user.
func TestRosterUpdateKeepsFocus(t *testing.T) {
	m := step(focusModel(t), key("tab"))
	m = step(m, RosterMsg{Roster: vc.Roster{Plugins: []vc.Plugin{
		{ID: "vibecheck", State: vc.StateUp},
		{ID: "todo", State: vc.StateUp},
	}}})

	if m.focus != FocusDetail {
		t.Error("a roster update moved focus out of the panel the user was reading")
	}
}

var _ = tea.KeyMsg{}

// Every action the keymap advertises must be handled somewhere. ActionPluginUI
// was bound to `u` in the transient from the start and never implemented, so
// pressing it silently did nothing — the failure mode a single source of
// truth for keys exists to prevent, showing up on the handler side instead.
//
// Asserted at the source level, in the same style as TestOnlyCmdsPerformsIO:
// with no session every command is a nil no-op, so there is no runtime
// difference between "handled" and "dropped on the floor" to observe.
func TestSubjectActionsAreHandled(t *testing.T) {
	src, err := os.ReadFile("app.go")
	if err != nil {
		t.Fatal(err)
	}
	handlers := string(src)

	// The verbs the transient offers for a subject. Each is a promise to the
	// user that pressing that key does something.
	for _, action := range []string{
		"ActionPluginUI",
		"ActionPluginRestart",
		"ActionRefresh",
	} {
		if !strings.Contains(handlers, "keymap."+action) {
			t.Errorf("%s is bound in the keymap but never handled in app.go; the key does nothing", action)
		}
	}
}

// And the binding itself still resolves, so the handler above is reachable.
func TestPluginUIIsBoundForPlugins(t *testing.T) {
	m := testModel(130, 40)
	for m.subject().Kind != SubjectPlugin {
		m = step(m, key("]"))
	}

	b, ok := keymap.Lookup(m.keyCtx(), SubjectPlugin, m.focus, "u")
	if !ok {
		t.Fatal("u is not bound for a plugin; the open-UI action is unreachable")
	}
	if b.Action != keymap.ActionPluginUI {
		t.Fatalf("u = %q, want %q", b.Action, keymap.ActionPluginUI)
	}
}
