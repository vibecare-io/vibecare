// Package theme holds every lipgloss style the TUI draws with, so that no
// other file picks a colour.
//
// The palette is the base ANSI 16 deliberately, for the same reason
// internal/cli/output uses it: those are the colours the user's own terminal
// theme remaps, so a red here is the red they already recognise as wrong,
// whatever profile or background they run. Truecolor hex would look right on
// one machine and unreadable on the next.
package theme

import (
	"github.com/charmbracelet/lipgloss"

	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// ANSI slots, named by role rather than by colour so the tables below read
// as intent. lipgloss strips these entirely when the output is not a
// terminal, which is what makes the render tests plain-text comparisons.
const (
	ansiRed     = lipgloss.Color("1")
	ansiGreen   = lipgloss.Color("2")
	ansiYellow  = lipgloss.Color("3")
	ansiBlue    = lipgloss.Color("4")
	ansiMagenta = lipgloss.Color("5")
	ansiCyan    = lipgloss.Color("6")
	// The bright half. Used only where a block of colour needs to stay
	// legible with dark text on top of it.
	ansiBrightMagenta = lipgloss.Color("13")
	ansiBlack         = lipgloss.Color("0")
)

// Theme is the whole drawing vocabulary. Every field is a value: styles are
// copied on use, never mutated, so one Theme is safe to share across panes.
type Theme struct {
	// Dark records which variant was built. Panes that need a one-off
	// contrast decision read it rather than guessing from a style.
	Dark bool

	Header    lipgloss.Style
	HeaderBad lipgloss.Style

	Sidebar    lipgloss.Style
	Item       lipgloss.Style
	ItemActive lipgloss.Style
	// Select is the selected sidebar row drawn as a solid block rather than
	// coloured text. A block is found by the eye without being read, which
	// is what a cursor in a list should be; coloured text has to be
	// compared against its neighbours before it resolves.
	Select     lipgloss.Style
	SelectBlur lipgloss.Style
	// Divider is the rule between the subject list and the pane. It gives
	// the two halves an edge, so the sidebar reads as a column rather than
	// as text that happens to stop.
	Divider lipgloss.Style

	Tab       lipgloss.Style
	TabActive lipgloss.Style

	Chip         lipgloss.Style
	ChipActive   lipgloss.Style
	ChipSelected lipgloss.Style

	Footer    lipgloss.Style
	Bar       lipgloss.Style
	Key       lipgloss.Style
	Desc      lipgloss.Style
	GroupName lipgloss.Style

	Popup lipgloss.Style

	Title      lipgloss.Style
	GroupTitle lipgloss.Style
	Dim        lipgloss.Style
	Good       lipgloss.Style
	Warn       lipgloss.Style
	Bad        lipgloss.Style
	// Stale marks values held from before core went away. They are shown
	// rather than blanked — a stale number answers more questions than an
	// empty pane does — so they need a look that says "old, not current".
	Stale lipgloss.Style
}

// New builds the palette. dark selects the grey used for de-emphasis; there
// is no attempt to detect the terminal background here, because the caller
// already knows what the user asked for and lipgloss's own detection needs a
// TTY the tests do not have.
func New(dark bool) *Theme {
	dim := lipgloss.Color("8") // bright black: legible on a dark ground
	if !dark {
		dim = lipgloss.Color("7") // white: the light-ground equivalent
	}

	t := &Theme{Dark: dark}

	t.Header = lipgloss.NewStyle().Bold(true)
	t.HeaderBad = lipgloss.NewStyle().Bold(true).Foreground(ansiRed)

	t.Sidebar = lipgloss.NewStyle().PaddingRight(1)
	t.Item = lipgloss.NewStyle()
	t.ItemActive = lipgloss.NewStyle().Bold(true).Foreground(ansiCyan)
	// Dark text on a bright ground: the one place the palette needs a
	// specific pairing rather than a single colour, because a block is only
	// legible if what sits on it contrasts with it.
	t.Select = lipgloss.NewStyle().Foreground(ansiBlack).Background(ansiBrightMagenta).Bold(true)
	// Blurred, the block stays — the user must not lose their place — but
	// drops to grey so it no longer claims the keyboard.
	t.SelectBlur = lipgloss.NewStyle().Foreground(ansiBlack).Background(dim)
	t.Divider = lipgloss.NewStyle().Foreground(dim)

	t.Tab = lipgloss.NewStyle().Foreground(dim).Padding(0, 1)
	t.TabActive = lipgloss.NewStyle().Bold(true).Underline(true).Padding(0, 1)

	t.Chip = lipgloss.NewStyle().Foreground(dim)
	t.ChipActive = lipgloss.NewStyle().Foreground(ansiBlue)
	// ChipSelected is the one filter currently in effect. A background
	// block rather than a colour so it is found rather than compared.
	t.ChipSelected = lipgloss.NewStyle().Foreground(lipgloss.Color("0")).Background(ansiBlue).Bold(true)

	t.Footer = lipgloss.NewStyle().Foreground(dim)
	// Bar is the action-log strip. It reads as chrome rather than content,
	// which is what keeps a permanent full-width line from competing with
	// the pane above it.
	t.Bar = lipgloss.NewStyle().Foreground(ansiCyan)
	t.Key = lipgloss.NewStyle().Bold(true).Foreground(ansiMagenta)
	t.Desc = lipgloss.NewStyle().Foreground(dim)
	t.GroupName = lipgloss.NewStyle().Bold(true).Foreground(ansiCyan)

	t.Popup = lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(ansiCyan).
		Padding(0, 1)

	t.Title = lipgloss.NewStyle().Bold(true)
	// GroupTitle heads a section of the transient. Dim rather than bold:
	// the headings are scaffolding for the eye, and the keys beside them
	// are what the reader is hunting for.
	t.GroupTitle = lipgloss.NewStyle().Foreground(ansiBlue)
	t.Dim = lipgloss.NewStyle().Foreground(dim)
	t.Good = lipgloss.NewStyle().Foreground(ansiGreen)
	t.Warn = lipgloss.NewStyle().Foreground(ansiYellow)
	t.Bad = lipgloss.NewStyle().Foreground(ansiRed)
	t.Stale = lipgloss.NewStyle().Foreground(dim).Italic(true)

	return t
}

// State returns the style for a plugin state. UNKNOWN is dim rather than red
// on purpose: it means "core is unreachable so this is the last thing we
// knew", which is a statement about the client, not about the plugin.
func (t *Theme) State(s vc.State) lipgloss.Style {
	switch s {
	case vc.StateUp:
		return t.Good
	case vc.StateDegraded, vc.StateStarting:
		return t.Warn
	case vc.StateDown, vc.StateFailed:
		return t.Bad
	}
	return t.Dim
}
