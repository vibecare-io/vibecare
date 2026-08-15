package tui

import (
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
)

// actionLog records what this session has DONE, as opposed to what it has
// seen. Core's log says a plugin restarted; only this says you are the one
// who restarted it, and when. When a debugging session goes sideways the
// question is almost always "what did I just change", and scrolling back
// through a merged log to answer it is exactly the thing this tool exists to
// avoid.
//
// It is session-local and never persisted: it describes this window, and a
// record that outlived the window would start answering a different
// question.
type actionLog struct {
	entries []actionEntry
	// open expands the strip from one line into a list. Collapsed is the
	// default because the bar is permanent chrome, and permanent chrome that
	// takes six lines is a pane, not a status bar.
	open bool
}

type actionEntry struct {
	At   time.Time
	Text string
	// Err marks a failed action. Rendering these the same as successes
	// would make the log actively misleading — "restarted todo" next to a
	// restart that errored is worse than no entry at all.
	Err bool
}

// actionLogMax bounds the history. A session left open all day must not grow
// without limit, and nobody scrolls back past a few dozen actions.
const actionLogMax = 100

// actionLogLines is how many entries the expanded strip shows. Enough to
// cover a train of related actions, small enough to leave the pane usable.
const actionLogLines = 6

func (l *actionLog) add(text string, failed bool, now time.Time) {
	l.entries = append(l.entries, actionEntry{At: now, Text: text, Err: failed})
	if len(l.entries) > actionLogMax {
		l.entries = l.entries[len(l.entries)-actionLogMax:]
	}
}

// last returns the most recent entry, which is what the collapsed strip
// shows: the single most useful fact is what you did a moment ago.
func (l *actionLog) last() (actionEntry, bool) {
	if len(l.entries) == 0 {
		return actionEntry{}, false
	}
	return l.entries[len(l.entries)-1], true
}

// height is how many rows the strip occupies, so the layout can subtract it
// before handing the rest to the pane.
func (l *actionLog) height() int {
	if !l.open {
		return 1
	}
	n := len(l.entries)
	if n > actionLogLines {
		n = actionLogLines
	}
	if n < 1 {
		n = 1
	}
	return n + 1 // the header line plus the entries
}

// render draws the strip. Collapsed it is one line: a marker, the label, the
// most recent action, and the key that expands it.
func (l *actionLog) render(w int, th *theme.Theme) string {
	if w <= 0 {
		return ""
	}

	mark, hint := "▸", "a:expand"
	if l.open {
		mark, hint = "▾", "a:collapse"
	}

	head := th.Bar.Render(mark + " Action Log")
	if !l.open {
		if e, ok := l.last(); ok {
			head += "  " + l.entryStyle(e, th).Render(l.entryText(e))
		} else {
			head += "  " + th.Dim.Render("nothing yet")
		}
	}

	line := padBar(head, hint, w, th)
	if !l.open {
		return line
	}

	lines := []string{line}
	from := len(l.entries) - actionLogLines
	if from < 0 {
		from = 0
	}
	if len(l.entries) == 0 {
		lines = append(lines, th.Dim.Render("  nothing yet — restarts, opens and pauses land here"))
	}
	for _, e := range l.entries[from:] {
		lines = append(lines, clampLine("  "+l.entryStyle(e, th).Render(l.entryText(e)), w))
	}
	return strings.Join(lines, "\n")
}

func (l *actionLog) entryText(e actionEntry) string {
	return e.At.Format("15:04:05") + "  " + e.Text
}

func (l *actionLog) entryStyle(e actionEntry, th *theme.Theme) lipgloss.Style {
	if e.Err {
		return th.Bad
	}
	return th.Dim
}

// padBar spreads the label and the hint to opposite ends of one full-width
// line, which is what makes the strip read as a bar rather than as content.
func padBar(left, right string, w int, th *theme.Theme) string {
	r := th.Bar.Render(right)
	gap := w - lipgloss.Width(left) - lipgloss.Width(r)
	if gap < 1 {
		return clampLine(left, w)
	}
	return left + strings.Repeat(" ", gap) + r
}
