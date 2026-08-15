package tui

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// overviewPane answers "what is this thing doing right now" for whichever
// subject the sidebar has selected. One pane rather than three because the
// question is the same and only the fields differ; three would drift.
//
// It also hosts the small render primitives at the bottom of this file. They
// are shared by every pane_*.go in this package and are each too small to
// justify a file, and the one-pane-per-file rule leaves them no other home.
type overviewPane struct {
	th      *theme.Theme
	ctx     keymap.Ctx
	subject Subject

	roster vc.Roster
	status vc.Status
	plugin *vc.Plugin

	// stale means the last thing core said is all we have. Nothing is
	// cleared when it is set: an old number answers more questions than a
	// blank pane, it just has to be labelled as old.
	stale bool

	// connected records that core answered at least once, which is what
	// makes "last known" meaningful. Without it this pane cannot tell a
	// core it never reached from one that answered and had nothing.
	connected bool
}

// staleBanner distinguishes the two ways core can be missing. They call for
// different things from the reader: one means the values below are old, the
// other means there are no values at all and the address is worth checking.
func (p overviewPane) staleBanner() string {
	if p.connected {
		return "core unreachable — showing last known"
	}
	return unreachableAt(p.status.Addr) + " — retrying"
}

func init() {
	// The same pane serves four (subject, tab) pairs: core's Status and a
	// plugin's Stats are this pane's content under a different tab name.
	for _, reg := range []struct {
		kind SubjectKind
		ctx  keymap.Ctx
	}{
		{SubjectAll, keymap.CtxOverview},
		{SubjectPlugin, keymap.CtxOverview},
		{SubjectPlugin, keymap.CtxStats},
		{SubjectCore, keymap.CtxStatus},
	} {
		c := reg.ctx
		Register(reg.kind, c, func(p PaneCtx) Pane {
			return overviewPane{th: paneTheme(p.Theme), ctx: c, subject: p.Subject, plugin: p.Subject.Plugin}
		})
	}
}

func (p overviewPane) Init(PaneCtx) tea.Cmd   { return nil }
func (p overviewPane) Chips() []Chip          { return nil }
func (p overviewPane) KeyContext() keymap.Ctx { return p.ctx }

func (p overviewPane) Title() string {
	if p.ctx == keymap.CtxStatus {
		return "Status"
	}
	return "Overview"
}

func (p overviewPane) Update(msg tea.Msg) (Pane, tea.Cmd) {
	switch msg := msg.(type) {
	case RosterMsg:
		p.roster = msg.Roster
		p.plugin = findPlugin(msg.Roster, p.subject.ID, p.plugin)
		// Receiving a roster — even an empty one — proves core was reached
		// at some point, which is what earns this pane the right to say
		// "core found nothing in its plugins directory".
		//
		// It does not clear `stale`, for the same reason the root model no
		// longer does: vc replays the last roster to every new subscriber, so
		// this message arrives on every reconnect attempt regardless of
		// whether core is answering. Only a reachable Status clears it.
		p.connected = true

	case StatusMsg:
		p.status = msg.Status
		if msg.Status.Reachable {
			p.connected = true
			p.stale = false
		} else {
			// Status carries unreachability in its result, not as an error,
			// so this branch is the only notice this pane gets that core is
			// gone. Leaving it empty is what let the pane keep asserting
			// core had simply found no plugins.
			p.stale = true
		}

	case ErrMsg:
		if unreachable(msg.Err) {
			p.stale = true
		}

	case ActionMsg:
		if msg.Action == keymap.ActionCopy {
			return p, noticeCmd("copy needs a clipboard command in cmds.go")
		}
	}
	return p, nil
}

func (p overviewPane) View(w, h int) string {
	var body string
	switch p.subject.Kind {
	case SubjectCore:
		body = p.coreView(w)
	case SubjectPlugin:
		body = p.pluginView(w)
	default:
		body = p.allView(w)
	}
	if p.stale {
		body = p.th.Bad.Render(p.staleBanner()) + "\n\n" + body
	}
	return clamp(body, w, h)
}

