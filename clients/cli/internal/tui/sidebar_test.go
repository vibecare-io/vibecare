package tui

import (
	"strings"
	"testing"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// The bullet is the whole point of the sidebar: it must answer "is anything
// broken" without reading a word.
func TestBulletPerState(t *testing.T) {
	tests := []struct {
		state vc.State
		want  string
	}{
		{vc.StateUp, bulletUp},
		{vc.StateDegraded, bulletDegraded},
		{vc.StateStarting, bulletDegraded},
		{vc.StateDown, bulletDown},
		{vc.StateFailed, bulletDown},
		{vc.StateUnknown, bulletDown},
		{vc.State("nonsense"), bulletDown},
	}
	for _, tt := range tests {
		if got := bullet(tt.state); got != tt.want {
			t.Errorf("bullet(%s) = %q, want %q", tt.state, got, tt.want)
		}
	}
}

func TestSidebarRendersEverySubject(t *testing.T) {
	m := testModel(120, 40)
	out := m.sidebarView(20, 10)

	for _, want := range []string{"ALL", "core", "vibecheck", "todo"} {
		if !strings.Contains(out, want) {
			t.Errorf("sidebar is missing %q:\n%s", want, out)
		}
	}
	for _, line := range strings.Split(out, "\n") {
		switch {
		case strings.Contains(line, "vibecheck"):
			if !strings.Contains(line, bulletUp) {
				t.Errorf("an UP plugin should carry %q: %q", bulletUp, line)
			}
		case strings.Contains(line, "todo"):
			if !strings.Contains(line, bulletDown) {
				t.Errorf("a FAILED plugin should carry %q: %q", bulletDown, line)
			}
		}
	}
}

// ALL summarises: one failed plugin means the ALL row cannot look healthy,
// because that row is what a glance lands on first.
func TestAllRowShowsTheWorstState(t *testing.T) {
	tests := []struct {
		name    string
		plugins []vc.Plugin
		want    string
	}{
		{"everything up", []vc.Plugin{{ID: "a", State: vc.StateUp}}, bulletUp},
		{"one degraded", []vc.Plugin{{ID: "a", State: vc.StateUp}, {ID: "b", State: vc.StateDegraded}}, bulletDegraded},
		{"one failed", []vc.Plugin{{ID: "a", State: vc.StateUp}, {ID: "b", State: vc.StateFailed}}, bulletDown},
		{"no plugins at all", nil, bulletDegraded},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := step(newModel(nil, Options{}), RosterMsg{Roster: vc.Roster{Plugins: tt.plugins}})
			items := m.sidebarItems()
			if got := bullet(items[0].State); got != tt.want {
				t.Errorf("ALL bullet = %q, want %q", got, tt.want)
			}
		})
	}
}

// core has no plugin state of its own; it is up unless the client cannot
// reach it, in which case it must not still show green.
func TestCoreRowFollowsReachability(t *testing.T) {
	m := testModel(120, 40)
	if got := bullet(m.sidebarItems()[1].State); got != bulletUp {
		t.Errorf("core bullet = %q, want %q while reachable", got, bulletUp)
	}

	m = step(m, ErrMsg{Err: vc.Unreachable("127.0.0.1:50051", nil)})
	if got := bullet(m.sidebarItems()[1].State); got != bulletDown {
		t.Errorf("core bullet = %q, want %q once unreachable", got, bulletDown)
	}
}

func TestSidebarMarksTheSelection(t *testing.T) {
	m := step(testModel(120, 40), key("]"))
	out := m.sidebarView(20, 10)
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "core") && !strings.Contains(line, cursor) {
			t.Errorf("selected row is unmarked: %q", line)
		}
		if strings.Contains(line, "ALL") && strings.Contains(line, cursor) {
			t.Errorf("unselected row is marked: %q", line)
		}
	}
}

// Collapsed, the sidebar keeps the one thing it exists for.
func TestCollapsedSidebarKeepsBullets(t *testing.T) {
	out := renderSidebar(testModel(80, 24).sidebarItems(), 0, FocusSidebar, 3, 10, theme.New(true), true)
	if strings.Contains(out, "vibecheck") {
		t.Errorf("collapsed sidebar should not render names:\n%s", out)
	}
	if !strings.Contains(out, bulletDown) {
		t.Errorf("collapsed sidebar lost the failed bullet:\n%s", out)
	}
}

func TestSidebarClampsToItsBox(t *testing.T) {
	items := testModel(120, 40).sidebarItems()
	for _, h := range []int{0, 1, 2, 3, 10} {
		out := renderSidebar(items, 0, FocusSidebar, 18, h, theme.New(true), false)
		if out == "" {
			continue
		}
		if lines := strings.Count(out, "\n") + 1; lines > h && h > 0 {
			t.Errorf("height %d rendered %d lines", h, lines)
		}
	}
}
