package tui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
)

// transient is the which-key popup. It holds no bindings of its own: it is
// opened, and its contents are read from keymap at render time for whatever
// pane and subject are current. That is why it can never advertise a key
// the footer disagrees with.
type transient struct{ open bool }

// The popup is a single vertical list of titled groups rather than a grid of
// columns. Both fit more on screen than the eye can use, but a column layout
// makes the reader choose a scan direction before they can start reading,
// and it forces the description out — there is no room for a third column
// when four groups share the width. One column down the page keeps
// key / verb / what-it-does on the same line, which is the shape of the
// question a user actually has: "what can I do here, and what will it do".
const (
	// keyCol and descCol are the fixed columns the third one flows after.
	// Fixed rather than measured so the popup does not reflow into a
	// different shape when the subject changes under it.
	keyCol      = 9
	descCol     = 14
	rowIndent   = "  "
	dismissHint = "key run    esc cancel"
	popupTitle  = " — actions"
	titleMark   = "› "
)

// renderTransient draws the popup for one subject, never wider or taller
// than the box it was given.
func renderTransient(subject string, groups []keymap.Group, w, h int, th *theme.Theme) string {
	// Border eats two columns and two rows, the padding another two columns.
	innerW, innerH := w-4, h-2
	if innerW < 1 || innerH < 1 {
		return ""
	}

	head := th.Title.Render(titleMark + subject + popupTitle)
	foot := th.Dim.Render(dismissHint)

	// The title and the way out are never what gets dropped when the
	// terminal is small; the bindings are, because the popup is one keypress
	// from being reopened at a usable size.
	body := renderGroups(groups, innerW, th)
	if bodyH := innerH - 3; bodyH > 0 {
		body = clamp(body, innerW, bodyH)
	} else {
		body = ""
	}

	content := clamp(strings.Join([]string{head, "", body, foot}, "\n"), innerW, innerH)
	return th.Popup.Render(content)
}

// renderGroups lays titled groups out as one vertical list: a dim heading,
// then a row per binding, then a blank line before the next heading.
func renderGroups(groups []keymap.Group, w int, th *theme.Theme) string {
	if w <= 0 || len(groups) == 0 {
		return ""
	}

	var lines []string
	for _, g := range groups {
		if len(g.Bindings) == 0 {
			continue
		}
		if len(lines) > 0 {
			lines = append(lines, "")
		}
		lines = append(lines, th.GroupTitle.Render(g.Title))
		for _, b := range g.Bindings {
			lines = append(lines, renderBindingRow(b, w, th))
		}
	}
	return strings.Join(lines, "\n")
}

// renderBindingRow is one line of the popup: key, verb, and what it does.
//
// The columns are padded on the PRINTED width rather than the string length,
// because every cell is styled and the escape sequences would otherwise be
// counted as characters and eat the alignment.
func renderBindingRow(b keymap.Binding, w int, th *theme.Theme) string {
	key := padTo(th.Key.Render(b.Key), keyCol)
	desc := padTo(th.Item.Render(b.Desc), descCol)

	row := rowIndent + key + desc
	if b.Help != "" {
		// The help column takes what is left. Clamped rather than wrapped:
		// a popup row that grows to two lines breaks the scan down the key
		// column, which is the one thing this layout is for.
		if room := w - lipgloss.Width(row); room > 4 {
			row += th.Dim.Render(clampLine(b.Help, room))
		}
	}
	return clampLine(row, w)
}

// padTo right-pads a styled cell to n printed columns, leaving at least one
// space so two cells never run together.
func padTo(s string, n int) string {
	if gap := n - lipgloss.Width(s); gap > 0 {
		return s + strings.Repeat(" ", gap)
	}
	return s + " "
}

// clampLine truncates one styled line to w printed columns. It exists
// alongside clamp (which is width AND height) because every cell here is
// already a single line and the height dimension would only obscure that.
func clampLine(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if lipgloss.Width(s) <= w {
		return s
	}
	return clamp(s, w, 1)
}
