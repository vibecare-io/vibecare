//go:build dev

package tui

import (
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/vibecare-io/vibecare/clients/cli/internal/plugbuild"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// rebuildPlugin runs the plugin's declared build command and restarts it —
// the whole edit/see-it loop from one keypress, without leaving the TUI.
//
// It lives behind the dev tag with its binding: a release build has no key
// for it and no code for it. The notice it produces lands in the action log
// like any other, so a session's rebuilds are part of the record of what you
// changed.
func (c *commands) rebuildPlugin(id string) tea.Cmd {
	if !c.live() {
		return nil
	}
	return func() tea.Msg {
		pl, err := c.s.PluginBuild(c.ctx, id)
		if err != nil {
			return ErrMsg{Err: err}
		}

		res, err := plugbuild.Run(c.ctx, pl.Dir, pl.Build)
		if err != nil {
			return ErrMsg{Err: vc.Wrap(err, "rebuild %s", id)}
		}
		if err := c.s.RestartPlugin(c.ctx, id); err != nil {
			// The build succeeded; saying otherwise would send the reader
			// back to their code instead of to the kernel.
			return ErrMsg{Err: vc.Wrap(err, "%s built, but restarting it", id)}
		}
		return NoticeMsg{
			Text: "rebuilt " + id + " in " + res.Duration.Round(time.Millisecond).String(),
			At:   time.Now(),
		}
	}
}

// rebuildCmd is the seam app.go calls. The release build's version returns
// nil, so the handler needs no build tag of its own.
func (m model) rebuildCmd(id string) tea.Cmd { return m.cmds.rebuildPlugin(id) }
