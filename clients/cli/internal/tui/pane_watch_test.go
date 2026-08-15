package tui

import (
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

func watchPaneFor(t *testing.T) Pane {
	t.Helper()
	return paneOf(t, SubjectAll, keymap.CtxWatch, Subject{Kind: SubjectAll})
}

func ev(plugin, topic, payload string, sec int) EventMsg {
	return EventMsg{Event: vc.Event{
		Plugin: plugin, Topic: topic, Payload: payload,
		At: time.Date(2026, 8, 15, 10, 0, sec, 0, time.UTC),
	}}
}

func TestWatchRendersEvents(t *testing.T) {
	p := drive(watchPaneFor(t),
		ev("todo", "todo.created.v1", `{"id":1}`, 1),
		ev("vibecheck", "vibecheck.behavior_detected.v1", `{"kind":"nail"}`, 2),
	)

	out := p.View(120, 20)
	for _, want := range []string{"todo", "todo.created.v1", "vibecheck.behavior_detected.v1", "10:00:01"} {
		if !strings.Contains(out, want) {
			t.Errorf("view missing %q:\n%s", want, out)
		}
	}
}

// Empty is the normal state on a quiet system, and it has to explain itself
// rather than look like a broken pane.
func TestWatchEmptyExplainsItself(t *testing.T) {
	out := watchPaneFor(t).View(100, 12)
	if !strings.Contains(out, "nothing published yet") {
		t.Errorf("empty watch view says nothing useful:\n%s", out)
	}
	if !strings.Contains(out, "no plugin subscribed") {
		t.Errorf("empty view does not explain what it shows:\n%s", out)
	}
}

// A topic must keep the same colour every time it appears, in every session.
// A palette handed out in arrival order would look identical and mean
// nothing — the point is locking onto one topic in a fast stream without
// reading it.
func TestTopicColourIsStableAndVaries(t *testing.T) {
	restore := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.ANSI256)
	t.Cleanup(func() { lipgloss.SetColorProfile(restore) })

	th := theme.New(true)
	a1 := topicStyle("todo.created.v1", th).Render("x")
	a2 := topicStyle("todo.created.v1", th).Render("x")
	b := topicStyle("vibecheck.behavior_detected.v1", th).Render("x")

	if a1 != a2 {
		t.Error("the same topic rendered two different colours")
	}
	if a1 == b {
		t.Error("two different topics share a colour; the stream is unreadable at speed")
	}
}

// Scrollback is bounded: a day-long session on a busy bus must not grow
// without limit.
func TestWatchScrollbackIsBounded(t *testing.T) {
	p := watchPaneFor(t)
	for i := 0; i < watchMax+250; i++ {
		p = drive(p, ev("todo", "todo.created.v1", "x", i%60))
	}
	if got := len(p.(watchPane).events); got > watchMax {
		t.Errorf("held %d events, want at most %d", got, watchMax)
	}
}

// Chips are how the topics present themselves, and the filter narrows to one.
func TestWatchFiltersByTopic(t *testing.T) {
	p := drive(watchPaneFor(t),
		ev("todo", "todo.created.v1", "a", 1),
		ev("vibecheck", "vibecheck.behavior_detected.v1", "b", 2),
	)

	var topics []string
	for _, c := range p.Chips() {
		if c.Filter {
			topics = append(topics, c.Label)
		}
	}
	if len(topics) != 3 { // all + the two topics
		t.Fatalf("filter chips = %v, want all + 2 topics", topics)
	}

	w := p.(watchPane)
	w.filter = "todo.created.v1"
	out := w.View(120, 20)
	if strings.Contains(out, "vibecheck.behavior_detected.v1") {
		t.Errorf("filter did not exclude the other topic:\n%s", out)
	}
	if !strings.Contains(out, "todo.created.v1") {
		t.Errorf("filter excluded its own topic:\n%s", out)
	}
}

// The rule every live tail gets wrong: scrolling back must not be undone by
// the next arriving event.
func TestWatchScrollingBackDisengagesFollow(t *testing.T) {
	p := watchPaneFor(t)
	for i := 0; i < 60; i++ {
		p = drive(p, ev("todo", "todo.created.v1", "x", i%60))
	}
	if !p.(watchPane).follow {
		t.Fatal("watch did not start following")
	}

	p = drive(p, tea.WindowSizeMsg{Width: 120, Height: 30}, ActionMsg{Action: keymap.ActionSelectPrev})
	if p.(watchPane).follow {
		t.Error("scrolling back left follow engaged; the view will yank away mid-read")
	}
}

// Clearing empties the view, and the wording must not imply data was lost:
// core stores none of this in the first place.
func TestWatchClear(t *testing.T) {
	p := drive(watchPaneFor(t), ev("todo", "todo.created.v1", "a", 1))
	p = drive(p, ActionMsg{Action: keymap.ActionClear})
	if got := len(p.(watchPane).events); got != 0 {
		t.Errorf("clear left %d events", got)
	}
}

// A payload with newlines must not break the one-event-per-line layout.
func TestWatchFlattensMultilinePayloads(t *testing.T) {
	p := drive(watchPaneFor(t), ev("todo", "todo.created.v1", "line one\nline two\tand\rmore", 1))
	out := p.View(200, 10)
	if lines := strings.Count(strings.TrimRight(out, "\n"), "\n") + 1; lines != 1 {
		t.Errorf("one event rendered as %d lines:\n%s", lines, out)
	}
	if !strings.Contains(out, "line one line two and more") {
		t.Errorf("payload not flattened:\n%s", out)
	}
}
