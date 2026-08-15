package tui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
)

// Tabs live inside the detail pane because they are facets of the selected
// subject, not top-level destinations: which tabs exist at all depends on
// what the sidebar has selected, and putting them anywhere else would imply
// otherwise.
func renderTabs(tabs []keymap.Tab, active int, subject string, w int, th *theme.Theme) string {
	if w <= 0 {
		return ""
	}

	parts := make([]string, 0, len(tabs))
	for i, t := range tabs {
		style := th.Tab
		if i == active {
			style = th.TabActive
		}
		parts = append(parts, style.Render(t.Name))
	}
	strip := strings.Join(parts, th.Dim.Render("│"))

	// The subject name rides at the right end, so a screenshot of the
	// detail pane alone still says what it is showing.
	label := th.Title.Render(subject)
	if gap := w - lipgloss.Width(strip) - lipgloss.Width(label); gap > 1 {
		return strip + strings.Repeat(" ", gap) + label
	}
	return clamp(strip, w, 1)
}

// renderChips draws the active pane's controls under the tab strip. It
// always occupies its line, even with no chips: a row that appears and
// disappears would shift the pane content under the cursor.
func renderChips(chips []Chip, w int, th *theme.Theme) string {
	if w <= 0 {
		return ""
	}
	if len(chips) == 0 {
		return strings.Repeat(" ", w)
	}

	var toggles, filters []Chip
	for _, c := range chips {
		if c.Filter {
			filters = append(filters, c)
		} else {
			toggles = append(toggles, c)
		}
	}

	lines := []string{}
	if len(toggles) > 0 {
		lines = append(lines, chipLine(toggles, w, th))
	}
	if len(filters) > 0 {
		lines = append(lines, chipLine(filters, w, th))
	}
	// The row is a fixed two lines whichever way it is filled, so the pane
	// below it does not jump up and down as a pane's controls change.
	for len(lines) < chipLines {
		lines = append(lines, strings.Repeat(" ", w))
	}
	return strings.Join(lines[:chipLines], "\n")
}

func chipLine(chips []Chip, w int, th *theme.Theme) string {
	parts := make([]string, 0, len(chips))
	for _, c := range chips {
		text := c.Label
		if c.Value != "" {
			text += ":" + c.Value
		}
		style := th.Chip
		if c.Active {
			style = th.ChipActive
			if c.Filter {
				// The selected filter gets a solid block rather than a
				// colour: with several filters side by side, colour alone
				// makes the eye compare shades instead of finding the one.
				style = th.ChipSelected
			} else if c.Value == "" {
				// A valueless toggle has nothing to show its state with;
				// the dot is what says it is on.
				text += ":●"
			}
		}
		parts = append(parts, style.Render(" "+text+" "))
	}
	return clampLine(pad(strings.Join(parts, " "), w), w)
}
