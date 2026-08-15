package tui

import (
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// schedulesPane lists what is scheduled and when it next fires. Times are
// relative because the question is always "how long until" or "how long
// since"; the absolute instant is in the detail view and in --json, where a
// parser can have it.
//
// Pausing and resuming are writes, and a pane may not perform one. The keys
// are bound, so pressing one says what is missing instead of silently doing
// nothing — a key that appears to work and does not is worse than one that
// admits it is unwired.
type schedulesPane struct {
	th *theme.Theme

	schedules []vc.Schedule
	cursor    int
	filter    string // "" all, "enabled", "paused"
	open      bool
	top       int
	winH      int
}

var scheduleFilters = []string{"", "enabled", "paused"}

func init() {
	for _, k := range []SubjectKind{SubjectAll, SubjectCore} {
		Register(k, keymap.CtxSchedules, func(p PaneCtx) Pane {
			return schedulesPane{th: paneTheme(p.Theme), winH: 20}
		})
	}
}

func (p schedulesPane) Init(PaneCtx) tea.Cmd   { return nil }
func (p schedulesPane) Title() string          { return "Schedules" }
func (p schedulesPane) KeyContext() keymap.Ctx { return keymap.CtxSchedules }

func (p schedulesPane) Chips() []Chip {
	chips := make([]Chip, 0, len(scheduleFilters))
	for _, f := range scheduleFilters {
		label := f
		if label == "" {
			label = "all"
		}
		chips = append(chips, Chip{Label: label, Active: p.filter == f, Filter: true})
	}
	return chips
}

func (p schedulesPane) Update(msg tea.Msg) (Pane, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		if h := msg.Height - headerLines - footerLines - chromeLines; h > 0 {
			p.winH = h
		}

	case SchedulesMsg:
		p.schedules = msg.Schedules
		p.clampCursor()

	case ActionMsg:
		return p.act(msg.Action)

	case tea.KeyMsg:
		switch msg.String() {
		case "tab":
			p.filter = nextFilter(scheduleFilters, p.filter)
			p.cursor, p.top = 0, 0
		case "k":
			p.move(-1)
		case "j":
			p.move(1)
		}
	}
	return p, nil
}

func (p schedulesPane) act(a string) (Pane, tea.Cmd) {
	switch a {
	case keymap.ActionSelectPrev:
		p.move(-1)
	case keymap.ActionSelectNext:
		p.move(1)
	case keymap.ActionOpen:
		p.open = !p.open

	case keymap.ActionPause:
		return p, noticeCmd("pause %s needs a schedule command in cmds.go", p.selectedID())
	case keymap.ActionPauseAll:
		return p, noticeCmd("pause all needs a schedule command in cmds.go")
	case keymap.ActionResume:
		return p, noticeCmd("resume %s needs a schedule command in cmds.go", p.selectedID())
	case keymap.ActionResumeAll:
		return p, noticeCmd("resume all needs a schedule command in cmds.go")
	}
	return p, nil
}

func (p *schedulesPane) move(d int) {
	p.cursor += d
	p.clampCursor()
}

func (p *schedulesPane) clampCursor() {
	n := len(p.visible())
	if p.cursor >= n {
		p.cursor = n - 1
	}
	if p.cursor < 0 {
		p.cursor = 0
	}
}

func (p schedulesPane) visible() []vc.Schedule {
	if p.filter == "" {
		return p.schedules
	}
	want := p.filter == "enabled"
	out := make([]vc.Schedule, 0, len(p.schedules))
	for _, s := range p.schedules {
		if s.Enabled == want {
			out = append(out, s)
		}
	}
	return out
}

func (p schedulesPane) selected() (vc.Schedule, bool) {
	vis := p.visible()
	if p.cursor < 0 || p.cursor >= len(vis) {
		return vc.Schedule{}, false
	}
	return vis[p.cursor], true
}

func (p schedulesPane) selectedID() string {
	if s, ok := p.selected(); ok {
		return s.ID
	}
	return "nothing"
}

func (p schedulesPane) View(w, h int) string {
	vis := p.visible()
	if len(vis) == 0 {
		return clamp(p.th.Dim.Render(p.emptyText()), w, h)
	}

	detail := ""
	listH := h
	if p.open {
		if s, ok := p.selected(); ok {
			detail = p.detailView(s, w)
			listH = h - lineCount(detail) - 1
		}
	}
	if listH < 2 {
		listH = 2
	}

	now := time.Now()
	rows := make([][]string, 0, len(vis))
	for i, s := range vis {
		mark := " "
		if i == p.cursor {
			mark = cursor
		}
		enabled := p.th.Good.Render("on")
		if !s.Enabled {
			enabled = p.th.Warn.Render("paused")
		}
		rows = append(rows, []string{
			mark + s.Name,
			enabled,
			relAt(s.NextExecution, now),
			relAt(s.LastExecution, now),
			orDash(s.RRule),
		})
	}

	// The header costs a row, so the window is one shorter than the space.
	top := scrollWindow(p.top, p.cursor, len(rows), listH-1)
	end := top + listH - 1
	if end > len(rows) {
		end = len(rows)
	}
	list := renderGrid([]string{" NAME", "STATE", "NEXT", "LAST", "RRULE"}, rows[top:end], p.th, w)

	if detail == "" {
		return clamp(list, w, h)
	}
	return clamp(list+"\n\n"+detail, w, h)
}

func (p schedulesPane) detailView(s vc.Schedule, w int) string {
	now := time.Now()
	pairs := [][2]string{
		{"id", s.ID},
		{"routine", orDash(s.RoutineID)},
		{"rrule", orDash(s.RRule)},
		{"timezone", orDash(s.Timezone)},
		{"next", relAt(s.NextExecution, now)},
		{"last", relAt(s.LastExecution, now)},
		{"notes", orDash(s.Notes)},
	}
	out := renderKV(pairs, p.th, w)
	if len(s.Actions) == 0 {
		// List never populates Actions — only Get does — so an empty list
		// here means "not fetched", not "none".
		return out + "\n" + p.th.Dim.Render("actions are not carried by the schedule list; open this schedule with `vibecare schedules show`")
	}
	return out + "\n" + renderGrid(actionHeaders(), actionRows(s.Actions), p.th, w)
}

func (p schedulesPane) emptyText() string {
	if len(p.schedules) > 0 {
		return "no " + p.filter + " schedules — the filter is hiding all of them"
	}
	return "no schedules — core has none, or has not answered yet"
}

func nextFilter(steps []string, cur string) string {
	for i, s := range steps {
		if s == cur {
			return steps[(i+1)%len(steps)]
		}
	}
	return ""
}

// lineCount counts rendered rows. A block's height is what the list
// above it has to give up, and counting newlines is exactly that.
func lineCount(s string) int {
	if s == "" {
		return 0
	}
	return strings.Count(s, "\n") + 1
}
