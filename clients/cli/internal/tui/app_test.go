package tui

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// key builds the KeyMsg bubbletea would deliver for a key name from the
// keymap tables. Tests name keys the way keymap does, never the way tea
// spells them internally.
func key(name string) tea.KeyMsg {
	switch name {
	case "left":
		return tea.KeyMsg{Type: tea.KeyLeft}
	case "right":
		return tea.KeyMsg{Type: tea.KeyRight}
	case "up":
		return tea.KeyMsg{Type: tea.KeyUp}
	case "down":
		return tea.KeyMsg{Type: tea.KeyDown}
	case "esc":
		return tea.KeyMsg{Type: tea.KeyEsc}
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case " ":
		return tea.KeyMsg{Type: tea.KeySpace, Runes: []rune(" ")}
	}
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(name)}
}

func testRoster() vc.Roster {
	return vc.Roster{
		BaseURL: "http://127.0.0.1:51234",
		Plugins: []vc.Plugin{
			{ID: "vibecheck", Name: "VibeCheck", State: vc.StateUp},
			{ID: "todo", Name: "Todo", State: vc.StateFailed},
		},
	}
}

// step drives the model exactly as the runtime does, discarding commands the
// tests do not assert on.
func step(m model, msgs ...tea.Msg) model {
	for _, msg := range msgs {
		next, _ := m.Update(msg)
		m = next.(model)
	}
	return m
}

// testModel is a model with no session at all: every command is a no-op, so
// the whole suite runs with no backend, no database and no plugins.
func testModel(w, h int) model {
	return step(newModel(nil, Options{}),
		tea.WindowSizeMsg{Width: w, Height: h},
		RosterMsg{Roster: testRoster()},
	)
}

func TestSubjectsFromRoster(t *testing.T) {
	m := testModel(120, 40)

	want := []string{"", "core", "vibecheck", "todo"}
	if len(m.subjects) != len(want) {
		t.Fatalf("got %d subjects, want %d: %+v", len(m.subjects), len(want), m.subjects)
	}
	for i, id := range want {
		if m.subjects[i].ID != id {
			t.Errorf("subject %d = %q, want %q", i, m.subjects[i].ID, id)
		}
	}
	if m.subjects[0].Kind != SubjectAll || m.subjects[1].Kind != SubjectCore {
		t.Errorf("first two subjects must be ALL and core, got %v/%v", m.subjects[0].Kind, m.subjects[1].Kind)
	}
	if m.subjects[2].Plugin == nil || m.subjects[2].Plugin.Name != "VibeCheck" {
		t.Errorf("plugin subject lost its plugin: %+v", m.subjects[2])
	}
}

