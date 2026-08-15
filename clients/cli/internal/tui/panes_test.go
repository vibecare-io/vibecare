package tui

import (
	"fmt"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/vibecare-io/vibecare/clients/cli/internal/logtail"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// Every test here drives a pane exactly as the runtime does — messages in,
// state and rendered text out — with no session, no files and no terminal.
// lipgloss emits no escapes when stdout is not a TTY, so a View is compared
// as plain text.

// paneOf builds the pane the registry has for this subject and tab, already
// sized, which is what the root model does before the first frame.
func paneOf(t *testing.T, k SubjectKind, c keymap.Ctx, s Subject) Pane {
	t.Helper()
	p := paneFor(k, c, PaneCtx{Subject: s, Theme: theme.New(true)})
	if _, ok := p.(placeholderPane); ok {
		t.Fatalf("no pane registered for %v/%s", k, c)
	}
	p.Init(PaneCtx{Subject: s, Theme: theme.New(true)})
	return drive(p, tea.WindowSizeMsg{Width: 100, Height: 30})
}

func drive(p Pane, msgs ...tea.Msg) Pane {
	for _, msg := range msgs {
		next, _ := p.Update(msg)
		if next != nil {
			p = next
		}
	}
	return p
}

// action is what the root forwards after resolving a key through keymap, so
// pane tests press actions rather than keys wherever a binding exists.
func action(a string) tea.Msg { return ActionMsg{Action: a} }

func chipValue(p Pane, label string) (Chip, bool) {
	for _, c := range p.Chips() {
		if c.Label == label {
			return c, true
		}
	}
	return Chip{}, false
}

func pluginSubject(p vc.Plugin) Subject {
	return Subject{Kind: SubjectPlugin, ID: p.ID, Plugin: &p}
}

func mustContain(t *testing.T, got string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(got, w) {
			t.Errorf("view missing %q\n---\n%s\n---", w, got)
		}
	}
}

func mustNotContain(t *testing.T, got string, unwanted ...string) {
	t.Helper()
	for _, w := range unwanted {
		if strings.Contains(got, w) {
			t.Errorf("view contains %q and should not\n---\n%s\n---", w, got)
		}
	}
}

func TestOverviewAllShowsTallyAndGrid(t *testing.T) {
	p := paneOf(t, SubjectAll, keymap.CtxOverview, Subject{Kind: SubjectAll})
	p = drive(p, RosterMsg{Roster: vc.Roster{Plugins: []vc.Plugin{
		{ID: "vibecheck", State: vc.StateUp, PID: 40122, UptimeSec: 90, Restarts: 1, Stats: true},
		{ID: "todo", State: vc.StateFailed, Detail: "exit 1"},
	}}})

	mustContain(t, p.View(100, 20), "vibecheck", "todo", "UP", "FAILED", "40122", "2 total")
}

func TestOverviewEmptyRosterSaysSo(t *testing.T) {
	p := paneOf(t, SubjectAll, keymap.CtxOverview, Subject{Kind: SubjectAll})
	p = drive(p, RosterMsg{Roster: vc.Roster{}})

	mustContain(t, p.View(80, 10), "no plugins discovered")
}

// A roster row that never met the kernel's HTTP surface has zeroes, not
// measurements. Printing "0 restarts" there is a lie, which is why Stats
// exists at all.
func TestOverviewPluginWithoutStatsHidesNumbers(t *testing.T) {
	pl := vc.Plugin{ID: "todo", Name: "Todo", State: vc.StateUp, UI: "webview"}
	p := paneOf(t, SubjectPlugin, keymap.CtxOverview, pluginSubject(pl))

	got := p.View(80, 20)
	mustContain(t, got, "todo", "UP", "kernel stats unavailable")
	mustNotContain(t, got, "restarts")
}

func TestOverviewPluginWithStats(t *testing.T) {
	pl := vc.Plugin{
		ID: "vibecheck", State: vc.StateUp, PID: 40122, UptimeSec: 3720, Restarts: 2,
		ProbeLatencyMS: 3, EventsPublished: 12, EventsDelivered: 8,
		LogPath: "/tmp/vibecheck.log", Stats: true,
	}
	p := paneOf(t, SubjectPlugin, keymap.CtxOverview, pluginSubject(pl))

	mustContain(t, p.View(80, 20), "40122", "1h2m", "restarts", "3ms", "12", "/tmp/vibecheck.log")
}

