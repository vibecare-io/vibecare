package vc

import (
	"context"
	"testing"
	"time"

	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
	pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
)

// waitIntents blocks until the fake shell has n live Intents streams. The
// subscribe is asynchronous — WatchAlerts returns before the server has
// registered the stream — so pushing an alert without waiting would be a
// coin flip.
func waitIntents(t *testing.T, f *fakeShell, n int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		f.mu.Lock()
		live := len(f.intents)
		f.mu.Unlock()
		if live >= n {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %d intent stream(s)", n)
}

func TestWatchAlertsDelivers(t *testing.T) {
	sess, f := newTestServer(t)

	ch, err := sess.WatchAlerts(testCtx(t))
	if err != nil {
		t.Fatalf("WatchAlerts: %v", err)
	}
	waitIntents(t, f.shell, 1)

	before := time.Now()
	f.shell.pushAlert(&clientv1.Alert{
		Plugin: "todo",
		Title:  "Stand up",
		Body:   "You have been sitting for an hour",
		Level:  "warn",
		Actions: []*pluginv1.AlertAction{
			{Label: "Snooze", Url: "snooze"},
		},
	})

	select {
	case a := <-ch:
		if a.Plugin != "todo" || a.Title != "Stand up" || !a.Warn() {
			t.Fatalf("alert = %+v", a)
		}
		if len(a.Actions) != 1 || a.Actions[0].Label != "Snooze" || a.Actions[0].URL != "snooze" {
			t.Fatalf("actions = %+v", a.Actions)
		}
		if a.Received.Before(before) {
			t.Fatalf("Received = %v, want a client receive time at or after %v", a.Received, before)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no alert delivered")
	}
}

func TestWatchAlertsClosesOnContextCancel(t *testing.T) {
	sess, f := newTestServer(t)

	ctx, cancel := context.WithCancel(context.Background())
	ch, err := sess.WatchAlerts(ctx)
	if err != nil {
		t.Fatalf("WatchAlerts: %v", err)
	}
	waitIntents(t, f.shell, 1)

	cancel()
	select {
	case _, open := <-ch:
		if open {
			// One in-flight alert may still be buffered; drain and retry.
			select {
			case _, open := <-ch:
				if open {
					t.Fatal("channel still open after cancel")
				}
			case <-time.After(3 * time.Second):
				t.Fatal("channel never closed after cancel")
			}
		}
	case <-time.After(3 * time.Second):
		t.Fatal("channel never closed after cancel")
	}
}

// A user leaves the alerts pane open across a `just run` restart, so a
// dropped stream must resubscribe rather than go quiet forever.
func TestWatchAlertsReconnects(t *testing.T) {
	sess, f := newTestServer(t)

	ch, err := sess.WatchAlerts(testCtx(t))
	if err != nil {
		t.Fatalf("WatchAlerts: %v", err)
	}
	waitIntents(t, f.shell, 1)

	f.shell.dropAll()
	waitIntents(t, f.shell, 1)

	f.shell.pushAlert(&clientv1.Alert{Plugin: "todo", Title: "back", Level: "info"})
	select {
	case a := <-ch:
		if a.Title != "back" {
			t.Fatalf("alert = %+v", a)
		}
		if a.Warn() {
			t.Fatal("info alert must not be a warning")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no alert after reconnect")
	}
}

func TestWatchAlertsClosesWhenSessionCloses(t *testing.T) {
	sess, f := newTestServer(t)

	ch, err := sess.WatchAlerts(context.Background())
	if err != nil {
		t.Fatalf("WatchAlerts: %v", err)
	}
	waitIntents(t, f.shell, 1)

	if err := sess.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	select {
	case _, open := <-ch:
		if open {
			t.Fatal("channel still open after Close")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("channel never closed after Close")
	}

	if _, err := sess.WatchAlerts(context.Background()); err == nil {
		t.Fatal("watching a closed session should fail")
	}
}
