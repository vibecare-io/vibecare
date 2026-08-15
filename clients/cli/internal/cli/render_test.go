package cli

import (
	"strings"
	"testing"
	"time"

	"github.com/mattn/go-runewidth"

	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// at is a fixed "now" so the relative-time tables read as arithmetic rather
// than as timing. Every case below is expressed as an offset from it.
var at = time.Date(2026, 8, 14, 12, 0, 0, 0, time.UTC)

func ptr(t time.Time) *time.Time { return &t }

func TestHumanDuration(t *testing.T) {
	cases := []struct {
		in   time.Duration
		want string
	}{
		{0, "0s"},
		{-5 * time.Second, "0s"},
		{45 * time.Second, "45s"},
		{time.Minute, "1m"},
		{12 * time.Minute, "12m"},
		{12*time.Minute + 30*time.Second, "12m"},
		{time.Hour, "1h"},
		{3*time.Hour + 4*time.Minute, "3h4m"},
		{3*time.Hour + 4*time.Minute + 59*time.Second, "3h4m"},
		{24 * time.Hour, "1d"},
		{49 * time.Hour, "2d1h"},
		{48 * time.Hour, "2d"},
	}
	for _, c := range cases {
		if got := humanDuration(c.in); got != c.want {
			t.Errorf("humanDuration(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestRelTimeAt(t *testing.T) {
	cases := []struct {
		name string
		in   *time.Time
		want string
	}{
		{"never run", nil, dash},
		// The whole reason this helper exists: an unset timestamp that
		// reached us as a value rather than a nil pointer must still read as
		// "never", not as a date in 1970 — or, for the Go zero time, in year 1.
		{"the zero time is not a timestamp", ptr(time.Time{}), dash},
		{"due soon", ptr(at.Add(12 * time.Minute)), "in 12m"},
		{"due within the minute", ptr(at.Add(45 * time.Second)), "in 45s"},
		{"ran earlier", ptr(at.Add(-3 * time.Hour)), "3h ago"},
		{"ran yesterday", ptr(at.Add(-26 * time.Hour)), "1d2h ago"},
		{"rounds down to the coarser unit", ptr(at.Add(12*time.Minute + 59*time.Second)), "in 12m"},
		{"this instant", ptr(at), "now"},
		{"sub-second either way is now", ptr(at.Add(-500 * time.Millisecond)), "now"},
	}
	for _, c := range cases {
		if got := relTimeAt(c.in, at); got != c.want {
			t.Errorf("%s: relTimeAt = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestTruncate(t *testing.T) {
	cases := []struct {
		name  string
		in    string
		width int
		want  string
	}{
		{"empty", "", 10, ""},
		{"fits", "FREQ=DAILY", 10, "FREQ=DAILY"},
		{"one over", "FREQ=DAILYX", 10, "FREQ=DAIL…"},
		{"no room at all", "FREQ=DAILY", 0, ""},
		// A cell is measured in terminal columns, not runes: the table aligns
		// on width, so truncating on len() would break every row after a CJK
		// one.
		{"wide runes count double", "日本語テスト", 5, "日本…"},
	}
	for _, c := range cases {
		got := truncate(c.in, c.width)
		if got != c.want {
			t.Errorf("%s: truncate(%q, %d) = %q, want %q", c.name, c.in, c.width, got, c.want)
		}
		if w := runewidth.StringWidth(got); w > c.width {
			t.Errorf("%s: result is %d columns wide, want at most %d", c.name, w, c.width)
		}
	}
}

func TestRRuleCell(t *testing.T) {
	long := "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=30;COUNT=52"

	if got := rruleCell(""); got != dash {
		t.Errorf("rruleCell(\"\") = %q, want %q", got, dash)
	}
	if got := rruleCell("FREQ=DAILY"); got != "FREQ=DAILY" {
		t.Errorf("rruleCell = %q, want it untouched", got)
	}
	got := rruleCell(long)
	if w := runewidth.StringWidth(got); w != rruleWidth {
		t.Errorf("rruleCell(long) is %d columns, want %d: %q", w, rruleWidth, got)
	}
	if !strings.HasSuffix(got, "…") {
		t.Errorf("rruleCell(long) = %q, want an ellipsis marking the cut", got)
	}
}

func TestStamp(t *testing.T) {
	if got := stamp(nil); got != dash {
		t.Errorf("stamp(nil) = %q, want %q", got, dash)
	}
	if got := stamp(ptr(time.Time{})); got != dash {
		t.Errorf("stamp(zero) = %q, want %q", got, dash)
	}
	// The detail view carries both readings: the contract's RFC 3339 instant,
	// and the relative one a human actually reads.
	got := stampAt(ptr(at.Add(-2*time.Hour)), at)
	if !strings.HasPrefix(got, "2026-08-14T10:00:00Z") || !strings.Contains(got, "2h ago") {
		t.Errorf("stampAt = %q, want the absolute instant and the relative one", got)
	}
}

func TestYesNo(t *testing.T) {
	if yesNo(true) != "yes" || yesNo(false) != "no" {
		t.Errorf("yesNo = %q/%q, want yes/no", yesNo(true), yesNo(false))
	}
}

func TestOrDash(t *testing.T) {
	if got := orDash(""); got != dash {
		t.Errorf("orDash(\"\") = %q, want %q", got, dash)
	}
	if got := orDash("x"); got != "x" {
		t.Errorf("orDash(%q) = %q, want it untouched", "x", got)
	}
}

func TestActionRows(t *testing.T) {
	rows := actionRows([]vc.Action{
		{ID: "a1", Name: "Stretch", Type: "notification", Enabled: true, Order: 0},
		{ID: "a2", Type: "", Enabled: false, Order: 1},
	})
	if len(rows) != 2 {
		t.Fatalf("actionRows returned %d rows, want 2", len(rows))
	}
	want := []string{"1", "a1", "Stretch", "notification", "yes"}
	for i := range want {
		if rows[0][i] != want[i] {
			t.Errorf("row 0 column %d = %q, want %q", i, rows[0][i], want[i])
		}
	}
	// An action whose name or type core never set must not render as an empty
	// cell that reads like a truncation bug.
	if rows[1][2] != dash || rows[1][3] != dash {
		t.Errorf("row 1 = %q, want dashes for the unset name and type", rows[1])
	}
	if rows[1][4] != "no" {
		t.Errorf("row 1 enabled = %q, want %q", rows[1][4], "no")
	}
}
