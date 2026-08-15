package tui

import (
	tea "github.com/charmbracelet/bubbletea"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// manifestPane shows what core knows about a plugin's declaration.
//
// It shows the roster's copy of it, which is identity plus the proxied UI
// path — not the manifest file. The file's other fields (exec, subscribes,
// publishes, the plugin directory) are only on disk, and reading a file is
// I/O, which belongs in cmds.go and does not exist there yet. So the pane
// renders what it has and names what it is missing, rather than leaving a
// half-empty screen that reads as a bug.
type manifestPane struct {
	th      *theme.Theme
	subject Subject
	plugin  *vc.Plugin
}

func init() {
	Register(SubjectPlugin, keymap.CtxManifest, func(p PaneCtx) Pane {
		return manifestPane{th: paneTheme(p.Theme), subject: p.Subject, plugin: p.Subject.Plugin}
	})
}

func (p manifestPane) Init(PaneCtx) tea.Cmd   { return nil }
func (p manifestPane) Title() string          { return "Manifest" }
func (p manifestPane) Chips() []Chip          { return nil }
func (p manifestPane) KeyContext() keymap.Ctx { return keymap.CtxManifest }

func (p manifestPane) Update(msg tea.Msg) (Pane, tea.Cmd) {
	switch msg := msg.(type) {
	case RosterMsg:
		p.plugin = findPlugin(msg.Roster, p.subject.ID, p.plugin)

	case ActionMsg:
		switch msg.Action {
		case keymap.ActionCopy:
			return p, noticeCmd("copy needs a clipboard command in cmds.go")
		case keymap.ActionOpen:
			return p, noticeCmd("opening manifest.yaml needs a file command in cmds.go")
		}
	}
	return p, nil
}

func (p manifestPane) View(w, h int) string {
	pl := p.plugin
	if pl == nil {
		return clamp(p.th.Dim.Render("no plugin selected, so there is no manifest to show"), w, h)
	}

	body := renderKV([][2]string{
		{"id", pl.ID},
		{"name", orDash(pl.Name)},
		{"icon", orDash(pl.Icon)},
		{"ui", orDash(pl.UI)},
		{"path", orDash(pl.Path)},
		{"log", orDash(pl.LogPath)},
	}, p.th, w)

	body += "\n\n" + p.th.Dim.Render(
		"exec, subscribes, publishes and the plugin directory are declared in\n"+
			"manifest.yaml on disk. Core does not serve that file, so this pane shows\n"+
			"only the fields the roster carries.")

	return clamp(body, w, h)
}
