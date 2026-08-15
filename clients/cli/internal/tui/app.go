package tui

import (
	"context"
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/vibecare-io/vibecare/clients/cli/internal/logtail"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// Layout constants. The proportions come from §6.1: a fifth of the screen
// for the subject list, the rest for its detail.
const (
	sidebarShare   = 5 // one fifth
	sidebarMin     = 14
	sidebarMax     = 28
	collapseBelow  = 90 // below this the names cost more than they inform
	collapsedWidth = 3  // cursor + bullet
	headerLines    = 1
	footerLines    = 2
	chipLines      = 2             // toggles line + filters line, always both
	chromeLines    = 1 + chipLines // tab strip + chip rows
	gutterCols     = 1             // space between the sidebar's rule and the pane

	coreID = "core"
	allID  = ""
)

// SubjectKind and its values are re-exported from keymap so panes have one
// import for the concept. keymap owns them because the binding tables are
// keyed by kind and keymap must not import its own consumer.
type SubjectKind = keymap.SubjectKind

const (
	SubjectAll    = keymap.SubjectAll
	SubjectCore   = keymap.SubjectCore
	SubjectPlugin = keymap.SubjectPlugin
)

// Focus is re-exported for the same reason, so the chrome and its tests name
// the two halves of the layout without importing keymap for one constant.
type Focus = keymap.Focus

const (
	FocusSidebar = keymap.FocusSidebar
	FocusDetail  = keymap.FocusDetail
)

// Subject is what the sidebar has selected: everything, core, or one plugin.
type Subject struct {
	Kind SubjectKind
	// ID is "" for ALL, "core", or the plugin id.
	ID string
	// Plugin is the roster row this subject was built from, nil unless Kind
	// is SubjectPlugin. Panes read stats from it rather than asking again.
	Plugin *vc.Plugin
}

// PaneCtx is everything a pane is given when it is built.
type PaneCtx struct {
	Subject Subject
	Theme   *theme.Theme
}

// Chip is one control in the row under the tabs — a toggle or a filter the
// pane owns, rendered by the chrome so every pane's controls look alike.
type Chip struct {
	Label  string
	Active bool
	Value  string
	// Filter separates the two kinds of control that share this row. A
	// toggle answers "how is this pane behaving" (follow, wrap, tail); a
	// filter answers "which of these am I looking at" (all, core, todo).
	// They read as one undifferentiated run when mixed, so they get a line
	// each — and only filters get the solid selected-chip treatment, since
	// exactly one of them is active at a time.
	Filter bool
}

// Pane is one tab's content. Panes are pure: they render from what messages
// gave them and ask for work by returning commands, never by calling core.
type Pane interface {
	Init(ctx PaneCtx) tea.Cmd
	Update(msg tea.Msg) (Pane, tea.Cmd)
	View(w, h int) string
	Title() string
	Chips() []Chip
	KeyContext() keymap.Ctx
}

// PaneFactory builds a pane for one subject.
type PaneFactory func(PaneCtx) Pane

type paneKey struct {
	Kind SubjectKind
	Ctx  keymap.Ctx
}

// registry is populated by the pane files' init functions. A missing entry
// is not a failure: the chrome shows a placeholder, which is what lets the
// layout be built and tested before any pane exists.
var registry = map[paneKey]PaneFactory{}

// Register installs the pane that renders ctx for subjects of kind k. Later
// registrations win, so a build can substitute one.
func Register(k SubjectKind, c keymap.Ctx, f PaneFactory) {
	registry[paneKey{k, c}] = f
}

func paneFor(k SubjectKind, c keymap.Ctx, pctx PaneCtx) Pane {
	if f, ok := registry[paneKey{k, c}]; ok {
		if p := f(pctx); p != nil {
			return p
		}
	}
	return placeholderPane{ctx: c}
}

// placeholderPane stands in for a tab nobody has written yet. It says which
// pane is missing rather than rendering an empty box that looks like a bug.
type placeholderPane struct {
	ctx   keymap.Ctx
	title string
}

func (p placeholderPane) Init(PaneCtx) tea.Cmd           { return nil }
func (p placeholderPane) Update(tea.Msg) (Pane, tea.Cmd) { return p, nil }
func (p placeholderPane) Chips() []Chip                  { return nil }
func (p placeholderPane) KeyContext() keymap.Ctx         { return p.ctx }
func (p placeholderPane) View(w, h int) string           { return clamp("no "+string(p.ctx)+" pane yet", w, h) }

func (p placeholderPane) Title() string {
	if p.title != "" {
		return p.title
	}
	return string(p.ctx)
}

// viewScope is the cancellation handle for everything the current view
// started. It is a pointer inside a value model on purpose: the model is
// copied on every update, and a cancel that got copied is a cancel that
// never runs.
type viewScope struct{ cancel context.CancelFunc }

func (v *viewScope) close() {
	if v == nil || v.cancel == nil {
		return
	}
	v.cancel()
	v.cancel = nil
}

// model is the root. It owns the layout, the subject and tab selection, and
// the lifetime of everything the current view started.
type model struct {
	cmds  *commands
	theme *theme.Theme

	width, height int

	subjects []Subject
	subjIdx  int
	tabIdx   int
	pane     Pane

	// focus is which half of the layout the keyboard drives. It starts on
	// the sidebar because that is where a user's eye lands and where the
	// first j/k must do something visible.
	focus keymap.Focus

	roster vc.Roster
	status vc.Status

	// stale means core stopped answering. Nothing is cleared when it is
	// set: last-known values are more use than a blank screen, they are
	// just marked as old.
	stale    bool
	staleMsg string
	notice   string
	retries  int

	// connected records that core answered at least once. It is what
	// separates "nothing is there" from "we have not heard yet", and those
	// must never render the same: an empty roster is a claim about core's
	// plugins directory, and it is only true once core has answered.
	connected bool

	// retrying means the reconnect clock is already ticking. It guards
	// against arming a second one: status is re-polled every pollInterval,
	// so arming per unreachable message would stack a timer every two
	// seconds and make the "backoff" fire faster the longer core is down.
	retrying bool

	zoom bool
	help bool
	tr   transient
	alog actionLog

	muted bool

	scope    *viewScope
	rosterCh *stream[vc.Roster]
	alertCh  *stream[vc.Alert]
	eventCh  *stream[vc.Event]
	logCh    *stream[logtail.Line]
}

func newModel(c *commands, opts Options) model {
	m := model{
		cmds:  c,
		theme: theme.New(true),
		scope: &viewScope{},
		muted: opts.Notifier == nil,
	}
	m.subjects = subjectsFrom(vc.Roster{})
	m.pane = paneFor(SubjectAll, keymap.Tabs(SubjectAll)[0].Ctx, m.paneCtx())
	return m
}

func (m model) paneCtx() PaneCtx {
	return PaneCtx{Subject: m.subject(), Theme: m.theme}
}

func (m model) Init() tea.Cmd {
	// No session means core was down when the client started. The UI still
	// comes up — a dead core is a state to render, not a reason to refuse —
	// and the reconnect loop is what eventually gets it a session.
	if !m.cmds.live() {
		return tea.Batch(m.connecting(), m.pane.Init(m.paneCtx()))
	}
	return tea.Batch(m.cmds.start(), m.pane.Init(m.paneCtx()))
}

// connecting arms the first reconnect attempt without waiting for the
// backoff, since the caller has already established that the dial failed.
func (m model) connecting() tea.Cmd { return m.cmds.connect(0) }

// subjectsFrom builds the sidebar's rows. ALL and core always exist, even
// with no roster at all — with core down that list is the only thing telling
// the user what they are looking at.
func subjectsFrom(r vc.Roster) []Subject {
	subjects := []Subject{
		{Kind: SubjectAll, ID: allID},
		{Kind: SubjectCore, ID: coreID},
	}
	for i := range r.Plugins {
		p := r.Plugins[i]
		subjects = append(subjects, Subject{Kind: SubjectPlugin, ID: p.ID, Plugin: &p})
	}
	return subjects
}

func (m model) subject() Subject {
	if len(m.subjects) == 0 {
		return Subject{Kind: SubjectAll}
	}
	i := m.subjIdx
	if i < 0 || i >= len(m.subjects) {
		i = 0
	}
	return m.subjects[i]
}

func (m model) tabs() []keymap.Tab { return keymap.Tabs(m.subject().Kind) }

// keyCtx is the context every key lookup and every rendered binding list is
// resolved against. The pane has the final say, because a pane may focus a
// sub-view with its own bindings.
func (m model) keyCtx() keymap.Ctx {
	if m.pane != nil {
		return m.pane.KeyContext()
	}
	tabs := m.tabs()
	if m.tabIdx < len(tabs) {
		return tabs[m.tabIdx].Ctx
	}
	return keymap.CtxOverview
}

func (m model) collapsed() bool { return m.width > 0 && m.width < collapseBelow }

func (m model) sidebarWidth() int {
	switch {
	case m.zoom, m.width <= collapsedWidth*2:
		return 0
	case m.collapsed():
		return collapsedWidth
	}
	w := m.width / sidebarShare
	if w < sidebarMin {
		w = sidebarMin
	}
	if w > sidebarMax {
		w = sidebarMax
	}
	if w > m.width/2 {
		w = m.width / 2
	}
	return w
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m.forward(msg)

	case tea.KeyMsg:
		return m.handleKey(msg)

	case RosterStreamMsg:
		m.rosterCh = msg.S
		return m, m.cmds.nextRoster(msg.S)

	case EventStreamMsg:
		m.eventCh = msg.S
		return m, m.cmds.nextEvent(msg.S)

	case EventMsg:
		next, cmd := m.forward(msg)
		return next, tea.Batch(cmd, m.cmds.nextEvent(m.eventCh))

	case AlertStreamMsg:
		m.alertCh = msg.S
		return m, m.cmds.nextAlert(msg.S)

	case LogStreamMsg:
		m.logCh = msg.S
		return m, m.cmds.nextLog(msg.S)

	case RosterMsg:
		m.roster = msg.Roster
		// A roster proves core was reached at SOME point, which is what
		// separates an empty roster from "we have not heard yet".
		m.connected = true
		// It deliberately does not clear `stale` or the retry chain. vc
		// replays its last roster to every new subscriber, so a reconnect
		// attempt gets this message back whether or not core answered —
		// treating it as recovery cleared the banner and reset the counter
		// every couple of seconds while core was down. Reachability has one
		// source of truth here, and it is Status.
		m, sel := m.reselect(subjectsFrom(msg.Roster))
		next, cmd := m.forward(msg)
		return next, tea.Batch(cmd, sel, m.cmds.nextRoster(m.rosterCh))

	case StatusMsg:
		m.status = msg.Status
		if msg.Status.Reachable {
			m.connected = true
			m = m.recovered()
			return m.forward(msg)
		}
		return m.lost(msg)

	case AlertMsg:
		next, cmd := m.forward(msg)
		return next, tea.Batch(cmd, m.alertCmd(msg.Alert), m.cmds.nextAlert(m.alertCh))

	case LogMsg:
		next, cmd := m.forward(msg)
		return next, tea.Batch(cmd, m.cmds.nextLog(m.logCh))

	case TickMsg:
		// The roster fetch rides the same clock as the status poll: it is
		// what keeps uptime and event counters moving, since the roster
		// STREAM only fires when the roster's shape changes and carries no
		// stats at all.
		return m, tea.Batch(m.cmds.status(), m.cmds.roster(), m.cmds.tick())

	case RetryMsg:
		// A timer that fired after core came back is a straggler: acting on
		// it would restart a chain nobody is waiting for, and move a counter
		// that has already been reset.
		if !m.stale {
			return m, nil
		}
		m.retries = msg.Attempt
		// Arm the NEXT attempt here. Without this the chain fired exactly
		// once and stopped — lost() will not re-arm it, because it sees
		// retrying already true — leaving reconnection to the fixed 2s
		// status tick and freezing the header on "retrying" forever.
		return m, tea.Batch(m.cmds.watchRoster(), m.cmds.status(), m.cmds.retry(msg.Attempt))

	case ConnectedMsg:
		// Swapping in a whole new commands rather than assigning its session
		// keeps the goroutines that read it from racing the assignment.
		m.cmds = m.cmds.with(msg.S)
		m.connected = true
		m = m.recovered()
		next, cmd := m.forward(msg)
		return next, tea.Batch(cmd, m.cmds.start())

	case ConnectFailedMsg:
		m.retries = msg.Attempt
		m.stale = true
		m.retrying = true
		m.staleMsg = unreachableAt(m.cmds.target())
		next, cmd := m.forward(StatusMsg{Status: vc.Status{Addr: m.cmds.target()}})
		return next, tea.Batch(cmd, m.cmds.connect(msg.Attempt))

	case NoticeMsg:
		m.notice = msg.Text
		// A notice is the acknowledgement of something the user did, which
		// is exactly what the action log records. Hanging it off NoticeMsg
		// rather than off each handler means a new action gets logged for
		// free the moment it reports itself.
		m.alog.add(msg.Text, false, msg.At)
		return m.forward(msg)

	case ErrMsg:
		return m.handleErr(msg)
	}

	return m.forward(msg)
}

