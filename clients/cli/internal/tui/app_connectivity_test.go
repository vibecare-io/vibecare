package tui

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// blankModel is a sized model that has NEVER received a roster. testModel
// seeds one, which would hide exactly the bug these tests are about: a
// client that has not heard from core yet must not be indistinguishable
// from one that heard "nothing here".
func blankModel() model {
	return step(newModel(nil, Options{}), tea.WindowSizeMsg{Width: 120, Height: 40})
}

// The TUI learns core is gone from Status.Reachable, NOT from an error.
// Session.Status deliberately returns a nil error and encodes unreachability
// in the struct, because "gRPC up, kernel down" is a real state a status
// command must still print. That makes Reachable the only signal the TUI
// gets: WatchRoster reconnects internally and never surfaces an ErrMsg, so a
// model that waits for one waits forever and keeps claiming everything is
// fine.
func TestUnreachableStatusGoesStale(t *testing.T) {
	m := step(blankModel(), StatusMsg{Status: vc.Status{Addr: "127.0.0.1:59999"}})

	if !m.stale {
		t.Fatal("stale = false after an unreachable StatusMsg; the UI is still claiming core is fine")
	}
	if !strings.Contains(m.staleMsg, "unreachable") {
		t.Errorf("staleMsg = %q, want it to say core is unreachable", m.staleMsg)
	}
	if !strings.Contains(m.staleMsg, "127.0.0.1:59999") {
		t.Errorf("staleMsg = %q, want the address so the user can see WHERE it looked", m.staleMsg)
	}
}

// A reachable status after an unreachable one must clear the banner and reset
// the backoff, so the reconnect clock does not stay wound up at ten seconds
// for the rest of the session.
func TestReachableStatusRecovers(t *testing.T) {
	m := step(blankModel(),
		StatusMsg{Status: vc.Status{Addr: "a"}},
		RetryMsg{Attempt: 4},
		StatusMsg{Status: vc.Status{Addr: "a", Reachable: true}},
	)

	if m.stale {
		t.Error("stale = true after core came back")
	}
	if m.retries != 0 {
		t.Errorf("retries = %d after recovery, want 0 so the next outage starts at the base delay", m.retries)
	}
}

// The retry clock is armed on the TRANSITION into unreachable, not on every
// poll. Status is re-polled every pollInterval, so re-arming per message
// would stack one timer every two seconds and turn the backoff into a busy
// loop that gets faster the longer core stays down.
func TestRetryArmsOnceNotPerPoll(t *testing.T) {
	// Asserted on model state rather than the returned tea.Cmd: with no
	// session every command is a no-op nil, so the cmd cannot distinguish
	// "armed" from "declined to arm". retrying is the guard itself.
	m := step(blankModel(), StatusMsg{Status: vc.Status{Addr: "a"}})
	if !m.retrying {
		t.Fatal("retrying = false after the first unreachable status; the reconnect clock never started")
	}

	before := m.retries
	m = step(m, StatusMsg{Status: vc.Status{Addr: "a"}}, StatusMsg{Status: vc.Status{Addr: "a"}})
	if m.retries != before {
		t.Errorf("retries moved from %d to %d on repeat polls; the backoff is being driven by the poll clock, not by attempts", before, m.retries)
	}

	// And the clock stops on recovery, so the next outage starts at base.
	m = step(m, StatusMsg{Status: vc.Status{Addr: "a", Reachable: true}})
	if m.retrying {
		t.Error("retrying = true after core came back; the clock was never stopped")
	}
}

// Three states that must never be conflated. The middle one is a statement
// about core's plugins directory and is only true once core has answered.
func TestOverviewSeparatesUnreachableFromEmpty(t *testing.T) {
	tests := []struct {
		name    string
		msgs    []any
		want    string
		notWant string
	}{
		{
			name:    "never connected",
			msgs:    []any{StatusMsg{Status: vc.Status{Addr: "127.0.0.1:59999"}}},
			want:    "unreachable",
			notWant: "no plugins discovered",
		},
		{
			name: "connected, genuinely empty",
			msgs: []any{
				StatusMsg{Status: vc.Status{Addr: "a", Reachable: true}},
				RosterMsg{Roster: vc.Roster{}},
			},
			want:    "no plugins discovered",
			notWant: "unreachable",
		},
		{
			name: "connected, then lost",
			msgs: []any{
				StatusMsg{Status: vc.Status{Addr: "a", Reachable: true}},
				RosterMsg{Roster: testRoster()},
				StatusMsg{Status: vc.Status{Addr: "a"}},
			},
			want:    "unreachable",
			notWant: "no plugins discovered",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			m := blankModel()
			for _, msg := range tc.msgs {
				m = step(m, msg)
			}
			got := m.pane.View(80, 24)

			if !strings.Contains(got, tc.want) {
				t.Errorf("view missing %q\n--- got ---\n%s", tc.want, got)
			}
			if strings.Contains(got, tc.notWant) {
				t.Errorf("view wrongly claims %q\n--- got ---\n%s", tc.notWant, got)
			}
		})
	}
}

// The header is the one line that answers "is this screen telling me the
// truth". While reconnecting it must say so and name the attempt, rather
// than showing a stale plugin tally as though it were live.
func TestHeaderShowsRetryState(t *testing.T) {
	m := step(blankModel(),
		StatusMsg{Status: vc.Status{Addr: "127.0.0.1:59999"}},
		RetryMsg{Attempt: 3},
	)

	got := m.headerView(100)
	for _, want := range []string{"unreachable", "retrying", "3"} {
		if !strings.Contains(got, want) {
			t.Errorf("header missing %q\n--- got ---\n%s", want, got)
		}
	}
}