func TestUpdateTransitions(t *testing.T) {
	tests := []struct {
		name  string
		msgs  []tea.Msg
		check func(t *testing.T, m model)
	}{
		{
			name: "resize is recorded",
			msgs: []tea.Msg{tea.WindowSizeMsg{Width: 100, Height: 30}},
			check: func(t *testing.T, m model) {
				if m.width != 100 || m.height != 30 {
					t.Errorf("size = %dx%d, want 100x30", m.width, m.height)
				}
			},
		},
		{
			name: "narrow window collapses the sidebar",
			msgs: []tea.Msg{tea.WindowSizeMsg{Width: 80, Height: 24}},
			check: func(t *testing.T, m model) {
				if !m.collapsed() {
					t.Error("sidebar should collapse below 90 columns")
				}
			},
		},
		{
			name: "next subject",
			msgs: []tea.Msg{key("]")},
			check: func(t *testing.T, m model) {
				if got := m.subject().ID; got != "core" {
					t.Errorf("subject = %q, want core", got)
				}
			},
		},
		{
			name: "prev subject wraps to the last plugin",
			msgs: []tea.Msg{key("[")},
			check: func(t *testing.T, m model) {
				if got := m.subject().ID; got != "todo" {
					t.Errorf("subject = %q, want todo", got)
				}
			},
		},
		{
			name: "next tab moves the key context",
			// tab enters the panel first: from the sidebar, → crosses over
			// rather than walking the strip.
			msgs: []tea.Msg{key("tab"), key("right")},
			check: func(t *testing.T, m model) {
				if m.tabIdx != 1 {
					t.Fatalf("tabIdx = %d, want 1", m.tabIdx)
				}
				// Asserted against the strip rather than a hard-coded name:
				// this test is about the key CHANGING the context, and
				// pinning it to one tab makes adding a tab look like a
				// regression.
				want := keymap.Tabs(m.subject().Kind)[1].Ctx
				if got := m.keyCtx(); got != want {
					t.Errorf("ctx = %q, want %q", got, want)
				}
			},
		},
		{
			name: "tab wraps",
			msgs: []tea.Msg{key("tab"), key("left")},
			check: func(t *testing.T, m model) {
				if m.tabIdx != len(keymap.Tabs(SubjectAll))-1 {
					t.Errorf("tabIdx = %d, want last", m.tabIdx)
				}
			},
		},
		{
			name: "digit jumps to a tab",
			msgs: []tea.Msg{key("3")},
			check: func(t *testing.T, m model) {
				if m.tabIdx != 2 {
					t.Errorf("tabIdx = %d, want 2", m.tabIdx)
				}
			},
		},
		{
			name: "changing subject resets the tab",
			msgs: []tea.Msg{key("3"), key("]")},
			check: func(t *testing.T, m model) {
				if m.tabIdx != 0 {
					t.Errorf("tabIdx = %d, want 0 after subject change", m.tabIdx)
				}
			},
		},
		{
			name: "tabs follow the subject kind",
			msgs: []tea.Msg{key("]"), key("]")},
			check: func(t *testing.T, m model) {
				if m.subject().Kind != SubjectPlugin {
					t.Fatalf("kind = %v, want plugin", m.subject().Kind)
				}
				if got := m.keyCtx(); got != keymap.CtxOverview {
					t.Errorf("ctx = %q, want overview", got)
				}
				if got := m.tabs()[2].Name; got != "Events" {
					t.Errorf("third plugin tab = %q, want Events", got)
				}
			},
		},
		{
			name: "an error marks the header stale",
			msgs: []tea.Msg{ErrMsg{Err: vc.Unreachable("127.0.0.1:50051", errors.New("connection refused"))}},
			check: func(t *testing.T, m model) {
				if !m.stale {
					t.Fatal("ErrMsg should mark the view stale")
				}
				if !strings.Contains(m.View(), "unreachable") {
					t.Errorf("header does not report the failure:\n%s", m.View())
				}
			},
		},
		{
			// This case previously asserted the opposite, on the reasonable-
			// sounding belief that a roster can only have come from core.
			// It cannot: vc replays its last roster to every new subscriber,
			// so a reconnect attempt receives one whether or not core
			// answered. Acting on it cleared the banner and reset the retry
			// chain roughly every two seconds while core was down.
			name: "a replayed roster does not clear stale",
			msgs: []tea.Msg{
				ErrMsg{Err: vc.Unreachable("127.0.0.1:50051", errors.New("boom"))},
				RosterMsg{Roster: testRoster()},
			},
			check: func(t *testing.T, m model) {
				if !m.stale {
					t.Error("a roster is not proof of reachability; only Status is")
				}
				if len(m.roster.Plugins) == 0 {
					t.Error("the roster payload should still be taken")
				}
			},
		},
		{
			name: "status also clears stale",
			msgs: []tea.Msg{
				ErrMsg{Err: vc.Unreachable("127.0.0.1:50051", errors.New("boom"))},
				StatusMsg{Status: vc.Status{Reachable: true, Version: "1.2.3"}},
			},
			check: func(t *testing.T, m model) {
				if m.stale {
					t.Error("reachable status should clear stale")
				}
				if !strings.Contains(m.View(), "1.2.3") {
					t.Error("header should show the version core reported")
				}
			},
		},
		{
			name: "zoom hides the sidebar",
			msgs: []tea.Msg{key("z")},
			check: func(t *testing.T, m model) {
				if !m.zoom {
					t.Fatal("z should zoom")
				}
				if m.sidebarWidth() != 0 {
					t.Errorf("sidebar width = %d, want 0 when zoomed", m.sidebarWidth())
				}
			},
		},
		{
			name: "space opens the transient",
			msgs: []tea.Msg{key(" ")},
			check: func(t *testing.T, m model) {
				if !m.tr.open {
					t.Fatal("space should open the transient")
				}
				// "actions" is the popup's own title. It no longer carries a
				// "Global" group: movement and chrome live in the footer,
				// and including them made the popup taller than the
				// terminal. See keymap.For vs keymap.All.
				if !strings.Contains(m.View(), "actions") {
					t.Errorf("transient is not on screen:\n%s", m.View())
				}
			},
		},
		{
			name: "esc dismisses the transient",
			msgs: []tea.Msg{key(" "), key("esc")},
			check: func(t *testing.T, m model) {
				if m.tr.open {
					t.Error("esc should dismiss the transient")
				}
			},
		},
		{
			name: "? toggles help",
			msgs: []tea.Msg{key("?")},
			check: func(t *testing.T, m model) {
				if !m.help {
					t.Fatal("? should open help")
				}
				if !strings.Contains(m.View(), "next subject") {
					t.Errorf("help does not render the bindings:\n%s", m.View())
				}
			},
		},
		{
			name: "esc closes help",
			msgs: []tea.Msg{key("?"), key("esc")},
			check: func(t *testing.T, m model) {
				if m.help {
					t.Error("esc should close help")
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tt.check(t, step(testModel(120, 40), tt.msgs...))
		})
	}
}

func TestQuitReturnsQuitCmd(t *testing.T) {
	m := testModel(120, 40)
	next, cmd := m.Update(key("q"))
	_ = next
	if cmd == nil {
		t.Fatal("q produced no command")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatalf("q produced %T, want tea.QuitMsg", cmd())
	}
}

// A session left open for an hour must not accumulate goroutines: the model
// owns the cancel for whatever the current view started, and every switch
// must run it.
func TestViewChangeCancelsPreviousStreams(t *testing.T) {
	tests := []struct {
		name string
		msgs []tea.Msg
	}{
		{"subject change", []tea.Msg{key("]")}},
		// Entering the panel is not itself a view change — it moves focus,
		// not the view — so the scope must survive it and be cancelled by
		// the tab move that follows.
		{"tab change", []tea.Msg{key("tab"), key("right")}},
		{"tab jump", []tea.Msg{key("4")}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := testModel(120, 40)
			cancelled := 0
			old := m.scope
			old.cancel = func() { cancelled++ }

			m = step(m, tt.msgs...)

			if cancelled != 1 {
				t.Errorf("previous view cancelled %d times, want 1", cancelled)
			}
			if m.scope == old {
				t.Error("model kept the old scope; the new view has nothing to cancel")
			}
		})
	}
}