// reselect swaps in a new sidebar list and keeps the cursor on the subject it
// was already on. It takes the new list rather than reading a field the caller
// already overwrote: the wanted subject has to be resolved against the OLD
// rows, or the old index is looked up in the new list and the cursor silently
// lands on whichever row inherited it.
//
// A plugin that disappeared goes to ALL through retune, not by assignment:
// the view it was showing is a tail on a plugin that no longer exists, and
// only retune cancels it. Skipping that leaks one tailer per roster shrink.
func (m model) reselect(next []Subject) (model, tea.Cmd) {
	want := m.subject()
	m.subjects = next

	for i, s := range next {
		if s.Kind == want.Kind && s.ID == want.ID {
			m.subjIdx = i
			return m, nil
		}
	}

	m.subjIdx = 0
	m.tabIdx = 0
	tuned, cmd := m.retune()
	return tuned.(model), cmd
}

func (m model) recovered() model {
	m.stale = false
	m.staleMsg = ""
	m.retries = 0
	m.retrying = false
	return m
}

// lost handles a status poll that found core gone. It exists because
// Session.Status reports unreachability in its RESULT rather than as an
// error — "gRPC up, kernel down" is a real state a status view must still
// print — so a model that only reacts to ErrMsg never learns core is
// missing. WatchRoster reconnects internally and never surfaces one either,
// which is how the TUI came to sit there claiming core had simply found no
// plugins.
//
// The retry clock is armed on the TRANSITION only. Status is re-polled every
// pollInterval, so arming per message would stack a timer every two seconds
// and turn the backoff into a busy loop that speeds up the longer core stays
// down — the opposite of what backoff is for.
func (m model) lost(msg StatusMsg) (tea.Model, tea.Cmd) {
	armed := m.retrying

	m.stale = true
	m.retrying = true
	m.staleMsg = unreachableAt(msg.Status.Addr)
	m.rosterCh = nil

	next, cmd := m.forward(msg)
	if armed {
		return next, cmd
	}
	return next, tea.Batch(cmd, m.cmds.retry(m.retries))
}