// Kernel stats are gated on Plugin.Stats: false means "not measured", and
// rendering a zero there would be a fabricated measurement. True means the
// kernel's HTTP surface answered and the numbers are real.
func TestOverviewRendersStatsWhenMeasured(t *testing.T) {
	measured := vc.Roster{Plugins: []vc.Plugin{{
		ID: "todo", Name: "Todo", State: vc.StateUp,
		PID: 4403, UptimeSec: 754, Restarts: 2, EventsPublished: 3, Stats: true,
	}}}

	m := step(blankModel(),
		StatusMsg{Status: vc.Status{Addr: "a", Reachable: true}},
		RosterMsg{Roster: measured},
	)

	got := m.pane.View(120, 30)
	if !strings.Contains(got, "4403") {
		t.Errorf("measured stats not rendered; overview shows no pid\n--- got ---\n%s", got)
	}
	if strings.Contains(got, "stats unavailable") {
		t.Errorf("claims stats unavailable while Stats=true\n--- got ---\n%s", got)
	}
}

func TestOverviewDashesWhenUnmeasured(t *testing.T) {
	unmeasured := vc.Roster{Plugins: []vc.Plugin{{
		ID: "todo", Name: "Todo", State: vc.StateUp, Stats: false,
	}}}

	m := step(blankModel(),
		StatusMsg{Status: vc.Status{Addr: "a", Reachable: true}},
		RosterMsg{Roster: unmeasured},
	)

	// Assert on the plugin's own row, not the whole view: the tally line
	// legitimately contains zeros ("0 degraded"), and those are counts the
	// client computed itself rather than measurements it never took.
	var row string
	for _, l := range strings.Split(m.pane.View(120, 30), "\n") {
		if strings.HasPrefix(strings.TrimSpace(l), "todo") {
			row = l
		}
	}
	if row == "" {
		t.Fatal("no row for todo in the overview")
	}
	if !strings.Contains(row, "—") {
		t.Errorf("unmeasured stats not rendered as em dashes: %q", row)
	}
	if strings.Contains(row, "0") {
		t.Errorf("rendered a fabricated 0 for an unmeasured stat: %q", row)
	}
}

// The TUI is started with a nil session whenever core is down, because a
// dead core is a state to render rather than a reason to refuse to start.
// What must NOT happen is what used to: the window comes up inert, issues no
// commands at all, and would never notice core arriving.
func TestNoSessionKeepsTryingToConnect(t *testing.T) {
	var attempts int32
	c := &commands{
		ctx:  context.Background(),
		addr: "127.0.0.1:59999",
		dial: func(context.Context) (*vc.Session, error) {
			atomic.AddInt32(&attempts, 1)
			return nil, vc.Unreachable("127.0.0.1:59999", errors.New("connection refused"))
		},
	}
	m := step(newModel(c, Options{}), tea.WindowSizeMsg{Width: 120, Height: 40})

	if cmd := m.Init(); cmd == nil {
		t.Fatal("Init issued no command with a nil session; the TUI would sit there forever")
	}

	// Drive one failed attempt the way the runtime would.
	m2, cmd := m.Update(ConnectFailedMsg{Attempt: 1, Err: vc.Unreachable("127.0.0.1:59999", errors.New("refused"))})
	m = m2.(model)

	if !m.stale {
		t.Error("stale = false after a failed reconnect")
	}
	if m.retries != 1 {
		t.Errorf("retries = %d, want 1", m.retries)
	}
	if cmd == nil {
		t.Error("no follow-up command after a failed reconnect; the loop stopped")
	}
	if !strings.Contains(m.staleMsg, "127.0.0.1:59999") {
		t.Errorf("staleMsg = %q, want the address it could not reach", m.staleMsg)
	}
	// And the user is told what to do about it, not just that it is broken.
	view := m.pane.View(120, 30)
	for _, want := range []string{"just run", "server.log"} {
		if !strings.Contains(view, want) {
			t.Errorf("pane missing the %q hint\n--- got ---\n%s", want, view)
		}
	}
}

// Backoff must grow with the attempt, not restart from zero each time.
func TestReconnectBackoffGrows(t *testing.T) {
	if retryDelay(0) >= retryDelay(3) {
		t.Errorf("delay(0)=%s is not shorter than delay(3)=%s; the backoff is not backing off",
			retryDelay(0), retryDelay(3))
	}
	if retryDelay(99) != vc.DefaultBackoff.Max {
		t.Errorf("delay(99) = %s, want the cap %s", retryDelay(99), vc.DefaultBackoff.Max)
	}
}

// A pane built mid-session inherits what the model already knows. Without
// this it renders its zero vc.Status — whose Reachable is false — and spends
// up to a whole poll interval telling the user core is unreachable while it
// is answering perfectly well. Found by driving the real binary: select a
// plugin, press esc, press j, and core's Status tab reads "unreachable".
func TestNewPaneInheritsKnownState(t *testing.T) {
	m := step(testModel(120, 40),
		StatusMsg{Status: vc.Status{
			Addr: "127.0.0.1:50051", Reachable: true, Version: "dev",
			Scheduler: &vc.Scheduler{Running: true},
		}},
		RosterMsg{Roster: testRoster()},
	)

	// Move to core, which rebuilds the pane.
	m = step(m, key("]"))
	if m.subject().Kind != SubjectCore {
		t.Fatalf("setup: subject is %v, want core", m.subject().Kind)
	}

	got := m.pane.View(120, 30)
	if strings.Contains(got, "unreachable") {
		t.Errorf("a freshly built pane claims core is unreachable while it is up:\n%s", got)
	}
	if !strings.Contains(got, "127.0.0.1:50051") {
		t.Errorf("freshly built pane did not inherit the known status:\n%s", got)
	}
}
