package tui

import (
	"context"
	"errors"
	"sync/atomic"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/vibecare-io/vibecare/clients/cli/internal/browser"
	"github.com/vibecare-io/vibecare/clients/cli/internal/logtail"
	"github.com/vibecare-io/vibecare/clients/cli/internal/notify"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// This file is the only one in package tui that talks to core, follows a
// file, or draws a desktop notification (§4.3 of the design). Everything
// else in the package is a pure function of messages, which is why the tests
// need neither a backend nor a terminal. A test asserts the rule rather than
// trusting it.

const (
	// pollInterval matches the kernel-stats cadence the design specifies.
	// Only views that need those counters are refreshed on it.
	pollInterval = 2 * time.Second

	// tailLines is how much history a log view opens with. Enough to show
	// why something died; small enough to render instantly.
	tailLines = 500
)

// backoff is the reconnect schedule. It comes from vc so the TUI's automatic
// reconnect and the CLI's --wait behave identically: core restarting under
// `just run` is back within a second, so it starts fast, and a core that is
// gone for good settles to one dial every few seconds rather than spinning.
var backoff = vc.DefaultBackoff

// Options is what the caller configures the TUI with.
type Options struct {
	// Notifier bridges alerts to the desktop. Nil means the user did not
	// ask for notifications, and nothing pops.
	Notifier notify.Notifier

	// Dial opens a new session. The TUI is started with a nil session when
	// core is down — a dead core is a state to render, not a reason to
	// refuse to start — and this is how it gets out of that state without
	// the user quitting and re-running. Nil means no reconnect is possible,
	// which is only true in tests.
	Dial func(context.Context) (*vc.Session, error)

	// Addr is the target, purely so the UI can name what it cannot reach.
	// With a nil session there is no Session to ask.
	Addr string
}

// Run starts the TUI against an open session and blocks until the user
// quits or ctx is cancelled.
//
// It lives in cmds.go rather than app.go because this is the one place a
// session enters the package; app.go stays free of it, and the layering
// test can be a single grep.
func Run(ctx context.Context, s *vc.Session, opts Options) error {
	ctx, cancel := context.WithCancel(ctx)
	// Cancelling on the way out is what stops the roster, alert and log
	// goroutines; bubbletea returning does not stop them by itself.
	defer cancel()

	n := opts.Notifier
	if n == nil {
		n = notify.Noop()
	}

	c := &commands{ctx: ctx, s: s, notifier: n, dial: opts.Dial, addr: opts.Addr}
	p := tea.NewProgram(newModel(c, opts), tea.WithAltScreen(), tea.WithContext(ctx))
	_, err := p.Run()
	return err
}

// commands owns the session and produces every tea.Cmd. A nil *commands is
// a working no-op — the tests drive the whole model through one — so the
// model never guards its call sites.
type commands struct {
	ctx      context.Context
	s        *vc.Session
	notifier notify.Notifier
	dial     func(context.Context) (*vc.Session, error)
	addr     string
}

func (c *commands) live() bool { return c != nil && c.s != nil }

// target names what this client is pointed at, for the messages shown when
// it cannot reach it.
func (c *commands) target() string {
	if c == nil {
		return ""
	}
	return c.addr
}

// with returns a copy carrying a newly-dialled session. It replaces the
// struct rather than assigning c.s in place: commands is read from the
// goroutines every tea.Cmd runs on, and mutating a field they are reading is
// a data race the race detector would find on the first reconnect.
func (c *commands) with(s *vc.Session) *commands {
	if c == nil {
		return nil
	}
	next := *c
	next.s = s
	return &next
}

// connect dials after a backoff delay. This is the path out of a TUI that
// was started with no session at all, which is what happens whenever core is
// down when the user runs `vibecare`: the UI comes up, says so, and keeps
// trying, so a `just run` in another pane is picked up without the user
// having to quit and start again.
func (c *commands) connect(attempt int) tea.Cmd {
	if c == nil || c.dial == nil {
		return nil
	}
	return tea.Tick(backoff.Delay(attempt), func(time.Time) tea.Msg {
		s, err := c.dial(c.ctx)
		if err != nil {
			return ConnectFailedMsg{Attempt: attempt + 1, Err: err}
		}
		return ConnectedMsg{S: s}
	})
}

// stream is one long-lived source plus the single-reader guard that keeps
// re-arming honest.
//
// The failure this prevents: a view is switched while a read is in flight,
// the model re-arms the new handle, and the old read completes and re-arms
// too — one extra reader per switch, forever. armed makes a handle refuse a
// second concurrent read, so the count is bounded at one per generation and
// a superseded generation simply stops when its channel closes.
type stream[T any] struct {
	ch    <-chan T
	armed atomic.Bool
}

// recv reads one value and wraps it as a message. It returns nil — no
// command at all — when the handle is already being read or has finished,
// which is how a cancelled generation goes quiet.
func recv[T any](ctx context.Context, s *stream[T], wrap func(T) tea.Msg) tea.Cmd {
	if s == nil || !s.armed.CompareAndSwap(false, true) {
		return nil
	}
	return func() tea.Msg {
		defer s.armed.Store(false)
		select {
		case <-ctx.Done():
			return nil
		case v, ok := <-s.ch:
			if !ok {
				return nil
			}
			return wrap(v)
		}
	}
}

// start opens the streams that live as long as the session: the roster and
// the alert feed. Neither is tied to a view, so neither is cancelled by
// switching one.
func (c *commands) start() tea.Cmd {
	if !c.live() {
		return nil
	}
	return tea.Batch(c.watchRoster(), c.watchAlerts(), c.watchEvents(), c.status(), c.tick())
}

func (c *commands) watchRoster() tea.Cmd {
	if !c.live() {
		return nil
	}
	return func() tea.Msg {
		ch, err := c.s.WatchRoster(c.ctx)
		if err != nil {
			return ErrMsg{Err: err}
		}
		return RosterStreamMsg{S: &stream[vc.Roster]{ch: ch}}
	}
}

func (c *commands) nextRoster(s *stream[vc.Roster]) tea.Cmd {
	if !c.live() {
		return nil
	}
	return recv(c.ctx, s, func(r vc.Roster) tea.Msg { return RosterMsg{Roster: r} })
}

func (c *commands) watchAlerts() tea.Cmd {
	if !c.live() {
		return nil
	}
	return func() tea.Msg {
		ch, err := c.s.WatchAlerts(c.ctx)
		if err != nil {
			return ErrMsg{Err: err}
		}
		return AlertStreamMsg{S: &stream[vc.Alert]{ch: ch}}
	}
}

// watchEvents opens the bus firehose. It is a session-lifetime stream like
// the roster and alerts, not a per-view one: the events keep arriving while
// you are on another tab, so switching away and back does not leave a hole
// in the record you were watching.
func (c *commands) watchEvents() tea.Cmd {
	if !c.live() {
		return nil
	}
	return func() tea.Msg {
		ch, err := c.s.WatchEvents(c.ctx)
		if err != nil {
			// The firehose is a diagnostic, not the UI's reason to exist:
			// a kernel that cannot serve it should not turn the whole
			// client red.
			return nil
		}
		return EventStreamMsg{S: &stream[vc.Event]{ch: ch}}
	}
}

func (c *commands) nextEvent(s *stream[vc.Event]) tea.Cmd {
	if !c.live() {
		return nil
	}
	return recv(c.ctx, s, func(e vc.Event) tea.Msg { return EventMsg{Event: e} })
}

func (c *commands) nextAlert(s *stream[vc.Alert]) tea.Cmd {
	if !c.live() {
		return nil
	}
	return recv(c.ctx, s, func(a vc.Alert) tea.Msg { return AlertMsg{Alert: a} })
}

func (c *commands) nextLog(s *stream[logtail.Line]) tea.Cmd {
	if !c.live() {
		return nil
	}
	return recv(c.ctx, s, func(l logtail.Line) tea.Msg { return LogMsg{Line: l} })
}

func (c *commands) status() tea.Cmd {
	if !c.live() {
		return nil
	}
	return func() tea.Msg {
		st, err := c.s.Status(c.ctx)
		if err != nil {
			return ErrMsg{Err: err}
		}
		return StatusMsg{Status: st}
	}
}

func (c *commands) tick() tea.Cmd {
	if !c.live() {
		return nil
	}
	return tea.Tick(pollInterval, func(time.Time) tea.Msg { return TickMsg{} })
}

// retryDelay is the backoff schedule, kept separate from the command so the
// header can show the user the same number the timer will actually use.
//
// It delegates to vc so the TUI's reconnect and the CLI's --wait spend their
// budget identically. Two copies of a backoff schedule drift, and the one
// that drifts is always the one nobody is watching.
func retryDelay(attempt int) time.Duration {
	return backoff.Delay(attempt)
}

// retry schedules the next reconnect attempt. The delay doubles per attempt
// and caps, so a core that never comes back costs one dial every few seconds
// rather than a busy loop.
//
// It deliberately does NOT require a live session. Arming a timer touches
// nothing; everything the timer goes on to trigger — watchRoster, status —
// guards itself. Requiring one here meant the schedule was silently skipped
// in exactly the state it exists for, and made the whole chain untestable
// without a backend.
func (c *commands) retry(attempt int) tea.Cmd {
	if c == nil {
		return nil
	}
	next := attempt + 1
	return tea.Tick(retryDelay(attempt), func(time.Time) tea.Msg { return RetryMsg{Attempt: next} })
}

// roster fetches the roster ENRICHED with the kernel's HTTP stats. The
// difference from watchRoster matters: the stream carries identity and state
// only, so a client that reads it alone can never show a pid, an uptime or
// an event counter — every stats-gated render takes its "not measured"
// branch forever. Session.Roster is the only path that sets Plugin.Stats,
// and this is the only caller of it in the TUI.
//
// It is a poll rather than a stream because the numbers it carries — uptime
// above all — change continuously while the roster itself changes almost
// never.
func (c *commands) roster() tea.Cmd {
	if !c.live() {
		return nil
	}
	return func() tea.Msg {
		r, err := c.s.Roster(c.ctx)
		if err != nil {
			// Stats are a nicety; losing them is not worth a red banner.
			// Genuine unreachability is reported by the status poll, which
			// owns that decision for the whole UI.
			return nil
		}
		return RosterMsg{Roster: r}
	}
}

func (c *commands) restart(id string) tea.Cmd {
	if !c.live() {
		return nil
	}
	return func() tea.Msg {
		if err := c.s.RestartPlugin(c.ctx, id); err != nil {
			return ErrMsg{Err: err}
		}
		return NoticeMsg{Text: "restarting " + id, At: time.Now()}
	}
}

// openPluginUI resolves a plugin's authenticated URL and hands it to the
// desktop. Both halves live here rather than in a pane because both are I/O:
// the URL needs the kernel origin and the session token, and opening it
// execs a program.
func (c *commands) openPluginUI(id string) tea.Cmd {
	if !c.live() {
		return nil
	}
	return func() tea.Msg {
		u, err := c.s.PluginURL(c.ctx, id)
		if err != nil {
			return ErrMsg{Err: err}
		}
		if err := browser.Open(c.ctx, u); err != nil {
			return ErrMsg{Err: vc.Wrap(err, "open %s in a browser", id)}
		}
		// The notice deliberately omits the URL: it contains a live session
		// token and the header is the one part of the screen that ends up in
		// screenshots and screen shares.
		return NoticeMsg{Text: "opened " + id + " in your browser", At: time.Now()}
	}
}

// notifyAlert bridges one alert to the desktop. Action buttons have no
// portable desktop equivalent, so the alert is flattened on the way out.
func (c *commands) notifyAlert(a vc.Alert) tea.Cmd {
	if c == nil || c.notifier == nil {
		return nil
	}
	return func() tea.Msg {
		n := notify.Notification{Title: a.Title, Body: a.Body, Level: a.Level}
		if err := c.notifier.Notify(c.ctx, n); err != nil {
			return ErrMsg{Err: err}
		}
		return nil
	}
}

// view starts whatever the newly selected subject and tab need, and records
// the cancel for it in scope. The model closes that scope before calling
// this again, which is the whole of the "switching view must not leak
// goroutines" rule.
func (c *commands) view(scope *viewScope, s Subject, k keymap.Ctx) tea.Cmd {
	if !c.live() || scope == nil {
		return nil
	}

	ctx, cancel := context.WithCancel(c.ctx)
	switch k {
	case keymap.CtxLogs:
		scope.cancel = cancel
		return c.tailLogs(ctx, s)
	case keymap.CtxSchedules:
		scope.cancel = cancel
		return c.schedules(ctx, s)
	case keymap.CtxRoutines:
		scope.cancel = cancel
		return c.routines(ctx, s)
	case keymap.CtxActions:
		scope.cancel = cancel
		return c.actions(ctx, s)
	}
	// Nothing was started, so nothing must be left holding a live context.
	cancel()
	return nil
}

func (c *commands) tailLogs(ctx context.Context, s Subject) tea.Cmd {
	return func() tea.Msg {
		sources, err := c.logSources(ctx, s)
		if err != nil {
			return ErrMsg{Err: err}
		}
		ch, err := logtail.Merge(ctx, sources, logtail.Options{Follow: true, Tail: tailLines})
		if err != nil {
			return ErrMsg{Err: err}
		}
		return LogStreamMsg{S: &stream[logtail.Line]{ch: ch}}
	}
}

// logSources resolves what the subject means in terms of files. Paths always
// come from the session — the client never rebuilds a log path from a
// convention, so changing where core writes them breaks nothing here.
func (c *commands) logSources(ctx context.Context, s Subject) ([]logtail.Source, error) {
	if s.Kind == SubjectAll {
		srcs, err := c.s.LogSources(ctx)
		if err != nil {
			return nil, err
		}
		out := make([]logtail.Source, 0, len(srcs))
		for _, src := range srcs {
			out = append(out, logtail.Source{ID: src.ID, Path: src.Path})
		}
		if len(out) == 0 {
			return nil, errors.New("no log sources")
		}
		return out, nil
	}

	id := s.ID
	if s.Kind == SubjectCore {
		id = coreID
	}
	src, err := c.s.LogSource(ctx, id)
	if err != nil {
		return nil, err
	}
	return []logtail.Source{{ID: src.ID, Path: src.Path}}, nil
}

func (c *commands) schedules(ctx context.Context, s Subject) tea.Cmd {
	return func() tea.Msg {
		list, err := c.s.ListSchedules(ctx, vc.ScheduleFilter{})
		if err != nil {
			return ErrMsg{Err: err}
		}
		return SchedulesMsg{Schedules: list}
	}
}

func (c *commands) routines(ctx context.Context, s Subject) tea.Cmd {
	return func() tea.Msg {
		list, err := c.s.ListRoutines(ctx, "")
		if err != nil {
			return ErrMsg{Err: err}
		}
		return RoutinesMsg{Routines: list}
	}
}

func (c *commands) actions(ctx context.Context, s Subject) tea.Cmd {
	return func() tea.Msg {
		list, err := c.s.ListActions(ctx, "")
		if err != nil {
			return ErrMsg{Err: err}
		}
		return ActionsMsg{Actions: list}
	}
}

// unreachable reports whether an error means core itself is gone, as opposed
// to one call failing. Only the former degrades the whole UI.
func unreachable(err error) bool {
	return err != nil && vc.ExitCode(err) == vc.ExitUnreachable
}

// ConnectedMsg carries a session that was dialled after the TUI had already
// started. It only ever appears when the client came up with core down.
type ConnectedMsg struct{ S *vc.Session }

// ConnectFailedMsg reports one failed reconnect attempt and the attempt
// number, which is what the header counts and what sizes the next backoff.
type ConnectFailedMsg struct {
	Attempt int
	Err     error
}
