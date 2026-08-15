package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/vibecare-io/vibecare/clients/cli/internal/cli/output"
	"github.com/vibecare-io/vibecare/clients/cli/internal/notify"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// This file covers the phase 2–4 commands: schedules, alerts, routines and
// actions. Everything here runs with no backend — the command-level cases
// dial a dead port on purpose, and the streaming cases drive a channel
// directly rather than a stream.

func TestScheduleRowAt(t *testing.T) {
	next := at.Add(12 * time.Minute)
	last := at.Add(-3 * time.Hour)

	row := scheduleRowAt(vc.Schedule{
		ID: "s1", Name: "Morning stretch", Enabled: true,
		RRule:         "FREQ=DAILY;BYHOUR=9",
		NextExecution: &next,
		LastExecution: &last,
	}, at)

	want := []string{"s1", "Morning stretch", "yes", "FREQ=DAILY;BYHOUR=9", "in 12m", "3h ago"}
	if len(row) != len(want) {
		t.Fatalf("row has %d columns, want %d: %q", len(row), len(want), row)
	}
	for i := range want {
		if row[i] != want[i] {
			t.Errorf("column %d = %q, want %q", i, row[i], want[i])
		}
	}
}

// A schedule that has never run, and one that will never run again, are the
// two states this table exists to make obvious. Rendering either as 1970
// would be a fabricated fact.
func TestScheduleRowNeverRunRendersDashes(t *testing.T) {
	row := scheduleRowAt(vc.Schedule{ID: "s2", Name: "Paused", Enabled: false}, at)
	if row[2] != "no" {
		t.Errorf("enabled column = %q, want %q", row[2], "no")
	}
	for _, i := range []int{3, 4, 5} {
		if row[i] != dash {
			t.Errorf("column %d = %q, want %q", i, row[i], dash)
		}
	}
	if strings.Contains(strings.Join(row, " "), "1970") {
		t.Errorf("row mentions the epoch: %q", row)
	}
}

func TestScheduleRowTruncatesRRule(t *testing.T) {
	long := "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=30;COUNT=52"
	row := scheduleRowAt(vc.Schedule{ID: "s3", RRule: long}, at)
	if row[3] == long {
		t.Errorf("rrule column was not truncated: %q", row[3])
	}
	if !strings.HasSuffix(row[3], "…") {
		t.Errorf("rrule column = %q, want an ellipsis marking the cut", row[3])
	}
}

// --all plus an id is two different requests in one argv, and guessing which
// one was meant is how a user pauses every schedule they own by accident.
func TestPauseResumeAllWithIDIsUsageError(t *testing.T) {
	for _, verb := range []string{"pause", "resume"} {
		out, errOut, code := capture(t, "--addr", deadAddr, "schedules", verb, "--all", "s1")
		if code != vc.ExitUsage {
			t.Errorf("%s: exit = %d, want %d (stderr: %s)", verb, code, vc.ExitUsage, errOut)
		}
		if !strings.Contains(errOut, "--all") {
			t.Errorf("%s: stderr = %q, want it to name the conflict", verb, errOut)
		}
		if out != "" {
			t.Errorf("%s: stdout = %q, want nothing", verb, out)
		}
	}
}

func TestPauseResumeNeedATarget(t *testing.T) {
	for _, verb := range []string{"pause", "resume"} {
		_, errOut, code := capture(t, "--addr", deadAddr, "schedules", verb)
		if code != vc.ExitUsage {
			t.Errorf("%s: exit = %d, want %d (stderr: %s)", verb, code, vc.ExitUsage, errOut)
		}
	}
}

// Every one of these commands needs core. With none listening they must fail
// as unreachable — exit 2, not a panic and not a silent 0.
func TestCommandsAreUnreachableWithoutCore(t *testing.T) {
	argvs := [][]string{
		{"schedules"},
		{"schedules", "ls"},
		{"schedules", "ls", "--routine", "r1", "--enabled"},
		{"schedules", "show", "s1"},
		{"schedules", "pause", "s1"},
		{"schedules", "resume", "--all"},
		{"alerts"},
		{"routines"},
		{"routines", "ls"},
		{"routines", "show", "r1"},
		{"routines", "run", "r1"},
		{"routines", "logs", "r1"},
		{"actions"},
		{"actions", "ls"},
		{"actions", "show", "a1"},
		{"actions", "run", "a1"},
		{"actions", "types"},
	}
	for _, argv := range argvs {
		args := append([]string{"--addr", deadAddr}, argv...)
		out, errOut, code := capture(t, args...)
		if code != vc.ExitUnreachable {
			t.Errorf("%v: exit = %d, want %d (stdout: %s stderr: %s)", argv, code, vc.ExitUnreachable, out, errOut)
		}
		if !strings.Contains(errOut, "unreachable") {
			t.Errorf("%v: stderr = %q, want it to say core is unreachable", argv, errOut)
		}
	}
}

func TestMissingIDsAreUsageErrors(t *testing.T) {
	argvs := [][]string{
		{"schedules", "show"},
		{"routines", "show"},
		{"routines", "run"},
		{"routines", "logs"},
		{"actions", "show"},
		{"actions", "run"},
	}
	for _, argv := range argvs {
		args := append([]string{"--addr", deadAddr}, argv...)
		_, errOut, code := capture(t, args...)
		if code != vc.ExitUsage {
			t.Errorf("%v: exit = %d, want %d (stderr: %s)", argv, code, vc.ExitUsage, errOut)
		}
	}
}

