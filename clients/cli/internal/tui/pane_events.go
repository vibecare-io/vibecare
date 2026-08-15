package tui

import (
	"fmt"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// eventsPane shows what a plugin is doing on the bus.
//
// It shows counters and says so. Core keeps a published/delivered count and
// a last-event timestamp per plugin and retains no events, so there is no
// event list to render — and inventing one out of the plugin's own log would
// be a guess presented as a record. Naming the gap is more useful than
// filling it badly, and it is the note that tells whoever adds an event
// stream to core what this pane is waiting for.
type eventsPane struct {
	th      *theme.Theme
	subject Subject
	plugin  *vc.Plugin
}

func init() {
	Register(SubjectPlugin, keymap.CtxEvents, func(p PaneCtx) Pane {
		return eventsPane{th: paneTheme(p.Theme), subject: p.Subject, plugin: p.Subject.Plugin}
	})
}

func (p eventsPane) Init(PaneCtx) tea.Cmd   { return nil }
func (p eventsPane) Title() string          { return "Events" }
func (p eventsPane) Chips() []Chip          { return nil }
func (p eventsPane) KeyContext() keymap.Ctx { return keymap.CtxEvents }

func (p eventsPane) Update(msg tea.Msg) (Pane, tea.Cmd) {
	switch msg := msg.(type) {
	case RosterMsg:
		p.plugin = findPlugin(msg.Roster, p.subject.ID, p.plugin)

	case ActionMsg:
		switch msg.Action {
		case keymap.ActionCopy:
			return p, noticeCmd("copy needs a clipboard command in cmds.go")
		case keymap.ActionClear, keymap.ActionLogFollow:
			// Both keys exist for a scrolling event list. There is no list
			// to clear or follow, so they do nothing rather than pretending.
			return p, noticeCmd("core keeps bus counters only — there is no event list to follow")
		}
	}
	return p, nil
}

func (p eventsPane) View(w, h int) string {
	pl := p.plugin
	if pl == nil {
		return clamp(p.th.Dim.Render("this plugin is no longer on the roster"), w, h)
	}

	if !pl.Stats {
		body := renderKV([][2]string{{"plugin", pl.ID}}, p.th, w) + "\n\n" +
			p.th.Dim.Render("kernel stats unavailable — bus counters come from the kernel's HTTP surface,\nwhich this client could not reach")
		return clamp(body, w, h)
	}

	last := p.th.Dim.Render("never")
	if pl.LastEventUnix > 0 {
		at := time.Unix(pl.LastEventUnix, 0)
		last = relAt(&at, time.Now())
	}

	body := renderKV([][2]string{
		{"plugin", pl.ID},
		{"published", fmt.Sprintf("%d", pl.EventsPublished)},
		{"delivered", fmt.Sprintf("%d", pl.EventsDelivered)},
		{"last event", last},
	}, p.th, w)

	body += "\n\n" + p.th.Dim.Render(
		"topics: a plugin's subscribes/publishes live in its manifest.yaml, which core\n"+
			"does not serve, so they cannot be listed here yet\n\n"+
			"no per-event detail: core counts events and retains none, so there is nothing\n"+
			"to list — the Logs tab shows what the plugin itself printed")

	return clamp(body, w, h)
}
