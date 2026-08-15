package cli

import (
	"fmt"
	"strconv"
	"time"

	"github.com/mattn/go-runewidth"

	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// Cell formatting shared by the schedule, routine and action tables.
//
// It lives in its own file because two of the rules here are correctness, not
// decoration. A timestamp core never set must read as "never" rather than as
// a date near the epoch — the difference between "this schedule has not run"
// and "this schedule ran in 1970" is the whole answer the user came for. And
// a cell is measured in terminal columns, so a value that would wrap has to
// be cut here, before the table aligns on a width no terminal will honour.
//
// None of this applies to --json, which carries the raw values: the contract
// is for a parser, and a parser wants the timestamp, not the prose.

// Column budgets. Wide enough for the common value, narrow enough that the
// six-column schedule table still fits an 80-column terminal.
const (
	rruleWidth = 44
	notesWidth = 40
	nameWidth  = 32
)

// dash stands in for a value that was never measured. Rendering 0 there would
// be a fabricated fact — "0 restarts" and "we have no idea" are very different
// answers.
const dash = "—"

// humanDuration renders a duration the way a human reads a clock: at most two
// units, largest first, and the smaller one dropped when it is zero. Raw
// seconds belong in --json, where the _sec suffix says what they are; in a
// table they make the reader do arithmetic.
func humanDuration(d time.Duration) string {
	if d < time.Second {
		return "0s"
	}
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		h, m := int(d.Hours()), int(d.Minutes())%60
		if m == 0 {
			return fmt.Sprintf("%dh", h)
		}
		return fmt.Sprintf("%dh%dm", h, m)
	default:
		days, h := int(d.Hours())/24, int(d.Hours())%24
		if h == 0 {
			return fmt.Sprintf("%dd", days)
		}
		return fmt.Sprintf("%dd%dh", days, h)
	}
}

// relTime renders t relative to now. See relTimeAt for the rules.
func relTime(t *time.Time) string { return relTimeAt(t, time.Now()) }

// relTimeAt renders t as an offset from now: "in 12m" ahead, "3h ago"
// behind, and a dash for a timestamp that does not exist.
//
// Absent is a pointer OR the Go zero time: vc maps an unset proto timestamp
// to nil, but a value that arrived some other way must not be allowed to
// print as year 1 either. Sub-second offsets collapse to "now" because
// "in 0s" describes a clock, not an event.
func relTimeAt(t *time.Time, now time.Time) string {
	if t == nil || t.IsZero() {
		return dash
	}
	d := t.Sub(now)
	if d < 0 {
		d = -d
	}
	if d < time.Second {
		return "now"
	}
	if t.After(now) {
		return "in " + humanDuration(d)
	}
	return humanDuration(d) + " ago"
}

// stamp renders a timestamp for a detail view, where there is room for both
// readings: the RFC 3339 instant the JSON contract carries, and the relative
// one a human actually reads.
func stamp(t *time.Time) string { return stampAt(t, time.Now()) }

func stampAt(t *time.Time, now time.Time) string {
	if t == nil || t.IsZero() {
		return dash
	}
	return t.UTC().Format(time.RFC3339) + " (" + relTimeAt(t, now) + ")"
}

// truncate cuts s to at most width terminal columns, marking the cut with an
// ellipsis. Width is measured in cells rather than bytes or runes, because
// that is what the table pads to and what the terminal draws.
func truncate(s string, width int) string {
	if width <= 0 {
		return ""
	}
	if runewidth.StringWidth(s) <= width {
		return s
	}
	return runewidth.Truncate(s, width, "…")
}

// rruleCell renders an RRULE for a list row. Recurrence rules are routinely
// longer than a terminal is wide, and one schedule that wraps costs the
// reader the alignment of every row below it. `schedules show` prints the
// rule in full, and --json always does.
func rruleCell(s string) string { return orDash(truncate(s, rruleWidth)) }

// orDash renders an empty string as a dash. An empty cell in an aligned table
// reads as a rendering bug; a dash reads as "core did not set this".
func orDash(s string) string {
	if s == "" {
		return dash
	}
	return s
}

// yesNo renders a bool for a human. "true"/"false" is the JSON contract's
// job; a table column reads better as an answer than as a literal.
func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

// actionHeaders and actionRows render the action list that hangs off both a
// schedule and a routine, so the two detail views cannot drift apart.
var actionHeaders = []string{"#", "ID", "NAME", "TYPE", "ENABLED"}

// actionRows numbers from 1: Order is the join table's zero-based execution
// order, and "action 0" is an index, not a step.
func actionRows(actions []vc.Action) [][]string {
	rows := make([][]string, 0, len(actions))
	for _, a := range actions {
		rows = append(rows, []string{
			strconv.Itoa(int(a.Order) + 1),
			a.ID,
			orDash(truncate(a.Name, nameWidth)),
			orDash(a.Type),
			yesNo(a.Enabled),
		})
	}
	return rows
}
