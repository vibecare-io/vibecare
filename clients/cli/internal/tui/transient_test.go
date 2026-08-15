package tui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
)

// The popup is rendered from the tables, never from a hand-written list, so
// every binding the tables declare has to appear.
func TestTransientRendersEveryBinding(t *testing.T) {
	groups := keymap.For(keymap.CtxLogs, SubjectPlugin, FocusDetail)
	// Tall enough to hold the whole list. The popup is a vertical list of
	// grouped rows, so its height scales with the number of bindings — and
	// clipping is a legitimate behaviour on a short terminal, which
	// TestTransientFitsItsBox covers. Asserting completeness needs a box
	// that can actually fit it.
	out := renderTransient("vibecheck", groups, 120, 60, theme.New(true))

	for _, g := range groups {
		if !strings.Contains(out, g.Title) {
			t.Errorf("group %q missing:\n%s", g.Title, out)
		}
		for _, b := range g.Bindings {
			if !strings.Contains(out, b.Key) {
				t.Errorf("key %q missing:\n%s", b.Key, out)
			}
			if !strings.Contains(out, b.Desc) {
				t.Errorf("desc %q missing:\n%s", b.Desc, out)
			}
		}
	}
	if !strings.Contains(out, "esc") {
		t.Error("the popup must say how to dismiss itself")
	}
	if !strings.Contains(out, "vibecheck") {
		t.Error("the popup must name the subject it acts on")
	}
}

// A popup wider than the terminal is worse than no popup.
func TestTransientFitsItsBox(t *testing.T) {
	groups := keymap.For(keymap.CtxSchedules, SubjectCore, FocusDetail)
	for _, size := range [][2]int{{40, 12}, {60, 20}, {120, 40}, {200, 60}} {
		w, h := size[0], size[1]
		out := renderTransient("core", groups, w, h, theme.New(true))
		if got := lipgloss.Width(out); got > w {
			t.Errorf("%dx%d: popup is %d columns wide", w, h, got)
		}
		if got := lipgloss.Height(out); got > h {
			t.Errorf("%dx%d: popup is %d lines tall", w, h, got)
		}
	}
}

func TestTransientDispatchesAndDismisses(t *testing.T) {
	tests := []struct {
		name string
		key  string
		want bool // should the model have acted on it
	}{
		{"bound pane key", "f", true},
		{"bound root key", "z", true},
		{"unbound key", "Q", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := step(testModel(120, 40), key("2"), key(" ")) // Logs tab, popup up
			if !m.tr.open {
				t.Fatal("setup: transient did not open")
			}
			zoomBefore := m.zoom

			m = step(m, key(tt.key))

			if m.tr.open {
				t.Error("any key should dismiss the transient")
			}
			if tt.key == "z" && m.zoom == zoomBefore {
				t.Error("a bound key should also run its action")
			}
			if !tt.want && m.zoom != zoomBefore {
				t.Error("an unbound key must only dismiss")
			}
		})
	}
}

// The popup's contents are a function of the focused pane and the selected
// subject — that is the whole reason it is worth having.
func TestTransientFollowsSubjectAndTab(t *testing.T) {
	m := step(testModel(120, 40), key("]"), key("]"), key(" ")) // a plugin
	out := m.View()
	if !strings.Contains(out, "restart") {
		t.Errorf("a plugin's transient must offer restart:\n%s", out)
	}

	m = step(testModel(120, 40), key(" ")) // ALL
	if strings.Contains(m.View(), "restart") {
		t.Error("ALL has nothing to restart")
	}
}

// The popup's whole point is answering "what will this do", so a binding
// that has a description must show it.
func TestTransientShowsDescriptions(t *testing.T) {
	groups := keymap.For(keymap.CtxLogs, SubjectPlugin, FocusDetail)
	out := renderTransient("vibecheck", groups, 120, 60, theme.New(true))

	for _, g := range groups {
		for _, b := range g.Bindings {
			if b.Help == "" {
				continue
			}
			if !strings.Contains(out, b.Help) {
				t.Errorf("help %q for key %q is missing:\n%s", b.Help, b.Key, out)
			}
		}
	}
}

// Every subject verb carries an explanation. These are the actions that
// change the system, and "d  data dir" alone does not say whether it opens a
// folder or deletes one.
func TestSubjectBindingsAllExplainThemselves(t *testing.T) {
	for _, k := range []SubjectKind{SubjectAll, SubjectCore, SubjectPlugin} {
		for _, g := range keymap.For(keymap.CtxOverview, k, FocusDetail) {
			if g.Title == "Move" || g.Title == "View" {
				continue // movement is self-evident; tab names are the label
			}
			for _, b := range g.Bindings {
				if b.Help == "" {
					t.Errorf("%s/%s: key %q (%s) has no description", k, g.Title, b.Key, b.Desc)
				}
			}
		}
	}
}

// One vertical list, not a grid: the key column has to be scannable straight
// down, which means one binding per line.
func TestTransientIsOneBindingPerLine(t *testing.T) {
	groups := keymap.For(keymap.CtxLogs, SubjectPlugin, FocusDetail)
	out := renderTransient("vibecheck", groups, 120, 60, theme.New(true))

	var bindings int
	for _, g := range groups {
		bindings += len(g.Bindings)
	}
	// Title, blank, group headings, rows, blank separators, footer, border.
	if lines := strings.Count(out, "\n") + 1; lines < bindings {
		t.Errorf("popup is %d lines for %d bindings; they are not one per line:\n%s",
			lines, bindings, out)
	}
}