// unreachableAt names the address so the user can see WHERE this client
// looked, which is the difference between "core is down" and "you pointed me
// at the wrong port".
func unreachableAt(addr string) string {
	if addr == "" {
		return "core unreachable"
	}
	return "core unreachable at " + addr
}

// handleErr splits the two kinds of failure. Core being gone degrades the
// whole UI and starts the reconnect clock; one call failing is a notice.
func (m model) handleErr(msg ErrMsg) (tea.Model, tea.Cmd) {
	if msg.Err == nil {
		return m, nil
	}
	if !unreachable(msg.Err) {
		m.notice = msg.Err.Error()
		return m.forward(msg)
	}

	armed := m.retrying

	m.stale = true
	m.retrying = true
	m.staleMsg = msg.Err.Error()
	m.rosterCh = nil

	next, cmd := m.forward(msg)
	// Same one-clock rule as lost(): an ErrMsg and a failing status poll can
	// describe the same outage, and two arming paths must not become two
	// timers.
	if armed {
		return next, cmd
	}
	return next, tea.Batch(cmd, m.cmds.retry(m.retries))
}

func (m model) alertCmd(a vc.Alert) tea.Cmd {
	if m.muted {
		return nil
	}
	return m.cmds.notifyAlert(a)
}

// forward hands a message to the focused pane. The root handles chrome; the
// pane handles content, and it sees every message either way so a background
// pane is never stale when it comes back into focus.
func (m model) forward(msg tea.Msg) (tea.Model, tea.Cmd) {
	if m.pane == nil {
		return m, nil
	}
	p, cmd := m.pane.Update(msg)
	if p != nil {
		m.pane = p
	}
	return m, cmd
}