// allView is the whole system on one screen: the tally first because it is
// the answer, then a row per plugin for the follow-up question.
func (p overviewPane) allView(w int) string {
	t := p.roster.Tally()
	head := fmt.Sprintf("%d total   %d up   %d degraded   %d down   %d failed   %d starting",
		t.Total, t.Up, t.Degraded, t.Down, t.Failed, t.Starting)

	if len(p.roster.Plugins) == 0 {
		// "No plugins discovered" is a claim about core's plugins
		// directory, and it is only true once core has actually answered.
		// Before that the honest statement is that nothing is known yet —
		// the banner above already says core is unreachable, so repeating a
		// confident empty-roster message here would contradict it.
		if !p.connected {
			// Say what to do, not just what is wrong. Core being down is
			// the most common thing this tool reports, and the two useful
			// responses are always the same: start it, or read why it
			// stopped.
			return head + "\n\n" + p.th.Dim.Render(
				"no roster yet — core has not answered\n\n"+
					"  start it       just run\n"+
					"  check the log  "+coreLogPath())
		}
		return head + "\n\n" + p.th.Dim.Render("no plugins discovered — core found nothing in its plugins directory")
	}

	rows := make([][]string, 0, len(p.roster.Plugins))
	for _, pl := range p.roster.Plugins {
		rows = append(rows, []string{
			pl.ID,
			p.th.State(pl.State).Render(string(pl.State)),
			statNum(pl, pl.PID),
			statText(pl, humanAge(time.Duration(pl.UptimeSec)*time.Second)),
			statNum(pl, pl.Restarts),
			statText(pl, fmt.Sprintf("%d/%d", pl.EventsPublished, pl.EventsDelivered)),
			pl.Detail,
		})
	}
	grid := renderGrid([]string{"ID", "STATE", "PID", "UPTIME", "RESTARTS", "EV P/D", "DETAIL"}, rows, p.th, w)
	return head + "\n\n" + grid
}

func (p overviewPane) coreView(w int) string {
	st := p.status
	reach := p.th.Good.Render("reachable")
	if !st.Reachable {
		reach = p.th.Bad.Render("unreachable")
		if st.Error != "" {
			reach += " — " + st.Error
		}
	}

	sched := p.th.Dim.Render("unknown")
	if st.Scheduler != nil {
		sched = p.th.Good.Render("running")
		if !st.Scheduler.Running {
			sched = p.th.Warn.Render("stopped")
		}
	}

	t := st.Plugins
	pairs := [][2]string{
		{"addr", orDash(st.Addr)},
		{"state", reach},
		{"version", orDash(st.Version)},
		{"kernel", orDash(st.Kernel)},
		{"scheduler", sched},
		{"plugins", fmt.Sprintf("%d total   %d up   %d degraded   %d down   %d failed", t.Total, t.Up, t.Degraded, t.Down, t.Failed)},
	}
	return renderKV(pairs, p.th, w)
}

func (p overviewPane) pluginView(w int) string {
	pl := p.plugin
	if pl == nil {
		return p.th.Dim.Render("this plugin is no longer on the roster")
	}

	state := p.th.State(pl.State).Render(string(pl.State))
	if pl.Detail != "" {
		state += " — " + pl.Detail
	}
	pairs := [][2]string{
		{"id", pl.ID},
		{"name", orDash(pl.Name)},
		{"state", state},
		{"ui", orDash(pl.UI)},
		{"path", orDash(pl.Path)},
	}

	// Without kernel stats every number below is a zero value rather than a
	// measurement, so none of them are printed. "0 restarts" read off an
	// unmeasured row is worse than no number at all.
	if !pl.Stats {
		return renderKV(pairs, p.th, w) + "\n\n" +
			p.th.Dim.Render("kernel stats unavailable — this is the roster's identity only")
	}

	last := p.th.Dim.Render("never")
	if pl.LastEventUnix > 0 {
		at := time.Unix(pl.LastEventUnix, 0)
		last = relAt(&at, time.Now())
	}
	pairs = append(pairs,
		[2]string{"pid", strconv.Itoa(pl.PID)},
		[2]string{"uptime", humanAge(time.Duration(pl.UptimeSec) * time.Second)},
		[2]string{"restarts", strconv.Itoa(pl.Restarts)},
		[2]string{"probe", fmt.Sprintf("%dms", pl.ProbeLatencyMS)},
		[2]string{"events", fmt.Sprintf("%d published   %d delivered   last %s", pl.EventsPublished, pl.EventsDelivered, last)},
		[2]string{"log", orDash(pl.LogPath)},
	)
	return renderKV(pairs, p.th, w)
}

// statNum and statText blank a stats field the kernel never measured, so an
// unmeasured row reads as "—" rather than as a confident zero.
func statNum(p vc.Plugin, v int) string {
	if !p.Stats {
		return dash
	}
	return strconv.Itoa(v)
}

func statText(p vc.Plugin, s string) string {
	if !p.Stats {
		return dash
	}
	return s
}

// findPlugin re-reads a subject's row out of a fresh roster. The fallback
// matters: a roster that momentarily omits the plugin must not blank the
// pane the user is reading.
func findPlugin(r vc.Roster, id string, prev *vc.Plugin) *vc.Plugin {
	if id == "" {
		return prev
	}
	for i := range r.Plugins {
		if r.Plugins[i].ID == id {
			p := r.Plugins[i]
			return &p
		}
	}
	return prev
}