func TestCoreStatusPane(t *testing.T) {
	p := paneOf(t, SubjectCore, keymap.CtxStatus, Subject{Kind: SubjectCore, ID: coreID})
	p = drive(p, StatusMsg{Status: vc.Status{
		Addr: "127.0.0.1:50051", Reachable: true, Version: "0.4.1",
		Kernel: "http://127.0.0.1:51234", Scheduler: &vc.Scheduler{Running: true},
		Plugins: vc.Tally{Total: 2, Up: 1, Failed: 1},
	}})

	mustContain(t, p.View(90, 20), "127.0.0.1:50051", "0.4.1", "http://127.0.0.1:51234", "running")
}

func TestOverviewMarksLastKnownWhenCoreIsGone(t *testing.T) {
	p := paneOf(t, SubjectAll, keymap.CtxOverview, Subject{Kind: SubjectAll})
	p = drive(p,
		RosterMsg{Roster: vc.Roster{Plugins: []vc.Plugin{{ID: "todo", State: vc.StateUp, Stats: true}}}},
		ErrMsg{Err: vc.Unreachable("127.0.0.1:50051", fmt.Errorf("connection refused"))},
	)

	mustContain(t, p.View(90, 20), "core unreachable", "last known", "todo")
}

func logsPaneFor(t *testing.T, s Subject) Pane {
	t.Helper()
	return paneOf(t, s.Kind, keymap.CtxLogs, s)
}

func logMsgs(source string, n int) []tea.Msg {
	out := make([]tea.Msg, 0, n)
	for i := 1; i <= n; i++ {
		out = append(out, LogMsg{Line: logtail.Line{
			Source: source,
			Text:   fmt.Sprintf("line %03d", i),
			At:     time.Now(),
		}})
	}
	return out
}

func TestLogsFollowShowsNewest(t *testing.T) {
	p := logsPaneFor(t, Subject{Kind: SubjectCore, ID: coreID})
	p = drive(p, logMsgs(coreID, 40)...)

	got := p.View(80, 10)
	mustContain(t, got, "line 040")
	mustNotContain(t, got, "line 001")
}

// The rule the whole pane exists to obey: once the reader has scrolled back,
// arriving lines must not yank the view to the bottom again.
func TestLogsScrollUpDisengagesFollow(t *testing.T) {
	p := logsPaneFor(t, Subject{Kind: SubjectCore, ID: coreID})
	p = drive(p, logMsgs(coreID, 60)...)
	p = drive(p, action(keymap.ActionSelectPrev), action(keymap.ActionSelectPrev))

	if c, _ := chipValue(p, "follow"); c.Active {
		t.Error("follow still engaged after scrolling up")
	}

	before := p.View(80, 10)
	p = drive(p, logMsgs(coreID, 5)...)
	if after := p.View(80, 10); after != before {
		t.Errorf("view moved under the reader\nbefore:\n%s\nafter:\n%s", before, after)
	}
}

func TestLogsFollowToggleSnapsBackToBottom(t *testing.T) {
	p := logsPaneFor(t, Subject{Kind: SubjectCore, ID: coreID})
	p = drive(p, logMsgs(coreID, 60)...)
	p = drive(p, action(keymap.ActionSelectPrev), action(keymap.ActionLogFollow))

	c, ok := chipValue(p, "follow")
	if !ok || !c.Active {
		t.Fatalf("follow chip = %+v, want active", c)
	}
	mustContain(t, p.View(80, 10), "line 060")
}

// Scrolling down is not the same gesture as scrolling up: it must never
// re-arm follow behind the reader's back either, but it must not be blocked.
func TestLogsScrollDownKeepsFollowOff(t *testing.T) {
	p := logsPaneFor(t, Subject{Kind: SubjectCore, ID: coreID})
	p = drive(p, logMsgs(coreID, 60)...)
	p = drive(p, action(keymap.ActionSelectPrev), action(keymap.ActionSelectNext))

	if c, _ := chipValue(p, "follow"); c.Active {
		t.Error("scrolling down re-armed follow")
	}
}