func (m model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	k := msg.String()
	b, bound := keymap.Lookup(m.keyCtx(), m.subject().Kind, m.focus, k)

	// Help is modal: it is a reading surface, so only the keys that close
	// it do anything.
	if m.help {
		if bound && (b.Action == keymap.ActionCancel || b.Action == keymap.ActionHelp) {
			m.help = false
		}
		if bound && b.Action == keymap.ActionQuit {
			return m, tea.Quit
		}
		return m, nil
	}

	// The transient is which-key: any key dismisses it, and a bound key
	// also runs. Leaving it up after an unknown key would trap the user in
	// a popup they cannot read their way out of.
	if m.tr.open {
		m.tr.open = false
		if !bound || b.Action == keymap.ActionCancel || b.Action == keymap.ActionTransient {
			return m, nil
		}
		return m.act(b)
	}

	if !bound {
		return m.forward(msg)
	}
	return m.act(b)
}

func (m model) act(b keymap.Binding) (tea.Model, tea.Cmd) {
	if i, ok := keymap.TabIndex(b.Action); ok {
		return m.selectTab(i)
	}

	switch b.Action {
	case keymap.ActionQuit:
		m.scope.close()
		return m, tea.Quit

	case keymap.ActionHelp:
		m.help = !m.help
		return m, nil

	case keymap.ActionTransient:
		m.tr.open = true
		return m, nil

	case keymap.ActionCancel:
		// Ordering matters and is split across two places: handleKey has
		// already dealt with help and the transient, so anything reaching
		// here has no modal open. A notice is dismissed first — it is the
		// most recent thing the user saw — and only then does esc mean
		// "leave the panel".
		if m.notice != "" {
			m.notice = ""
			return m, nil
		}
		if m.focus == keymap.FocusDetail {
			m.focus = keymap.FocusSidebar
		}
		return m, nil

	case keymap.ActionZoom:
		m.zoom = !m.zoom
		return m, nil

	case keymap.ActionActionLog:
		m.alog.open = !m.alog.open
		return m, nil

	case keymap.ActionFocusDetail:
		m.focus = keymap.FocusDetail
		return m, nil

	case keymap.ActionFocusSidebar:
		m.focus = keymap.FocusSidebar
		return m, nil

	case keymap.ActionTabNext:
		return m.selectTab(m.tabIdx + 1)

	case keymap.ActionTabPrev:
		return m.selectTab(m.tabIdx - 1)

	case keymap.ActionSubjectNext:
		return m.selectSubject(m.subjIdx + 1)

	case keymap.ActionSubjectPrev:
		return m.selectSubject(m.subjIdx - 1)

	case keymap.ActionRefresh:
		return m, m.cmds.status()

	case keymap.ActionAlertMute:
		m.muted = !m.muted
		return m, nil

	case keymap.ActionPluginRebuild:
		s := m.subject()
		if s.Kind != SubjectPlugin {
			return m, nil
		}
		m.notice = "rebuilding " + s.ID
		return m, m.rebuildCmd(s.ID)

	case keymap.ActionPluginUI:
		s := m.subject()
		if s.Kind != SubjectPlugin {
			return m, nil
		}
		return m, m.cmds.openPluginUI(s.ID)

	case keymap.ActionPluginRestart:
		s := m.subject()
		if s.Kind != SubjectPlugin {
			return m, nil
		}
		m.notice = "restarting " + s.ID
		return m, m.cmds.restart(s.ID)
	}

	// Anything the chrome does not own belongs to the pane. It sees the
	// resolved action, not the key, so the binding stays declared once.
	return m.forward(ActionMsg{Action: b.Action})
}

