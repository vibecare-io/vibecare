package tui

import (
	"strings"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
)

// Help is the third surface rendered from the keymap tables, and it renders
// the same groups the transient does — deliberately. If `?` showed a
// hand-written summary it would be the copy that goes stale, so it shows the
// live tables and differs only in having the whole pane to do it in.
func renderHelp(subject string, c keymap.Ctx, k SubjectKind, f keymap.Focus, w, h int, th *theme.Theme) string {
	if w <= 0 || h <= 0 {
		return ""
	}

	head := th.Title.Render("keys — "+subject+" · "+string(c)) + "  " +
		th.Dim.Render("esc closes")
	body := renderGroups(keymap.All(c, k, f), w, th)

	return clamp(strings.Join([]string{head, "", body}, "\n"), w, h)
}