func TestLogsSearchNavigation(t *testing.T) {
	p := logsPaneFor(t, Subject{Kind: SubjectCore, ID: coreID})
	p = drive(p,
		LogMsg{Line: logtail.Line{Source: coreID, Text: "alpha one"}},
		LogMsg{Line: logtail.Line{Source: coreID, Text: "beta"}},
		LogMsg{Line: logtail.Line{Source: coreID, Text: "alpha two"}},
		LogMsg{Line: logtail.Line{Source: coreID, Text: "alpha three"}},
	)

	p = drive(p, action(keymap.ActionSearch),
		tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("alpha")},
		tea.KeyMsg{Type: tea.KeyEnter},
	)

	want := []string{"1/3", "2/3", "3/3", "1/3"}
	for i, w := range want {
		c, ok := chipValue(p, "search")
		if !ok {
			t.Fatal("no search chip")
		}
		if c.Value != "alpha "+w {
			t.Fatalf("step %d: search chip = %q, want %q", i, c.Value, "alpha "+w)
		}
		p = drive(p, action(keymap.ActionSearchNext))
	}

	// N is deliberately unbound in keymap, so it reaches the pane as a key
	// and means "the other direction".
	p = drive(p, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("N")})
	if c, _ := chipValue(p, "search"); c.Value != "alpha 1/3" {
		t.Errorf("after N search chip = %q, want %q", c.Value, "alpha 1/3")
	}
}

// Jumping to a match is a scroll, so it must turn follow off for the same
// reason scrolling up does: the reader is looking at something specific.
func TestLogsSearchDisengagesFollow(t *testing.T) {
	p := logsPaneFor(t, Subject{Kind: SubjectCore, ID: coreID})
	p = drive(p, logMsgs(coreID, 40)...)
	p = drive(p, action(keymap.ActionSearch),
		tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("line 003")},
		tea.KeyMsg{Type: tea.KeyEnter},
	)

	if c, _ := chipValue(p, "follow"); c.Active {
		t.Error("follow still engaged after jumping to a match")
	}
	mustContain(t, p.View(80, 10), "line 003")
}

func TestLogsSearchTypingDoesNotScroll(t *testing.T) {
	p := logsPaneFor(t, Subject{Kind: SubjectCore, ID: coreID})
	p = drive(p, logMsgs(coreID, 10)...)
	p = drive(p, action(keymap.ActionSearch),
		tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("lin")},
		tea.KeyMsg{Type: tea.KeyBackspace},
	)

	if c, _ := chipValue(p, "search"); c.Value != "li" {
		t.Errorf("search chip = %q, want %q", c.Value, "li")
	}
}

func TestLogsSourceFilterAndChips(t *testing.T) {
	p := logsPaneFor(t, Subject{Kind: SubjectAll})
	p = drive(p,
		LogMsg{Line: logtail.Line{Source: "core", Text: "from core"}},
		LogMsg{Line: logtail.Line{Source: "todo", Text: "from todo"}},
	)

	if _, ok := chipValue(p, "core"); !ok {
		t.Error("no per-source chip for core")
	}
	mustContain(t, p.View(90, 10), "from core", "from todo")

	// tab cycles the source filter: all -> core -> todo -> all.
	p = drive(p, tea.KeyMsg{Type: tea.KeyTab})
	got := p.View(90, 10)
	mustContain(t, got, "from core")
	mustNotContain(t, got, "from todo")
}

func TestLogsClear(t *testing.T) {
	p := logsPaneFor(t, Subject{Kind: SubjectCore, ID: coreID})
	p = drive(p, logMsgs(coreID, 5)...)
	p = drive(p, action(keymap.ActionClear))

	mustNotContain(t, p.View(80, 10), "line 005")
}

func TestLogsEmptyStateForPluginThatNeverRan(t *testing.T) {
	pl := vc.Plugin{ID: "todo", State: vc.StateDown, Stats: true}
	p := logsPaneFor(t, pluginSubject(pl))

	mustContain(t, p.View(80, 10), "no log yet")
}

func TestLogsWrapChipToggles(t *testing.T) {
	p := logsPaneFor(t, Subject{Kind: SubjectCore, ID: coreID})
	if c, _ := chipValue(p, "wrap"); c.Active {
		t.Error("wrap defaults on; long lines should be cut, not reflowed")
	}
	p = drive(p, action(keymap.ActionLogWrap))
	if c, _ := chipValue(p, "wrap"); !c.Active {
		t.Error("wrap did not toggle")
	}
}