func (m model) selectTab(i int) (tea.Model, tea.Cmd) {
	n := len(m.tabs())
	if n == 0 {
		return m, nil
	}
	i = ((i % n) + n) % n
	if i == m.tabIdx {
		return m, nil
	}
	m.tabIdx = i
	return m.retune()
}

func (m model) selectSubject(i int) (tea.Model, tea.Cmd) {
	n := len(m.subjects)
	if n == 0 {
		return m, nil
	}
	i = ((i % n) + n) % n
	if i == m.subjIdx {
		return m, nil
	}
	m.subjIdx = i
	// Tabs are facets of the subject, so a new subject starts at its first
	// facet rather than at whatever index the old one left behind.
	m.tabIdx = 0
	return m.retune()
}

// retune is the one place a view is torn down and rebuilt. Cancelling first
// is the point: whatever the previous view was tailing stops here, not
// whenever its goroutine notices.
func (m model) retune() (tea.Model, tea.Cmd) {
	m.scope.close()
	m.scope = &viewScope{}
	// Dropping the handle is what stops the log re-arm loop; the goroutine
	// behind it is already being cancelled above.
	m.logCh = nil

	subj := m.subject()
	tabs := m.tabs()
	if m.tabIdx >= len(tabs) {
		m.tabIdx = 0
	}
	ctx := tabs[m.tabIdx].Ctx

	pctx := PaneCtx{Subject: subj, Theme: m.theme}
	m.pane = paneFor(subj.Kind, ctx, pctx)

	cmds := []tea.Cmd{m.pane.Init(pctx), m.cmds.view(m.scope, subj, ctx)}

	// A freshly built pane knows nothing, and "nothing" is not neutral: its
	// zero vc.Status has Reachable false, so an uninformed pane does not
	// stay quiet, it actively reports that core is down. Replaying what the
	// model already knows closes that window, which would otherwise last
	// until the next poll — long enough to read, and wrong.
	//
	// Only seed what has actually been learned. Replaying a zero Status
	// would assert the very thing this is here to prevent.
	seed := make([]tea.Msg, 0, 3)
	if m.width > 0 {
		seed = append(seed, tea.WindowSizeMsg{Width: m.width, Height: m.height})
	}
	if m.connected {
		seed = append(seed, StatusMsg{Status: m.status}, RosterMsg{Roster: m.roster})
	}
	for _, msg := range seed {
		next, cmd := m.forward(msg)
		m = next.(model)
		cmds = append(cmds, cmd)
	}
	return m, tea.Batch(cmds...)
}