// countingNotifier stands in for the desktop. The suite must never spawn
// osascript or notify-send, and --notify has to be observable without one.
type countingNotifier struct {
	got []notify.Notification
	err error
}

func (c *countingNotifier) Notify(_ context.Context, n notify.Notification) error {
	c.got = append(c.got, n)
	return c.err
}

func alertChan(alerts ...vc.Alert) <-chan vc.Alert {
	ch := make(chan vc.Alert, len(alerts))
	for _, a := range alerts {
		ch <- a
	}
	close(ch)
	return ch
}

// --json emits one envelope per alert. A stream has no end, so there is no
// array to close and nothing a consumer could wait for: JSON Lines is the
// only shape that is parseable while the command is still running.
func TestEmitAlertsJSONLines(t *testing.T) {
	var out bytes.Buffer
	p := output.New(&out, io.Discard, output.JSON, false)
	ch := alertChan(
		vc.Alert{Received: at, Plugin: "vibecheck", Title: "Nail biting", Level: "warn"},
		vc.Alert{Received: at, Plugin: "todo", Title: "Due soon", Level: "info"},
	)

	if err := emitAlerts(context.Background(), p, notify.Noop(), ch, false); err != nil {
		t.Fatalf("emitAlerts: %v", err)
	}

	dec := json.NewDecoder(&out)
	var titles []string
	for {
		var env struct {
			V    int      `json:"v"`
			Data vc.Alert `json:"data"`
		}
		if err := dec.Decode(&env); errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			t.Fatalf("decode: %v", err)
		}
		if env.V != vc.ContractVersion {
			t.Errorf("v = %d, want %d", env.V, vc.ContractVersion)
		}
		titles = append(titles, env.Data.Title)
	}
	if len(titles) != 2 || titles[0] != "Nail biting" || titles[1] != "Due soon" {
		t.Errorf("titles = %q, want one envelope per alert in order", titles)
	}
}

func TestEmitAlertsTableLines(t *testing.T) {
	var out bytes.Buffer
	p := output.New(&out, io.Discard, output.Table, false)
	ch := alertChan(vc.Alert{
		Received: at, Plugin: "vibecheck", Title: "Nail biting", Body: "hand near face",
		Level: "warn", Actions: []vc.AlertAction{{Label: "Open", URL: "/x"}},
	})

	if err := emitAlerts(context.Background(), p, notify.Noop(), ch, false); err != nil {
		t.Fatalf("emitAlerts: %v", err)
	}
	for _, want := range []string{"vibecheck", "warn", "Nail biting", "hand near face", "Open"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("output missing %q:\n%s", want, out.String())
		}
	}
}

func TestEmitAlertsNotifiesPerAlert(t *testing.T) {
	n := &countingNotifier{}
	p := output.New(io.Discard, io.Discard, output.Table, false)
	ch := alertChan(
		vc.Alert{Plugin: "vibecheck", Title: "one", Level: "warn"},
		vc.Alert{Plugin: "todo", Title: "two"},
	)

	if err := emitAlerts(context.Background(), p, n, ch, false); err != nil {
		t.Fatalf("emitAlerts: %v", err)
	}
	if len(n.got) != 2 {
		t.Fatalf("notified %d times, want 2", len(n.got))
	}
	if !strings.Contains(n.got[0].Title, "one") || n.got[0].Level != "warn" {
		t.Errorf("first notification = %+v, want the alert's title and level", n.got[0])
	}
	if !strings.Contains(n.got[1].Title, "two") {
		t.Errorf("second notification = %+v, want the second alert", n.got[1])
	}
}

// A notifier that cannot draw must not take the stream down with it: the
// alerts are still worth printing.
func TestEmitAlertsSurvivesNotifierFailure(t *testing.T) {
	var out bytes.Buffer
	n := &countingNotifier{err: errors.New("no notification daemon")}
	p := output.New(&out, io.Discard, output.Table, false)

	if err := emitAlerts(context.Background(), p, n, alertChan(vc.Alert{Title: "still printed"}), false); err != nil {
		t.Fatalf("emitAlerts: %v", err)
	}
	if !strings.Contains(out.String(), "still printed") {
		t.Errorf("output = %q, want the alert printed anyway", out.String())
	}
}

// Without -f the command reports what core already had and leaves. Blocking
// forever on a channel nothing will write to would make `vibecare alerts`
// unusable from a script.
func TestEmitAlertsWithoutFollowReturns(t *testing.T) {
	p := output.New(io.Discard, io.Discard, output.Table, false)
	// Never closed and never written to: exactly the "no alerts queued" case.
	ch := make(chan vc.Alert)

	done := make(chan error, 1)
	go func() { done <- emitAlerts(context.Background(), p, notify.Noop(), ch, false) }()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("emitAlerts: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("emitAlerts hung with no alerts queued and --follow unset")
	}
}

// With -f, Ctrl-C is the way out, and it means "stop following" — a success,
// not a failure, or every shell pipeline ending in one would break.
func TestEmitAlertsFollowStopsOnCancel(t *testing.T) {
	p := output.New(io.Discard, io.Discard, output.Table, false)
	ctx, cancel := context.WithCancel(context.Background())
	ch := make(chan vc.Alert)

	done := make(chan error, 1)
	go func() { done <- emitAlerts(ctx, p, notify.Noop(), ch, true) }()

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("emitAlerts after cancel = %v, want nil", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("emitAlerts ignored its context")
	}
}
