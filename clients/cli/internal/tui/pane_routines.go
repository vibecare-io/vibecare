package tui

import (
	"strconv"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// routinesPane is a list over its selection's actions: the two questions
// asked about a routine are "what are they" and "what does this one do", and
// splitting them across two tabs would make the second cost a keystroke and
// lose the first.
//
// Running a routine is a write, so this pane reports what is unwired rather
// than pretending the key worked. See schedulesPane for the same reasoning.
type routinesPane struct {
	th *theme.Theme

	routines []vc.Routine
	cursor   int
	top      int
	winH     int
}

func init() {
	for _, k := range []SubjectKind{SubjectAll, SubjectCore} {
		Register(k, keymap.CtxRoutines, func(p PaneCtx) Pane {
			return routinesPane{th: paneTheme(p.Theme), winH: 20}
		})
	}
}

func (p routinesPane) Init(PaneCtx) tea.Cmd   { return nil }
func (p routinesPane) Title() string          { return "Routines" }
func (p routinesPane) Chips() []Chip          { return nil }
func (p routinesPane) KeyContext() keymap.Ctx { return keymap.CtxRoutines }

func (p routinesPane) Update(msg tea.Msg) (Pane, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		if h := msg.Height - headerLines - footerLines - chromeLines; h > 0 {
			p.winH = h
		}

	case RoutinesMsg:
		p.routines = msg.Routines
		p.clampCursor()

	case ActionMsg:
		switch msg.Action {
		case keymap.ActionSelectPrev:
			p.cursor--
			p.clampCursor()
		case keymap.ActionSelectNext:
			p.cursor++
			p.clampCursor()
		case keymap.ActionRun:
			return p, noticeCmd("run %s needs a routine command in cmds.go", p.selectedID())
		case keymap.ActionRoutineLogs:
			return p, noticeCmd("run log for %s needs a routine command in cmds.go", p.selectedID())
		}

	case tea.KeyMsg:
		switch msg.String() {
		case "k":
			p.cursor--
			p.clampCursor()
		case "j":
			p.cursor++
			p.clampCursor()
		}
	}
	return p, nil
}

func (p *routinesPane) clampCursor() {
	if p.cursor >= len(p.routines) {
		p.cursor = len(p.routines) - 1
	}
	if p.cursor < 0 {
		p.cursor = 0
	}
}

func (p routinesPane) selected() (vc.Routine, bool) {
	if p.cursor < 0 || p.cursor >= len(p.routines) {
		return vc.Routine{}, false
	}
	return p.routines[p.cursor], true
}

func (p routinesPane) selectedID() string {
	if r, ok := p.selected(); ok {
		return r.ID
	}
	return "nothing"
}

func (p routinesPane) View(w, h int) string {
	if len(p.routines) == 0 {
		return clamp(p.th.Dim.Render("no routines — core has none, or has not answered yet"), w, h)
	}

	// The list gets the top half and the selection's actions the rest, so
	// moving the cursor never changes where either block starts.
	listH := h / 2
	if listH < 2 {
		listH = 2
	}

	rows := make([][]string, 0, len(p.routines))
	for i, r := range p.routines {
		mark := " "
		if i == p.cursor {
			mark = cursor
		}
		enabled := p.th.Good.Render("on")
		if !r.Enabled {
			enabled = p.th.Warn.Render("off")
		}
		rows = append(rows, []string{mark + r.Name, enabled, strconv.Itoa(len(r.Actions)), orDash(r.Notes)})
	}

	top := scrollWindow(p.top, p.cursor, len(rows), listH-1)
	end := top + listH - 1
	if end > len(rows) {
		end = len(rows)
	}
	list := renderGrid([]string{" NAME", "STATE", "ACTIONS", "NOTES"}, rows[top:end], p.th, w)

	return clamp(list+"\n\n"+p.actionsView(w), w, h)
}

func (p routinesPane) actionsView(w int) string {
	r, ok := p.selected()
	if !ok {
		return ""
	}
	head := p.th.Title.Render(r.Name) + p.th.Dim.Render("  actions")
	if len(r.Actions) == 0 {
		// The routine list does not always carry its actions, so this says
		// "none came back", not "this routine does nothing".
		return head + "\n" + p.th.Dim.Render("no actions came back with this routine — `vibecare routines show "+r.ID+"` fetches them")
	}
	return head + "\n" + renderGrid(actionHeaders(), actionRows(r.Actions), p.th, w)
}

// actionHeaders and actionRows render the action list that hangs off both a
// routine and a schedule, so the two cannot drift apart. They mirror the
// same pair in internal/cli, which serves the non-interactive surface.
func actionHeaders() []string { return []string{"#", "NAME", "TYPE", "STATE"} }

// actionRows numbers from 1: Order is the join table's zero-based execution
// order, and "action 0" is an index, not a step.
func actionRows(actions []vc.Action) [][]string {
	rows := make([][]string, 0, len(actions))
	for _, a := range actions {
		state := "on"
		if !a.Enabled {
			state = "off"
		}
		rows = append(rows, []string{
			strconv.Itoa(int(a.Order) + 1),
			orDash(a.Name),
			orDash(a.Type),
			state,
		})
	}
	return rows
}