func (m model) View() string {
	if m.width <= 0 || m.height <= 0 {
		return ""
	}

	// The action-log strip is chrome, so it comes out of the body's budget
	// before anything is laid out. Expanding it shrinks the pane rather than
	// overflowing the terminal.
	barH := m.alog.height()
	body := m.height - headerLines - footerLines - barH
	if body < 1 {
		body = 1
	}

	sw := m.sidebarWidth()
	detail := m.detailView(m.width-sw, body)
	row := detail
	if sw > 0 {
		row = lipgloss.JoinHorizontal(lipgloss.Top, m.sidebarView(sw, body), detail)
	}

	out := lipgloss.JoinVertical(lipgloss.Left,
		m.headerView(m.width),
		row,
		m.alog.render(m.width, m.theme),
		renderFooter(m.keyCtx(), m.focus, m.width, m.theme),
	)
	return clamp(out, m.width, m.height)
}

// retrySuffix reports that the client is still trying, and how hard. Without
// it a red banner reads as "give up and restart me", when in fact the TUI
// reconnects on its own and is meant to be left open across a `just run`.
func (m model) retrySuffix() string {
	if !m.stale {
		return ""
	}
	if m.retries == 0 {
		return " — retrying"
	}
	return fmt.Sprintf(" — retrying in %s (attempt %d)", retryDelay(m.retries), m.retries)
}

