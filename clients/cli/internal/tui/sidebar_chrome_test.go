package tui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
)

// The rule has to run the FULL height, past the last plugin and through an
// empty roster. One that stops at the last row makes the column look ragged,
// and on an empty roster it looks like a rendering failure.
func TestDividerRunsFullHeight(t *testing.T) {
	items := testModel(120, 40).sidebarItems()
	for _, tc := range []struct {
		name  string
		items []sidebarItem
	}{
		{"with plugins", items},
		{"empty roster", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			const w, h = 20, 12
			out := renderSidebar(tc.items, 0, FocusSidebar, w, h, theme.New(true), false)

			lines := strings.Split(out, "\n")
			if len(lines) != h {
				t.Fatalf("got %d lines, want %d", len(lines), h)
			}
			for i, l := range lines {
				if !strings.HasSuffix(l, dividerGlyph) {
					t.Errorf("line %d has no divider: %q", i, l)
				}
			}
		})
	}
}

// The divider comes out of the sidebar's own width, so the pane beside it
// starts on the same column whether or not the rule is drawn. If it did not,
// adding the rule would have silently shifted every pane one column left.
func TestDividerFitsTheSidebarBudget(t *testing.T) {
	items := testModel(120, 40).sidebarItems()
	for _, w := range []int{8, 14, 20, 28} {
		out := renderSidebar(items, 0, FocusSidebar, w, 6, theme.New(true), false)
		for i, l := range strings.Split(out, "\n") {
			if got := lipgloss.Width(l); got != w {
				t.Errorf("w=%d line %d is %d columns: %q", w, i, got, l)
			}
		}
	}
}

// A background only reads as a block if it covers the padding too. Styles are
// stripped in tests by default — which is what makes every other render
// assertion a plain-string comparison — so this one turns colour on
// deliberately to check the thing that is invisible without it.
func TestSelectedRowIsAFullWidthBlock(t *testing.T) {
	restore := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.ANSI256)
	t.Cleanup(func() { lipgloss.SetColorProfile(restore) })

	items := []sidebarItem{{Label: "ALL"}, {Label: "core"}}
	const w = 24
	full := renderSidebar(items, 0, FocusSidebar, w, 4, theme.New(true), false)
	sel := strings.Split(full, "\n")[0]

	if !strings.Contains(sel, "\x1b[") {
		t.Fatalf("selected row carries no styling at all: %q", sel)
	}
	// The reset must come at the END of the row's content, not straight
	// after the label — that is the difference between a bar and a
	// coloured word.
	body := sel[:strings.LastIndex(sel, dividerGlyph)]
	plain := stripANSI(body)
	if got := len(strings.TrimRight(plain, " ")); got >= len(plain) {
		t.Errorf("selected row is not padded, so the block cannot span: %q", plain)
	}
	if idx := strings.Index(body, "\x1b[0m"); idx != -1 && idx < strings.Index(body, "ALL") {
		t.Error("styling is reset before the label; the block is broken up")
	}
}

// Blurred, the block must still be there — losing your place when focus
// moves is worse than a slightly louder sidebar.
func TestSelectedRowKeepsItsBlockWhenBlurred(t *testing.T) {
	restore := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.ANSI256)
	t.Cleanup(func() { lipgloss.SetColorProfile(restore) })

	items := []sidebarItem{{Label: "ALL"}, {Label: "core"}}
	blurred := strings.Split(renderSidebar(items, 0, FocusDetail, 24, 4, theme.New(true), false), "\n")[0]
	focused := strings.Split(renderSidebar(items, 0, FocusSidebar, 24, 4, theme.New(true), false), "\n")[0]

	if !strings.Contains(blurred, "\x1b[") {
		t.Error("the blurred selection lost its block entirely")
	}
	if blurred == focused {
		t.Error("focused and blurred selections are identical; focus is invisible")
	}
}

func stripANSI(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); {
		if s[i] == 0x1b {
			for i < len(s) && s[i] != 'm' {
				i++
			}
			i++
			continue
		}
		b.WriteByte(s[i])
		i++
	}
	return b.String()
}
