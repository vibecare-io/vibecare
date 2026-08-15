// Package output renders every command's result in exactly one of two
// shapes: an aligned table for a human, or the versioned JSON envelope
// defined in internal/vc.
//
// The split matters more than it looks. `--json` is a contract that agents
// and scripts parse (§5 of the CLI design), so a stray progress line on
// stdout is a breaking change, not cosmetic noise. Routing all output
// through one Printer is what makes that mechanically impossible: under
// JSON the human-facing calls are no-ops, and errors always leave on stderr
// so a caller can read stdout as a single document.
package output

import (
	"fmt"
	"io"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// Format selects the rendering shape. Table is the zero value because a
// human at a terminal is the default audience; --json opts in.
type Format int

const (
	Table Format = iota
	JSON
)

// Printer renders results. It is not safe for concurrent use — commands are
// single-threaded, and the TUI does its own rendering.
type Printer struct {
	out    io.Writer
	errw   io.Writer
	format Format
	color  bool

	dim    lipgloss.Style
	green  lipgloss.Style
	yellow lipgloss.Style
	red    lipgloss.Style
}

// New builds a Printer over out and errw.
//
// color is the user's intent (--no-color clears it), not the final say:
// even when it is set, the styles are bound to a renderer attached to out,
// so lipgloss's own terminal detection still strips colour from a pipe or a
// file. That is why `vibecare plugins | grep UP` works without any flag.
func New(out, errw io.Writer, f Format, color bool) *Printer {
	p := &Printer{out: out, errw: errw, format: f, color: color}
	if color {
		// Base ANSI colours only. The 8-colour set is the one that survives
		// every profile and every user's theme remap.
		r := lipgloss.NewRenderer(out)
		p.dim = r.NewStyle().Faint(true)
		p.green = r.NewStyle().Foreground(lipgloss.Color("2"))
		p.yellow = r.NewStyle().Foreground(lipgloss.Color("3"))
		p.red = r.NewStyle().Foreground(lipgloss.Color("1"))
	}
	return p
}

// IsJSON reports whether this printer is emitting the machine contract.
// Commands consult it to skip work that only a human would want, such as
// resolving a plugin's display name.
func (p *Printer) IsJSON() bool { return p.format == JSON }

// style applies s only when colour is enabled. The explicit guard, rather
// than a zero Style that renders to itself, is what guarantees byte-for-byte
// plain output — golden files depend on it.
func (p *Printer) style(s lipgloss.Style, text string) string {
	if !p.color {
		return text
	}
	return s.Render(text)
}

// Line writes one human-facing line to stdout. It is silent under --json,
// where stdout belongs to the envelope alone.
func (p *Printer) Line(format string, a ...any) {
	if p.IsJSON() {
		return
	}
	s := fmt.Sprintf(format, a...)
	if !strings.HasSuffix(s, "\n") {
		s += "\n"
	}
	fmt.Fprint(p.out, s)
}

// Err reports a failure on stderr, in whichever shape the caller asked for.
// It never touches stdout: under --json a consumer must be able to parse
// stdout even on the failure path, and in table mode a half-written table
// followed by an error is still greppable.
func (p *Printer) Err(err error) {
	if err == nil {
		return
	}
	if p.IsJSON() {
		body := vc.Body(err)
		// Encoding failures here have nowhere left to go — stderr is the
		// channel that just failed — so the exit code carries the news.
		_ = encode(p.errw, vc.Envelope{V: vc.ContractVersion, Err: &body})
		return
	}
	fmt.Fprintln(p.errw, p.style(p.red, "error: "+err.Error()))
}

// State renders a lifecycle state as a colourised label. Unknown values pass
// through unstyled rather than being dropped, so a kernel that grows a new
// state stays legible through an older client.
func (p *Printer) State(s vc.State) string {
	label := string(s)
	switch s {
	case vc.StateUp:
		return p.style(p.green, label)
	case vc.StateDegraded:
		return p.style(p.yellow, label)
	case vc.StateDown, vc.StateFailed:
		return p.style(p.red, label)
	case vc.StateStarting, vc.StateUnknown:
		return p.style(p.dim, label)
	}
	return label
}
