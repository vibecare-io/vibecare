package tui

import (
	"strings"
	"testing"
	"time"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
)

func at(sec int) time.Time { return time.Date(2026, 8, 15, 9, 0, sec, 0, time.UTC) }

// Collapsed, the strip is one line and shows the thing you just did — the
// single most useful fact when you are wondering what you changed.
func TestActionLogCollapsedShowsLatest(t *testing.T) {
	var l actionLog
	l.add("restarting todo", false, at(1))
	l.add("opened todo in your browser", false, at(2))

	out := l.render(100, theme.New(true))
	if lines := strings.Count(out, "\n") + 1; lines != 1 {
		t.Errorf("collapsed strip is %d lines, want 1:\n%s", lines, out)
	}
	if !strings.Contains(out, "opened todo") {
		t.Errorf("collapsed strip does not show the latest action:\n%s", out)
	}
	if strings.Contains(out, "restarting todo") {
		t.Errorf("collapsed strip showed history it has no room for:\n%s", out)
	}
	if !strings.Contains(out, "a:expand") {
		t.Errorf("collapsed strip does not say how to open it:\n%s", out)
	}
}

func TestActionLogExpandedShowsHistory(t *testing.T) {
	var l actionLog
	l.add("restarting todo", false, at(1))
	l.add("opened todo in your browser", false, at(2))
	l.open = true

	out := l.render(100, theme.New(true))
	for _, want := range []string{"restarting todo", "opened todo", "09:00:01", "a:collapse"} {
		if !strings.Contains(out, want) {
			t.Errorf("expanded strip missing %q:\n%s", want, out)
		}
	}
	if got, want := l.height(), 3; got != want {
		t.Errorf("height = %d, want %d (header + 2 entries)", got, want)
	}
}

// A session left open all day must not grow without bound.
func TestActionLogIsBounded(t *testing.T) {
	var l actionLog
	for i := 0; i < actionLogMax*2; i++ {
		l.add("action", false, at(i%60))
	}
	if len(l.entries) > actionLogMax {
		t.Errorf("kept %d entries, want at most %d", len(l.entries), actionLogMax)
	}
}

// Empty is a normal state, not a special case to crash on.
func TestActionLogEmpty(t *testing.T) {
	var l actionLog
	if got := l.height(); got != 1 {
		t.Errorf("empty collapsed height = %d, want 1", got)
	}
	if out := l.render(80, theme.New(true)); !strings.Contains(out, "nothing yet") {
		t.Errorf("empty strip says nothing:\n%s", out)
	}
	l.open = true
	if out := l.render(80, theme.New(true)); out == "" {
		t.Error("empty expanded strip rendered nothing at all")
	}
}

// The strip records what the user DID. Notices are how every action reports
// itself, so hanging the log off them is what makes a new action logged for
// free rather than needing a second call at each site.
func TestNoticeIsRecorded(t *testing.T) {
	m := step(testModel(120, 40), NoticeMsg{Text: "restarting todo", At: at(5)})

	if len(m.alog.entries) != 1 {
		t.Fatalf("logged %d entries, want 1", len(m.alog.entries))
	}
	if m.alog.entries[0].Text != "restarting todo" {
		t.Errorf("logged %q", m.alog.entries[0].Text)
	}
	if !strings.Contains(m.View(), "restarting todo") {
		t.Error("the strip is not visible in the rendered view")
	}
}

// `a` toggles it, and expanding must take its rows out of the pane's budget
// rather than pushing the footer off the bottom of the terminal.
func TestActionLogToggleFitsTheTerminal(t *testing.T) {
	m := step(testModel(120, 30), NoticeMsg{Text: "restarting todo", At: at(5)})
	if m.alog.open {
		t.Fatal("the strip starts expanded; it is permanent chrome and should not")
	}

	m = step(m, key("a"))
	if !m.alog.open {
		t.Fatal("a did not expand the action log")
	}
	if h := strings.Count(m.View(), "\n") + 1; h > 30 {
		t.Errorf("view is %d lines in a 30-line terminal", h)
	}

	m = step(m, key("a"))
	if m.alog.open {
		t.Error("a did not collapse it again")
	}
}
