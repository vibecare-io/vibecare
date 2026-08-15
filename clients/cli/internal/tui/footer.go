package tui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
)

// footerSep separates two hints. Two spaces rather than a glyph: the footer
// is the one part of the screen the eye should slide over.
const footerSep = "  "

// renderFooter draws the two-line hint strip for the focused pane. It is
// exactly footerLines tall whatever it contains, because a footer that grows
// would move the pane content under the cursor.
//
// The pane's own keys come first and the always-there keys after, so the
// line the eye starts on is the one that changed.
func renderFooter(c keymap.Ctx, f keymap.Focus, w int, th *theme.Theme) string {
	if w <= 0 {
		return ""
	}

	lines := make([]string, 0, footerLines)
	var cur string
	for _, b := range keymap.Footer(c, f) {
		hint := th.Key.Render(b.Key) + th.Footer.Render(":"+b.Desc)
		next := hint
		if cur != "" {
			next = cur + footerSep + hint
		}
		if lipgloss.Width(next) <= w {
			cur = next
			continue
		}
		lines = append(lines, cur)
		cur = hint
		if len(lines) == footerLines {
			// Everything past two lines lives in the transient, which is
			// one keypress away and has room for all of it.
			cur = ""
			break
		}
	}
	if cur != "" && len(lines) < footerLines {
		lines = append(lines, cur)
	}
	for len(lines) < footerLines {
		lines = append(lines, "")
	}
	return clamp(strings.Join(lines, "\n"), w, footerLines)
}