func TestEventsPaneRendersCountersAndSaysWhatIsMissing(t *testing.T) {
	pl := vc.Plugin{
		ID: "vibecheck", State: vc.StateUp, EventsPublished: 12, EventsDelivered: 8,
		LastEventUnix: time.Now().Add(-30 * time.Second).Unix(), Stats: true,
	}
	p := paneOf(t, SubjectPlugin, keymap.CtxEvents, pluginSubject(pl))

	got := p.View(90, 20)
	mustContain(t, got, "published", "12", "delivered", "8", "no per-event detail")
}

func TestEventsPaneWithoutStats(t *testing.T) {
	pl := vc.Plugin{ID: "todo", State: vc.StateUp}
	p := paneOf(t, SubjectPlugin, keymap.CtxEvents, pluginSubject(pl))

	got := p.View(90, 20)
	mustContain(t, got, "kernel stats unavailable")
	mustNotContain(t, got, "published 0")
}

func TestAlertsNewestAtBottomWithResolvedURL(t *testing.T) {
	p := paneOf(t, SubjectAll, keymap.CtxAlerts, Subject{Kind: SubjectAll})
	p = drive(p,
		RosterMsg{Roster: vc.Roster{BaseURL: "http://127.0.0.1:51234"}},
		AlertMsg{Alert: vc.Alert{Received: time.Now(), Plugin: "todo", Title: "older", Level: "info"}},
		AlertMsg{Alert: vc.Alert{
			Received: time.Now(), Plugin: "vibecheck", Title: "newer", Level: "warn",
			Body:    "nail biting",
			Actions: []vc.AlertAction{{Label: "Open", URL: "dashboard"}},
		}},
	)

	got := p.View(100, 20)
	mustContain(t, got, "older", "newer", "nail biting", "http://127.0.0.1:51234/p/vibecheck/dashboard")
	if strings.Index(got, "older") > strings.Index(got, "newer") {
		t.Error("alerts are not oldest-first; newest must be at the bottom")
	}
}

func TestAlertsEmptyState(t *testing.T) {
	p := paneOf(t, SubjectAll, keymap.CtxAlerts, Subject{Kind: SubjectAll})
	mustContain(t, p.View(80, 10), "no alerts")
}

func TestAlertsLevelFilter(t *testing.T) {
	p := paneOf(t, SubjectAll, keymap.CtxAlerts, Subject{Kind: SubjectAll})
	p = drive(p,
		AlertMsg{Alert: vc.Alert{Plugin: "todo", Title: "chatter", Level: "info"}},
		AlertMsg{Alert: vc.Alert{Plugin: "todo", Title: "trouble", Level: "warn"}},
		tea.KeyMsg{Type: tea.KeyTab}, // all -> info
	)

	got := p.View(80, 10)
	mustContain(t, got, "chatter")
	mustNotContain(t, got, "trouble")
}

func schedule(name string, enabled bool, next time.Time) vc.Schedule {
	return vc.Schedule{
		ID: name + "-id", Name: name, Enabled: enabled, RRule: "FREQ=DAILY",
		NextExecution: &next, Notes: name + " notes",
	}
}

func TestSchedulesTableAndFilter(t *testing.T) {
	now := time.Now()
	p := paneOf(t, SubjectAll, keymap.CtxSchedules, Subject{Kind: SubjectAll})
	p = drive(p, SchedulesMsg{Schedules: []vc.Schedule{
		schedule("stretch", true, now.Add(2*time.Hour)),
		schedule("hydrate", false, now.Add(30*time.Minute)),
	}})

	got := p.View(100, 20)
	mustContain(t, got, "stretch", "hydrate", "FREQ=DAILY", "in ")

	// tab cycles all -> enabled -> paused.
	p = drive(p, tea.KeyMsg{Type: tea.KeyTab})
	got = p.View(100, 20)
	mustContain(t, got, "stretch")
	mustNotContain(t, got, "hydrate")
}

