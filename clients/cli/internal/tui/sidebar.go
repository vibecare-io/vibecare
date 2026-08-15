package tui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// The sidebar's job is to answer "is anything broken" before a word is read,
// so the bullet carries the state and the glyphs are chosen to differ in
// shape, not only in colour — a red-green colourblind user, a monochrome
// terminal and a piped screenshot all still work.
const (
	bulletUp       = "◆"
	bulletDegraded = "◇"
	bulletDown     = "○"
	cursor         = "▸"
	// cursorBlur marks the selected row while the panel has focus. Same
	// column, quieter glyph.
	cursorBlur = "·"

	// dividerGlyph rules the sidebar off from the pane. It runs the full
	// height, including past the last row, so the two halves read as
	// columns rather than as a list that happens to stop.
	dividerGlyph = "│"
	dividerCols  = 1
)

func bullet(s vc.State) string {
	switch s {
	case vc.StateUp:
		return bulletUp
	case vc.StateDegraded, vc.StateStarting:
		return bulletDegraded
	}
	return bulletDown
}

// sidebarItem is one selectable row: a label and the state its bullet shows.
type sidebarItem struct {
	Label string
	State vc.State
}

// sidebarItems derives the rows from the current roster.
//
// ALL summarises rather than repeats: it shows the worst state on the list,
// because that row is where a glance lands and "everything is fine" must
// never be the summary of a failed plugin. core has no state of its own —
// it is up exactly when the client can still reach it.
func (m model) sidebarItems() []sidebarItem {
	items := make([]sidebarItem, 0, len(m.subjects))
	for _, s := range m.subjects {
		switch s.Kind {
		case SubjectAll:
			items = append(items, sidebarItem{Label: "ALL", State: worstState(m.roster.Plugins)})
		case SubjectCore:
			st := vc.StateUp
			if m.stale {
				st = vc.StateDown
			}
			items = append(items, sidebarItem{Label: coreID, State: st})
		default:
			st := vc.StateUnknown
			if s.Plugin != nil {
				st = s.Plugin.State
			}
			if m.stale {
				// Core is gone, so every plugin row is a memory. Saying
				// UNKNOWN is honest; leaving them green is not.
				st = vc.StateUnknown
			}
			items = append(items, sidebarItem{Label: s.ID, State: st})
		}
	}
	return items
}

// worstState collapses the roster to the state worth reporting. An empty
// roster is degraded rather than up: no plugins at all is not "healthy", it
// is "nothing is running yet".
func worstState(plugins []vc.Plugin) vc.State {
	if len(plugins) == 0 {
		return vc.StateDegraded
	}
	worst := vc.StateUp
	for _, p := range plugins {
		switch p.State {
		case vc.StateDown, vc.StateFailed, vc.StateUnknown:
			return vc.StateDown
		case vc.StateDegraded, vc.StateStarting:
			worst = vc.StateDegraded
		}
	}
	return worst
}

func (m model) sidebarView(w, h int) string {
	return renderSidebar(m.sidebarItems(), m.subjIdx, m.focus, w, h, m.theme, m.collapsed())
}

// renderSidebar draws the subject list into exactly w×h cells so the detail
// pane beside it starts on the same column on every line.
// focus decides how loud the selected row is. With the panel focused the
// cursor stays visible but stops shouting: the user needs to remember which
// subject they are reading without being told twice that it is where their
// keystrokes are going, because it is not.
func renderSidebar(items []sidebarItem, sel int, focus keymap.Focus, w, h int, th *theme.Theme, collapsed bool) string {
	if w <= 0 || h <= 0 {
		return ""
	}

	// The divider lives inside the sidebar's own width budget, so the pane
	// beside it starts on the same column whether or not this is drawn.
	contentW := w - dividerCols
	if contentW < 1 {
		return clamp(strings.Repeat(dividerGlyph, 1), w, h)
	}
	rule := th.Divider.Render(dividerGlyph)

	lines := make([]string, 0, h)
	for i, it := range items {
		if len(lines) == h {
			break
		}
		lines = append(lines, renderSidebarRow(it, i == sel, focus, contentW, th, collapsed)+rule)
	}

	// Filler rows carry the rule too. A divider that stops at the last
	// plugin makes the column look ragged and, worse, makes an empty roster
	// look like a rendering failure.
	for len(lines) < h {
		lines = append(lines, strings.Repeat(" ", contentW)+rule)
	}
	return clamp(strings.Join(lines, "\n"), w, h)
}

// renderSidebarRow draws one row. The selected row is built as PLAIN text and
// styled once as a whole, because a background has to cover the padding to
// read as a block — styling the label alone leaves a coloured word with a
// ragged edge rather than a bar.
//
// That costs the selected row its state colour. The bullet keeps its shape,
// which is what carries the state for a colourblind reader anyway, and the
// pane beside it names the state in words.
func renderSidebarRow(it sidebarItem, selected bool, focus keymap.Focus, w int, th *theme.Theme, collapsed bool) string {
	mark := " "
	if selected {
		mark = cursor
		if focus != keymap.FocusSidebar {
			mark = cursorBlur
		}
	}

	if selected {
		row := mark + bullet(it.State)
		if !collapsed {
			row += " " + it.Label
		}
		style := th.Select
		if focus != keymap.FocusSidebar {
			style = th.SelectBlur
		}
		return style.Render(padPlain(row, w))
	}

	row := mark + th.State(it.State).Render(bullet(it.State))
	if !collapsed {
		row += " " + th.Item.Render(it.Label)
	}
	return pad(row, w)
}

// padPlain pads unstyled text to w columns. It is separate from pad because
// the string it is given must stay unstyled: the caller wraps the result in
// one style, and an escape sequence in the middle would end the background
// early and leave the block with a hole in it.
func padPlain(s string, w int) string {
	if gap := w - lipgloss.Width(s); gap > 0 {
		return s + strings.Repeat(" ", gap)
	}
	return clampLine(s, w)
}

// pad right-fills a styled line to w columns, measuring what is printed
// rather than what is stored, so escape sequences do not eat the padding.
func pad(s string, w int) string {
	if gap := w - lipgloss.Width(s); gap > 0 {
		return s + strings.Repeat(" ", gap)
	}
	return s
}
