package tui

import (
	"time"

	"github.com/vibecare-io/vibecare/clients/cli/internal/logtail"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// Every asynchronous thing that can happen to this TUI is one of the types
// below, declared here and nowhere else. A pane that wants new data waits
// for a message; it never reaches for a session. That is what keeps
// Update(msg) → (model, cmd) pure enough to table-test without a terminal.

// RosterMsg is a fresh plugin roster, pushed by Shell.Plugins. Its arrival
// is also proof that core is answering, so it clears the stale header.
type RosterMsg struct{ Roster vc.Roster }

// StatusMsg is the periodic whole-system snapshot.
type StatusMsg struct{ Status vc.Status }

// AlertMsg is one plugin intent from Shell.Intents.
type AlertMsg struct{ Alert vc.Alert }

// LogMsg is one line from whichever tail the current view started.
type LogMsg struct{ Line logtail.Line }

// SchedulesMsg and RoutinesMsg carry the results of a one-shot fetch made
// when a view that needs them was opened.
type SchedulesMsg struct{ Schedules []vc.Schedule }

type RoutinesMsg struct{ Routines []vc.Routine }

// ActionsMsg is the action list behind core's Actions tab.
type ActionsMsg struct{ Actions []vc.Action }

// ErrMsg is any failure worth telling the user about. An unreachable error
// additionally puts the whole UI into its degraded mode; everything else is
// a one-line notice.
type ErrMsg struct{ Err error }

// TickMsg is the poll clock for anything that has no stream behind it.
type TickMsg struct{}

// ActionMsg is a keymap binding the root model did not consume, handed to
// the focused pane. Panes switch on the action, never on the key, so the
// binding stays declared exactly once in package keymap.
type ActionMsg struct{ Action string }

// NoticeMsg is transient feedback for something the user just did
// ("restarting vibecheck"). It is not an error and does not mark anything
// stale.
type NoticeMsg struct {
	Text string
	// At is stamped by whoever produced the notice, not read from the clock
	// inside Update: the model stays a pure function of its messages, which
	// is what lets the action log be tested without freezing time.
	At time.Time
}

// EventMsg is one message published on core's bus. Unlike a log line it is
// what a plugin actually put on the wire, which is the only way to see one
// publishing a topic nobody subscribed to.
type EventMsg struct{ Event vc.Event }

// EventStreamMsg hands over the bus stream, the same way the roster and
// alert streams arrive.
type EventStreamMsg struct{ S *stream[vc.Event] }

// RetryMsg fires when the reconnect backoff elapses. Attempt is what the
// next delay is computed from, so the model does not have to remember it
// separately.
type RetryMsg struct{ Attempt int }

// The *StreamMsg types hand the model the handle to a newly opened stream.
// The model, not the commands, decides which generation it is reading from:
// when it swaps a handle out, the cmd that would have re-armed the old one
// finds nothing to re-arm, which is how switching subject or tab stops the
// previous view's goroutines from outliving it.
type RosterStreamMsg struct{ S *stream[vc.Roster] }

type AlertStreamMsg struct{ S *stream[vc.Alert] }

type LogStreamMsg struct{ S *stream[logtail.Line] }