// --- shared pane primitives ------------------------------------------------

// dash is what an absent value prints as. An empty cell reads as a rendering
// bug; a dash reads as "core did not set this".
const dash = "—"

// paneTheme tolerates a pane built without one. Panes are constructed by a
// registry that anyone can call, and a nil dereference at render time is a
// crash in the middle of a full-screen program.
func paneTheme(t *theme.Theme) *theme.Theme {
	if t == nil {
		return theme.New(true)
	}
	return t
}

func orDash(s string) string {
	if s == "" {
		return dash
	}
	return s
}

// noticeCmd reports something to the user through the chrome's notice line.
// It is a command rather than pane state so that the message appears in the
// one place the user already watches for feedback.
func noticeCmd(format string, a ...any) tea.Cmd {
	text := fmt.Sprintf(format, a...)
	return func() tea.Msg { return NoticeMsg{Text: text, At: time.Now()} }
}

// renderKV lays label/value pairs out in two columns. Labels are dim because
// the eye is looking for the values.
func renderKV(pairs [][2]string, th *theme.Theme, w int) string {
	keyW := 0
	for _, p := range pairs {
		if n := lipgloss.Width(p[0]); n > keyW {
			keyW = n
		}
	}
	lines := make([]string, 0, len(pairs))
	for _, p := range pairs {
		label := th.Dim.Render(p[0]) + strings.Repeat(" ", keyW-lipgloss.Width(p[0]))
		lines = append(lines, clamp(label+"  "+p[1], w, 1))
	}
	return strings.Join(lines, "\n")
}

// renderGrid is the one table in the TUI. Columns are measured in printed
// cells, so a styled cell still lines up, and the last column absorbs the
// truncation because it is the one carrying prose.
func renderGrid(headers []string, rows [][]string, th *theme.Theme, w int) string {
	widths := make([]int, len(headers))
	for i, h := range headers {
		widths[i] = lipgloss.Width(h)
	}
	for _, r := range rows {
		for i, c := range r {
			if i < len(widths) && lipgloss.Width(c) > widths[i] {
				widths[i] = lipgloss.Width(c)
			}
		}
	}

	out := make([]string, 0, len(rows)+1)
	head := make([]string, 0, len(headers))
	for i, h := range headers {
		head = append(head, pad(h, widths[i]))
	}
	out = append(out, clamp(th.Dim.Render(strings.Join(head, "  ")), w, 1))

	for _, r := range rows {
		cells := make([]string, 0, len(r))
		for i, c := range r {
			if i < len(widths) {
				cells = append(cells, pad(c, widths[i]))
			}
		}
		out = append(out, clamp(strings.Join(cells, "  "), w, 1))
	}
	return strings.Join(out, "\n")
}

// scrollWindow picks which slice of n rows is on screen, keeping cursor
// visible without moving the view any further than it has to.
func scrollWindow(top, cursor, n, h int) int {
	if h < 1 {
		h = 1
	}
	if top > n-h {
		top = n - h
	}
	if cursor >= 0 {
		if cursor < top {
			top = cursor
		}
		if cursor >= top+h {
			top = cursor - h + 1
		}
	}
	if top < 0 {
		top = 0
	}
	return top
}

// humanAge renders a duration at one unit of precision, which is all a
// status line ever needs. Hours keep their minutes because "1h" and "1h59m"
// are different answers to "how long has this been up".
func humanAge(d time.Duration) string {
	if d < 0 {
		d = -d
	}
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh%dm", int(d.Hours()), int(d.Minutes())%60)
	default:
		return fmt.Sprintf("%dd%dh", int(d.Hours())/24, int(d.Hours())%24)
	}
}

// relAt renders a timestamp as an offset from now. A timestamp core never
// set is a dash, not a date near the epoch: "has not run" and "ran in 1970"
// are different answers and only one of them is true.
func relAt(t *time.Time, now time.Time) string {
	if t == nil || t.IsZero() {
		return dash
	}
	d := t.Sub(now)
	if d < 0 {
		d = -d
	}
	if d < time.Second {
		return "now"
	}
	if t.After(now) {
		return "in " + humanAge(d)
	}
	return humanAge(d) + " ago"
}

// coreLogPath resolves core's own log so the hint can be copied straight
// into a tail. It is duplicated from internal/cli rather than shared: the
// two packages are deliberately independent, and a one-line path is a
// cheaper duplication than a coupling between frontends.
func coreLogPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "~/.vibecare/logs/server.log"
	}
	return filepath.Join(home, ".vibecare", "logs", "server.log")
}