func TestSchedulesOpenShowsDetail(t *testing.T) {
	now := time.Now()
	p := paneOf(t, SubjectAll, keymap.CtxSchedules, Subject{Kind: SubjectAll})
	p = drive(p, SchedulesMsg{Schedules: []vc.Schedule{schedule("stretch", true, now.Add(time.Hour))}})
	p = drive(p, action(keymap.ActionOpen))

	mustContain(t, p.View(100, 20), "stretch notes")
}

func TestSchedulesEmptyState(t *testing.T) {
	p := paneOf(t, SubjectAll, keymap.CtxSchedules, Subject{Kind: SubjectAll})
	p = drive(p, SchedulesMsg{})
	mustContain(t, p.View(80, 10), "no schedules")
}

// Pausing is a write, and a pane may not perform one. It must say so rather
// than appearing to work.
func TestSchedulesPauseReportsItIsNotWired(t *testing.T) {
	p := paneOf(t, SubjectAll, keymap.CtxSchedules, Subject{Kind: SubjectAll})
	p = drive(p, SchedulesMsg{Schedules: []vc.Schedule{schedule("stretch", true, time.Now())}})

	next, cmd := p.Update(action(keymap.ActionPause))
	if next == nil || cmd == nil {
		t.Fatal("pause produced no command")
	}
	msg, ok := cmd().(NoticeMsg)
	if !ok || !strings.Contains(msg.Text, "pause") {
		t.Fatalf("pause produced %#v, want a NoticeMsg naming pause", msg)
	}
}

func TestRoutinesListAndSelectedActions(t *testing.T) {
	p := paneOf(t, SubjectAll, keymap.CtxRoutines, Subject{Kind: SubjectAll})
	p = drive(p, RoutinesMsg{Routines: []vc.Routine{
		{ID: "r1", Name: "morning", Enabled: true, Actions: []vc.Action{
			{ID: "a1", Name: "coffee", Type: "notify", Enabled: true},
		}},
		{ID: "r2", Name: "evening", Enabled: false},
	}})

	got := p.View(100, 24)
	mustContain(t, got, "morning", "evening", "coffee", "notify")

	p = drive(p, action(keymap.ActionSelectNext))
	mustContain(t, p.View(100, 24), "no actions")
}

func TestRoutinesEmptyState(t *testing.T) {
	p := paneOf(t, SubjectAll, keymap.CtxRoutines, Subject{Kind: SubjectAll})
	p = drive(p, RoutinesMsg{})
	mustContain(t, p.View(80, 10), "no routines")
}

func TestManifestPane(t *testing.T) {
	pl := vc.Plugin{ID: "todo", Name: "Todo", Icon: "checklist", UI: "webview", Path: "/p/todo/"}
	p := paneOf(t, SubjectPlugin, keymap.CtxManifest, pluginSubject(pl))

	got := p.View(90, 20)
	mustContain(t, got, "todo", "webview", "/p/todo/", "manifest.yaml")
}

// Every tab the keymap offers must resolve to a real pane, or the user finds
// a dead end. CtxActions is the one known gap and is named here so that
// filling it does not break this test.
func TestEveryTabHasAPane(t *testing.T) {
	for _, k := range []SubjectKind{SubjectAll, SubjectCore, SubjectPlugin} {
		for _, tab := range keymap.Tabs(k) {
			p := paneFor(k, tab.Ctx, PaneCtx{Subject: Subject{Kind: k}})
			if _, missing := p.(placeholderPane); missing && tab.Ctx != keymap.CtxActions {
				t.Errorf("%v/%s has no pane", k, tab.Ctx)
			}
			if p.KeyContext() != tab.Ctx {
				t.Errorf("%v/%s pane reports context %q", k, tab.Ctx, p.KeyContext())
			}
		}
	}
}

// A pane built without a theme is what the placeholder test in app_test.go
// does, and what a future caller will do by accident. It must render rather
// than dereference nil.
func TestPanesSurviveMissingTheme(t *testing.T) {
	for _, k := range []SubjectKind{SubjectAll, SubjectCore, SubjectPlugin} {
		for _, tab := range keymap.Tabs(k) {
			p := paneFor(k, tab.Ctx, PaneCtx{Subject: Subject{Kind: k}})
			if p.View(60, 10) == "" {
				t.Errorf("%v/%s rendered nothing without a theme", k, tab.Ctx)
			}
		}
	}
}