func TestSameTabDoesNotRestartStreams(t *testing.T) {
	m := testModel(120, 40)
	cancelled := 0
	m.scope.cancel = func() { cancelled++ }

	m = step(m, key("1")) // already on tab 0

	if cancelled != 0 {
		t.Errorf("re-selecting the current tab cancelled %d streams, want 0", cancelled)
	}
}

func TestViewSurvivesAnySize(t *testing.T) {
	sizes := [][2]int{{0, 0}, {1, 1}, {20, 4}, {89, 20}, {120, 40}, {300, 90}}
	for _, s := range sizes {
		m := testModel(s[0], s[1])
		m = step(m, key(" "))
		if got := m.View(); got == "" && s[0] > 0 {
			t.Errorf("%dx%d rendered nothing", s[0], s[1])
		}
	}
}

func TestViewRendersChrome(t *testing.T) {
	v := testModel(120, 40).View()
	for _, want := range []string{"ALL", "core", "vibecheck", "Overview", "Logs", "actions", "help"} {
		if !strings.Contains(v, want) {
			t.Errorf("view is missing %q:\n%s", want, v)
		}
	}
}

func TestFooterFollowsTheFocusedPane(t *testing.T) {
	m := step(testModel(120, 40), key("2")) // Logs
	v := m.View()
	if !strings.Contains(v, "follow") {
		t.Errorf("logs footer should offer follow:\n%s", v)
	}
}

func TestRegisteredPaneWins(t *testing.T) {
	restore, had := registry[paneKey{SubjectPlugin, keymap.CtxStats}]
	t.Cleanup(func() {
		if had {
			registry[paneKey{SubjectPlugin, keymap.CtxStats}] = restore
			return
		}
		delete(registry, paneKey{SubjectPlugin, keymap.CtxStats})
	})

	Register(SubjectPlugin, keymap.CtxStats, func(PaneCtx) Pane {
		return placeholderPane{ctx: keymap.CtxStats, title: "registered"}
	})

	p := paneFor(SubjectPlugin, keymap.CtxStats, PaneCtx{})
	if p.Title() != "registered" {
		t.Errorf("paneFor returned %q, want the registered pane", p.Title())
	}
}

func TestUnregisteredPaneIsAPlaceholder(t *testing.T) {
	p := paneFor(SubjectAll, keymap.CtxOverview, PaneCtx{})
	if p.KeyContext() != keymap.CtxOverview {
		t.Errorf("placeholder reports ctx %q, want overview", p.KeyContext())
	}
	if p.View(40, 5) == "" {
		t.Error("placeholder rendered nothing")
	}
}

// The layering rule from §4.3, checked mechanically: everything except
// cmds.go is a pure Update(msg) → (model, cmd), which is why this package is
// testable without a terminal or a backend.
func TestOnlyCmdsPerformsIO(t *testing.T) {
	// Built at runtime so this test does not match itself.
	forbidden := []string{"vc." + "Session", "logtail." + "Tail", "logtail." + "Merge"}

	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		if f == "cmds.go" || strings.HasSuffix(f, "_test.go") {
			continue
		}
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for _, bad := range forbidden {
			if strings.Contains(string(src), bad) {
				t.Errorf("%s uses %s; all I/O belongs in cmds.go", f, bad)
			}
		}
	}
}