// headerView answers "is this screen telling me the truth" in one line: red
// and loud when core is unreachable, quiet with the version when it is not.
func (m model) headerView(w int) string {
	left := m.theme.Title.Render("vibecare")

	// Facts as label:value pairs rather than a bare run of values. The
	// labels cost a few columns and buy the reader not having to know that
	// the third field is a plugin tally — a header that needs decoding is a
	// header that gets ignored.
	var right string
	switch {
	case m.stale:
		right = m.theme.HeaderBad.Render(m.staleMsg + m.retrySuffix())
	case m.notice != "":
		right = m.theme.Warn.Render(m.notice)
	default:
		t := m.roster.Tally()
		facts := [][2]string{}
		if m.status.Version != "" {
			facts = append(facts, [2]string{"version", m.status.Version})
		}
		if addr := m.status.Addr; addr != "" {
			facts = append(facts, [2]string{"core", addr})
		}
		facts = append(facts, [2]string{"plugins", fmt.Sprintf("%d/%d up", t.Up, t.Total)})

		parts := make([]string, 0, len(facts))
		for _, f := range facts {
			parts = append(parts, m.theme.Dim.Render(f[0]+":")+m.theme.Item.Render(f[1]))
		}
		right = strings.Join(parts, m.theme.Dim.Render(" — "))
	}

	gap := w - lipgloss.Width(left) - lipgloss.Width(right)
	if gap < 1 {
		return clamp(left+" "+right, w, 1)
	}
	return left + strings.Repeat(" ", gap) + right
}

// detailView is the 80 % side: tabs, the active pane's chips, then the pane.
func (m model) detailView(w, h int) string {
	if w < 1 {
		w = 1
	}
	// A gutter between the rule and the content. Without it the first
	// character of every line sits against the divider, which reads as the
	// two columns having collided rather than as a boundary between them.
	// Taken out of the width so nothing overflows: the pane is told the
	// space it actually has.
	gutter := ""
	if w > gutterCols {
		gutter = strings.Repeat(" ", gutterCols)
		w -= gutterCols
	}

	contentH := h - chromeLines
	if contentH < 1 {
		contentH = 1
	}

	var content string
	switch {
	case m.help:
		content = renderHelp(m.subjectLabel(), m.keyCtx(), m.subject().Kind, m.focus, w, contentH, m.theme)
	case m.tr.open:
		// The popup replaces the pane rather than floating over it:
		// compositing styled text needs ANSI-aware splicing, and the popup
		// is modal anyway — nothing under it can be acted on.
		box := renderTransient(m.subjectLabel(), keymap.For(m.keyCtx(), m.subject().Kind, m.focus), w, contentH, m.theme)
		content = lipgloss.Place(w, contentH, lipgloss.Center, lipgloss.Center, box)
	default:
		content = m.pane.View(w, contentH)
	}

	block := lipgloss.JoinVertical(lipgloss.Left,
		renderTabs(m.tabs(), m.tabIdx, m.subjectLabel(), w, m.theme),
		renderChips(m.pane.Chips(), w, m.theme),
		clamp(content, w, contentH),
	)
	if gutter == "" {
		return block
	}
	lines := strings.Split(block, "\n")
	for i, l := range lines {
		lines[i] = gutter + l
	}
	return strings.Join(lines, "\n")
}

// subjectLabel is what the subject is called on screen. ALL is upper case
// because it is a scope, not a name.
func (m model) subjectLabel() string {
	s := m.subject()
	switch s.Kind {
	case SubjectAll:
		return "ALL"
	case SubjectCore:
		return coreID
	}
	return s.ID
}

// clamp is the one truncation primitive the chrome uses. lipgloss does it
// ANSI-aware, so a styled line is cut at the right column rather than in the
// middle of an escape sequence.
func clamp(s string, w, h int) string {
	if w <= 0 || h <= 0 {
		return ""
	}
	return lipgloss.NewStyle().MaxWidth(w).MaxHeight(h).Render(s)
}
