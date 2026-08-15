package tui

import (
	"strconv"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// alertsPane is the scrollback core does not keep. Alerts are transient —
// Shell.Intents pushes them and nothing retains them — so whatever this pane
// drops is gone, which is why it keeps a generous buffer and appends rather
// than replaces.
//
// Newest is at the bottom, like a log: an alert stream is read as a
// narrative, and a list that grows upward makes the reader re-find their
// place every time one arrives.
type alertsPane struct {
	th *theme.Theme

	alerts []vc.Alert
	// baseURL resolves a plugin's relative action URL. It comes from the
	// roster because the kernel binds an ephemeral port, so it is reported
	// by core rather than configured here.
	baseURL string

	level  string // "" all, else "info" or "warn"
	follow bool
	top    int
	winH   int
	muted  bool
}

// alertBuffer is how many alerts are kept. Large, because losing one is
// losing it permanently, and each is a handful of lines.
const alertBuffer = 500

// alertLevels is what the filter cycles through, "all" first.
var alertLevels = []string{"", "info", "warn"}

func init() {
	Register(SubjectAll, keymap.CtxAlerts, func(p PaneCtx) Pane {
		return alertsPane{th: paneTheme(p.Theme), follow: true, winH: 20}
	})
}

func (p alertsPane) Init(PaneCtx) tea.Cmd   { return nil }
func (p alertsPane) Title() string          { return "Alerts" }
func (p alertsPane) KeyContext() keymap.Ctx { return keymap.CtxAlerts }

func (p alertsPane) Chips() []Chip {
	chips := []Chip{{Label: "follow", Active: p.follow}}
	for _, l := range alertLevels {
		label := l
		if label == "" {
			label = "all"
		}
		chips = append(chips, Chip{Label: label, Active: p.level == l, Filter: true})
	}
	if p.muted {
		chips = append(chips, Chip{Label: "muted", Active: true})
	}
	return chips
}

func (p alertsPane) Update(msg tea.Msg) (Pane, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		if h := msg.Height - headerLines - footerLines - chromeLines; h > 0 {
			p.winH = h
		}

	case AlertMsg:
		p.alerts = append(p.alerts, msg.Alert)
		if over := len(p.alerts) - alertBuffer; over > 0 {
			p.alerts = p.alerts[over:]
		}

	case RosterMsg:
		if msg.Roster.BaseURL != "" {
			p.baseURL = msg.Roster.BaseURL
		}

	case ActionMsg:
		switch msg.Action {
		case keymap.ActionLogFollow:
			p.follow = !p.follow
		case keymap.ActionClear:
			p.alerts, p.top = nil, 0
		case keymap.ActionAlertMute:
			// The root owns muting; the chip only reflects it, so that the
			// pane says what state the desktop bridge is in.
			p.muted = !p.muted
		case keymap.ActionSelectPrev:
			p.scroll(-1)
		case keymap.ActionSelectNext:
			p.scroll(1)
		case keymap.ActionCopy:
			return p, noticeCmd("copy needs a clipboard command in cmds.go")
		}

	case tea.KeyMsg:
		switch msg.String() {
		case "tab":
			p.level = nextLevel(p.level)
			p.top = 0
		case "k":
			p.scroll(-1)
		case "j":
			p.scroll(1)
		}
	}
	return p, nil
}

// scroll follows the same rule as the log pane: reading backwards turns
// follow off, and nothing turns it back on but the reader.
func (p *alertsPane) scroll(d int) {
	if p.follow {
		if d >= 0 {
			return
		}
		p.follow = false
		p.top = p.rowCount() - p.winH
	}
	p.top += d
	if p.top < 0 {
		p.top = 0
	}
}

func (p alertsPane) View(w, h int) string {
	rows := p.rows(w)
	if len(rows) == 0 {
		return clamp(p.th.Dim.Render(p.emptyText()), w, h)
	}

	start := p.top
	if p.follow {
		start = len(rows) - h
	}
	if start > len(rows)-h {
		start = len(rows) - h
	}
	if start < 0 {
		start = 0
	}

	end := start + h
	if end > len(rows) {
		end = len(rows)
	}
	return clamp(strings.Join(rows[start:end], "\n"), w, h)
}

// rows renders every visible alert into its lines, oldest first.
func (p alertsPane) rows(w int) []string {
	var out []string
	for _, a := range p.alerts {
		if !p.shows(a) {
			continue
		}
		out = append(out, p.render(a, w)...)
	}
	return out
}

// rowCount is how tall the rendered list is, needed before a width is known:
// scrolling happens on a key, and View is the only thing that is told a
// width.
func (p alertsPane) rowCount() int {
	n := 0
	for _, a := range p.alerts {
		if !p.shows(a) {
			continue
		}
		n++
		if a.Body != "" {
			n++
		}
		n += len(a.Actions)
	}
	return n
}

func (p alertsPane) shows(a vc.Alert) bool {
	switch p.level {
	case "":
		return true
	case "warn":
		return a.Warn()
	default:
		// Level is optional on the wire, and an alert with none is
		// informational — that is what a plugin that did not ask for
		// attention meant.
		return !a.Warn()
	}
}

func (p alertsPane) render(a vc.Alert, w int) []string {
	level := "INFO"
	style := p.th.Dim
	if a.Warn() {
		level, style = "WARN", p.th.Warn
	}

	head := ""
	if !a.Received.IsZero() {
		head += p.th.Dim.Render(a.Received.Format(logTimeFmt)) + "  "
	}
	head += style.Render(level) + "  " + p.th.Title.Render(orDash(a.Plugin)) + "  " + a.Title

	rows := []string{clamp(head, w, 1)}
	if a.Body != "" {
		rows = append(rows, clamp("    "+p.th.Dim.Render(a.Body), w, 1))
	}
	for _, act := range a.Actions {
		rows = append(rows, clamp("    ["+act.Label+"] "+p.th.Dim.Render(p.resolve(a.Plugin, act.URL)), w, 1))
	}
	return rows
}

// resolve expands a plugin-relative action URL against the kernel origin.
// Without an origin the relative form is shown as-is rather than as a broken
// absolute one.
func (p alertsPane) resolve(plugin, url string) string {
	if url == "" {
		return ""
	}
	if strings.HasPrefix(url, "http://") || strings.HasPrefix(url, "https://") {
		return url
	}
	rel := "/p/" + plugin + "/" + strings.TrimPrefix(url, "/")
	if p.baseURL == "" {
		return rel
	}
	return strings.TrimSuffix(p.baseURL, "/") + rel
}

func (p alertsPane) emptyText() string {
	if len(p.alerts) > 0 {
		return "no alerts at this level — the filter is hiding " + strconv.Itoa(len(p.alerts))
	}
	return "no alerts yet — plugins push these through Shell.Intents, and core keeps none"
}

func nextLevel(cur string) string {
	for i, l := range alertLevels {
		if l == cur {
			return alertLevels[(i+1)%len(alertLevels)]
		}
	}
	return ""
}
