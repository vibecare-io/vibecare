package tui

import (
	"context"

	tea "github.com/charmbracelet/bubbletea"
	"testing"
	"time"

	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// scheduling is a model whose commands can schedule timers but has no
// session, so retry() produces a real tea.Cmd while every command that would
// touch core stays a no-op. That is exactly the seam needed to ask "did it
// arm the next attempt?" without a backend.
func scheduling(t *testing.T) model {
	t.Helper()
	m := newModel(&commands{ctx: context.Background(), addr: "127.0.0.1:50051"}, Options{})
	return step(m, tea.WindowSizeMsg{Width: 120, Height: 40})
}

// The bug in the screenshot: the header said "retrying" forever with no
// attempt and no delay, because the chain fired once and stopped. Each
// RetryMsg must schedule the next one, or the backoff is not a backoff — it
// is a single retry followed by silence.
func TestRetryChainKeepsGoing(t *testing.T) {
	m := scheduling(t)

	// Core goes away.
	next, cmd := m.Update(StatusMsg{Status: vc.Status{Addr: "127.0.0.1:50051"}})
	m = next.(model)
	if cmd == nil {
		t.Fatal("losing core scheduled nothing")
	}

	// Every subsequent attempt must arm the one after it.
	for attempt := 1; attempt <= 4; attempt++ {
		next, cmd = m.Update(RetryMsg{Attempt: attempt})
		m = next.(model)

		if m.retries != attempt {
			t.Fatalf("attempt %d: retries = %d", attempt, m.retries)
		}
		if cmd == nil {
			t.Fatalf("attempt %d produced no follow-up; the retry chain stopped", attempt)
		}
		if !m.retrying {
			t.Fatalf("attempt %d: retrying went false while still unreachable", attempt)
		}
	}
}

// The delays must grow and then cap, which is the whole point of backoff:
// fast enough to catch a `just run` restarting, slow enough that a core
// which is never coming back costs one dial every few seconds.
func TestRetryDelaysAreExponentialAndCapped(t *testing.T) {
	var prev time.Duration
	for attempt := 0; attempt < 6; attempt++ {
		d := retryDelay(attempt)
		if attempt > 0 && d <= prev && prev < vc.DefaultBackoff.Max {
			t.Errorf("delay(%d)=%s did not grow past delay(%d)=%s", attempt, d, attempt-1, prev)
		}
		if d > vc.DefaultBackoff.Max {
			t.Errorf("delay(%d)=%s exceeds the cap %s", attempt, d, vc.DefaultBackoff.Max)
		}
		prev = d
	}
	if got := retryDelay(0); got != vc.DefaultBackoff.Base {
		t.Errorf("first delay = %s, want the base %s", got, vc.DefaultBackoff.Base)
	}
}

// A retry timer already in flight when core comes back must not restart the
// chain — otherwise a recovered client keeps dialling on a schedule nobody
// asked for.
func TestRetryStopsOnceCoreIsBack(t *testing.T) {
	m := scheduling(t)
	m = step(m, StatusMsg{Status: vc.Status{Addr: "a"}})
	m = step(m, RetryMsg{Attempt: 1})

	m = step(m, StatusMsg{Status: vc.Status{Addr: "a", Reachable: true}})
	if m.retrying || m.retries != 0 {
		t.Fatalf("after recovery: retrying=%v retries=%d, want false/0", m.retrying, m.retries)
	}

	// The straggler timer lands after recovery.
	next, cmd := m.Update(RetryMsg{Attempt: 2})
	m = next.(model)
	if cmd != nil {
		t.Error("a stale retry timer restarted the chain after core came back")
	}
	if m.retries != 0 {
		t.Errorf("a stale retry timer moved the counter to %d", m.retries)
	}
}

// The header is the only place this is visible, so it has to name both how
// long until the next try and how many have failed.
func TestHeaderCountsAttempts(t *testing.T) {
	m := scheduling(t)
	m = step(m, StatusMsg{Status: vc.Status{Addr: "127.0.0.1:50051"}}, RetryMsg{Attempt: 3})

	got := m.headerView(120)
	for _, want := range []string{"unreachable", "retrying in", "attempt 3"} {
		if !contains(got, want) {
			t.Errorf("header missing %q:\n%s", want, got)
		}
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// Reconnecting re-subscribes to the roster, and vc replays the last roster
// it holds to any new subscriber (plugins.go: `if s.have { ch <- s.roster }`).
// That replay is NOT evidence core is back — it is the same data this client
// already had. Treating it as recovery cleared the banner, reset the
// counter, and killed the retry chain every couple of seconds, which is why
// the header sat on "retrying" and never counted past 2.
//
// Reachability has exactly one source of truth in this client: Status.
func TestCachedRosterIsNotEvidenceOfRecovery(t *testing.T) {
	m := scheduling(t)
	m = step(m, StatusMsg{Status: vc.Status{Addr: "a"}}, RetryMsg{Attempt: 3})
	if !m.stale || m.retries != 3 {
		t.Fatalf("setup: stale=%v retries=%d", m.stale, m.retries)
	}

	// The replay lands, exactly as it does on every re-subscribe.
	m = step(m, RosterMsg{Roster: vc.Roster{Plugins: []vc.Plugin{{ID: "todo"}}}})

	if !m.stale {
		t.Error("a replayed roster cleared the unreachable banner; core is still down")
	}
	if m.retries != 3 {
		t.Errorf("a replayed roster reset the attempt counter to %d", m.retries)
	}
	if !m.retrying {
		t.Error("a replayed roster stopped the retry chain")
	}
	// It is still data: the roster itself must be taken.
	if len(m.roster.Plugins) != 1 {
		t.Error("the roster payload was dropped")
	}

	// And a reachable status — the one thing that does mean it — recovers.
	m = step(m, StatusMsg{Status: vc.Status{Addr: "a", Reachable: true}})
	if m.stale || m.retries != 0 || m.retrying {
		t.Errorf("a reachable status did not recover: stale=%v retries=%d retrying=%v",
			m.stale, m.retries, m.retrying)
	}
}
