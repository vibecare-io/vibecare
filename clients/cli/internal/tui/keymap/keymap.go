// Package keymap is the single source of truth for every key the TUI binds.
//
// Three surfaces show keys — the two-line footer, the `space` transient, and
// the `?` help screen — and all three render from the tables below. That is
// the whole point: a binding is declared exactly once, so the surfaces cannot
// drift apart, and no key string is written anywhere else in the TUI. Update
// handlers switch on Action, never on the rune the user pressed.
//
// The tables are ordinary Go values with no dependency on bubbletea, which is
// why the invariants that matter — no duplicate key inside one popup, nothing
// in the footer that the popup cannot reach — are table-tested directly.
package keymap

import (
	"strconv"
	"strings"
)

// SubjectKind is what the sidebar has selected. It lives here rather than in
// package tui because the tables are keyed by it and keymap must not import
// its own consumer; tui aliases these names back.
type SubjectKind int

const (
	// SubjectAll is the whole system: every plugin plus core.
	SubjectAll SubjectKind = iota
	// SubjectCore is the backend process itself.
	SubjectCore
	// SubjectPlugin is one plugin, the only subject that can be restarted.
	SubjectPlugin
)

func (k SubjectKind) String() string {
	switch k {
	case SubjectAll:
		return "all"
	case SubjectCore:
		return "core"
	case SubjectPlugin:
		return "plugin"
	}
	return "unknown"
}

// Focus is which half of the layout the keyboard is driving. It is the
// second dimension of every lookup: j means "next subject" on the left and
// "scroll" on the right, and a table keyed only by pane could not say that.
//
// Modelling it here rather than in the handlers is what keeps the promise
// this package makes — the footer, the transient and the help screen all
// render the keys for the CURRENT focus, so what is on screen is always what
// works.
type Focus int

const (
	// FocusSidebar drives the subject list: ALL, core, and each plugin.
	FocusSidebar Focus = iota
	// FocusDetail drives the tab strip and the pane under it.
	FocusDetail
)

func (f Focus) String() string {
	if f == FocusDetail {
		return "detail"
	}
	return "sidebar"
}

// Ctx identifies which pane has focus. It is a string so that a pane names
// its own context in one word and the tables read as prose.
type Ctx string

const (
	CtxOverview  Ctx = "overview"
	CtxStatus    Ctx = "status"
	CtxLogs      Ctx = "logs"
	CtxEvents    Ctx = "events"
	CtxAlerts    Ctx = "alerts"
	CtxSchedules Ctx = "schedules"
	CtxRoutines  Ctx = "routines"
	CtxActions   Ctx = "actions"
	CtxManifest  Ctx = "manifest"
	CtxStats     Ctx = "stats"
	CtxWatch     Ctx = "watch"
)

// Actions. The root model and the panes switch on these, so renaming a key
// is a one-line change in this file and renaming an action is a compile
// error at every handler — which is the safer direction for both.
const (
	ActionQuit       = "app.quit"
	ActionHelp       = "app.help"
	ActionTransient  = "app.transient"
	ActionCancel     = "app.cancel"
	ActionSearch     = "app.search"
	ActionSearchNext = "app.search.next"
	ActionGoto       = "app.goto"
	ActionZoom       = "app.zoom"

	ActionFocusDetail  = "focus.detail"
	ActionFocusSidebar = "focus.sidebar"

	ActionTabNext     = "tab.next"
	ActionTabPrev     = "tab.prev"
	ActionSelectNext  = "select.next"
	ActionSelectPrev  = "select.prev"
	ActionSubjectNext = "subject.next"
	ActionSubjectPrev = "subject.prev"

	// ActionTabJump is a prefix: the concrete actions are "tab.jump.0",
	// "tab.jump.1" and so on, resolved with TabIndex.
	ActionTabJump = "tab.jump."

	ActionRefresh       = "subject.refresh"
	ActionPluginRestart = "plugin.restart"
	ActionPluginDataDir = "plugin.datadir"
	ActionPluginUI      = "plugin.ui"
	ActionCoreVersion   = "core.version"

	ActionLogFollow = "log.follow"
	ActionLogTail   = "log.tail"
	ActionLogSince  = "log.since"
	ActionLogWrap   = "log.wrap"
	ActionClear     = "view.clear"
	ActionCopy      = "view.copy"
	ActionCopyAll   = "view.copy.all"
	ActionOpen      = "view.open"

	ActionAlertMute = "alert.mute"

	// ActionActionLog toggles the record of what this session has done.
	ActionActionLog = "app.actionlog"

	ActionPause     = "schedule.pause"
	ActionPauseAll  = "schedule.pause.all"
	ActionResume    = "schedule.resume"
	ActionResumeAll = "schedule.resume.all"

	ActionRun         = "run"
	ActionActionTypes = "action.types"
	ActionRoutineLogs = "routine.logs"
)

// Binding is one key and what it does. Key is the display form; Keys() is
// what a bubbletea KeyMsg is matched against, so the tables can show "←"
// while the runtime matches "left".
type Binding struct {
	Key  string
	Desc string
	// Help is the sentence the transient popup shows beside Desc. Desc is
	// the verb ("restart"); Help says what it actually does to the system
	// ("ask the kernel to respawn this plugin"). The footer has room for
	// only the verb, so the two are separate rather than one string that
	// would be truncated into uselessness in one place or padding in the
	// other. Empty Help simply renders no third column.
	Help   string
	Action string
}

// Keys returns the runtime key names this binding answers to. A Key of
// "a/b" binds both.
func (b Binding) Keys() []string {
	// "/" is itself a binding, so a single rune is never an alternation.
	if len([]rune(b.Key)) == 1 {
		return []string{normalize(b.Key)}
	}
	parts := strings.Split(b.Key, "/")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		out = append(out, normalize(p))
	}
	return out
}

// Matches reports whether key — a bubbletea KeyMsg.String() — triggers this
// binding.
func (b Binding) Matches(key string) bool {
	for _, k := range b.Keys() {
		if k == key {
			return true
		}
	}
	return false
}

// normalize maps a table's display form onto the name bubbletea reports.
// Only the glyphs appear here; letters are already their own key name.
func normalize(k string) string {
	switch k {
	case "←":
		return "left"
	case "→":
		return "right"
	case "↑":
		return "up"
	case "↓":
		return "down"
	case "⏎":
		return "enter"
	case "space":
		// bubbletea delivers the spacebar as a rune, not a named key.
		return " "
	}
	return k
}

// Group is one titled column of the transient popup.
type Group struct {
	Title    string
	Bindings []Binding
}

// Tab is one facet of the selected subject: the label in the tab strip and
// the pane context it selects. Tabs and bindings live in the same file so
// the jump keys in the transient cannot fall out of step with the strip.
type Tab struct {
	Name string
	Ctx  Ctx
}

var tabs = map[SubjectKind][]Tab{
	SubjectAll: {
		{"Overview", CtxOverview},
		{"Watch", CtxWatch},
		{"Logs", CtxLogs},
		{"Alerts", CtxAlerts},
		{"Schedules", CtxSchedules},
		{"Routines", CtxRoutines},
	},
	SubjectCore: {
		{"Status", CtxStatus},
		{"Logs", CtxLogs},
		{"Schedules", CtxSchedules},
		{"Routines", CtxRoutines},
		{"Actions", CtxActions},
	},
	SubjectPlugin: {
		{"Overview", CtxOverview},
		{"Logs", CtxLogs},
		{"Events", CtxEvents},
		{"Manifest", CtxManifest},
		{"Stats", CtxStats},
	},
}

// Tabs returns the facets of a subject of this kind, in strip order.
func Tabs(k SubjectKind) []Tab {
	src := tabs[k]
	out := make([]Tab, len(src))
	copy(out, src)
	return out
}

// TabIndex resolves a "tab.jump.N" action back to its strip position.
func TabIndex(action string) (int, bool) {
	if !strings.HasPrefix(action, ActionTabJump) {
		return 0, false
	}
	i, err := strconv.Atoi(strings.TrimPrefix(action, ActionTabJump))
	if err != nil {
		return 0, false
	}
	return i, true
}

// subjectGroups are the things you can do TO the selected subject. Only a
// plugin can be restarted, which is why "r" means restart under a plugin and
// refresh everywhere else — the same finger, the strongest available verb.
var subjectGroups = map[SubjectKind]Group{
	SubjectAll: {"Subject", []Binding{
		{"r", "refresh", "re-read core's status and roster now", ActionRefresh},
	}},
	SubjectCore: {"Core", []Binding{
		{"r", "refresh", "re-read core's status and roster now", ActionRefresh},
		{"v", "version", "show the running backend's build version", ActionCoreVersion},
	}},
	SubjectPlugin: {"Plugin", []Binding{
		{"r", "restart", "ask the kernel to respawn this plugin", ActionPluginRestart},
		{"d", "data dir", "reveal this plugin's ~/.vibecare/data directory", ActionPluginDataDir},
		{"u", "open ui", "open the plugin's own page in a browser", ActionPluginUI},
	}},
}

// ctxGroups are the controls of the focused pane.
var ctxGroups = map[Ctx]Group{
	CtxOverview: {"Overview", []Binding{
		{"⏎", "open", "open the selected row", ActionOpen},
		{"y", "copy", "copy what this pane is showing", ActionCopy},
	}},
	CtxStatus: {"Status", []Binding{
		{"y", "copy", "copy what this pane is showing", ActionCopy},
	}},
	CtxLogs: {"Logs", []Binding{
		{"f", "follow", "stick to the newest line as it arrives", ActionLogFollow},
		{"t", "tail", "how many lines to load with", ActionLogTail},
		{"s", "since", "only lines newer than a duration", ActionLogSince},
		{"w", "wrap", "wrap long lines instead of clipping", ActionLogWrap},
		{"c", "clear", "empty the view; the file is untouched", ActionClear},
		{"y", "copy line", "copy the highlighted line", ActionCopy},
		{"Y", "copy all", "copy every line currently held", ActionCopyAll},
	}},
	CtxEvents: {"Events", []Binding{
		{"f", "follow", "keep the counters live", ActionLogFollow},
		{"c", "clear", "empty the view; the file is untouched", ActionClear},
		{"y", "copy", "copy what this pane is showing", ActionCopy},
	}},
	CtxAlerts: {"Alerts", []Binding{
		{"f", "follow", "keep new alerts scrolling in", ActionLogFollow},
		{"c", "clear", "empty the view; the file is untouched", ActionClear},
		{"m", "mute desktop", "stop bridging alerts to the desktop", ActionAlertMute},
		{"y", "copy", "copy what this pane is showing", ActionCopy},
	}},
	CtxSchedules: {"Schedules", []Binding{
		{"⏎", "show", "show this schedule and its actions", ActionOpen},
		{"p", "pause", "stop this schedule from firing", ActionPause},
		{"P", "pause all", "stop every schedule from firing", ActionPauseAll},
		{"e", "resume", "let this schedule fire again", ActionResume},
		{"E", "resume all", "let every schedule fire again", ActionResumeAll},
	}},
	CtxRoutines: {"Routines", []Binding{
		{"⏎", "show", "show this routine and its actions", ActionOpen},
		{"x", "run", "execute this routine now", ActionRun},
		{"e", "run log", "past executions of this routine", ActionRoutineLogs},
	}},
	CtxActions: {"Actions", []Binding{
		{"⏎", "show", "show this action's type and parameters", ActionOpen},
		{"x", "run", "execute this action now", ActionRun},
		{"t", "types", "list the action types core supports", ActionActionTypes},
	}},
	CtxManifest: {"Manifest", []Binding{
		{"y", "copy", "copy what this pane is showing", ActionCopy},
		{"o", "open file", "open manifest.yaml in your editor", ActionOpen},
	}},
	CtxWatch: {"Watch", []Binding{
		{"f", "follow", "stick to the newest event as it arrives", ActionLogFollow},
		{"c", "clear", "empty the view; nothing is stored anyway", ActionClear},
		{"y", "copy", "copy the highlighted event", ActionCopy},
		{"Y", "copy all", "copy every event currently held", ActionCopyAll},
	}},
	CtxStats: {"Stats", []Binding{
		{"y", "copy", "copy what this pane is showing", ActionCopy},
	}},
}

// navGroup moves between things. Subject movement gets brackets rather than
// shifted arrows because a terminal that swallows shift+↑ would silently
// remove the only way to change subject from the keyboard.
// navFor is the movement half of the keymap, and the only place the two
// focuses genuinely disagree about what a key means.
//
// The same fingers do the same shape of thing on both sides — j/k move along
// the list you are in, h/l move across — but "the list you are in" is the
// subject list on the left and the pane's own content on the right, and
// "across" is entering the panel on the left and walking the tab strip on
// the right. That is why this is a function of Focus rather than one table:
// binding j to a single action would force one of the two halves to be
// wrong.
//
// The arrow keys stay bound alongside the vim keys throughout. This adds a
// way to drive the UI; it does not take away the one already in the footer.
func navFor(f Focus) Group {
	if f == FocusDetail {
		return Group{"Move", []Binding{
			{"h/←", "prev tab", "", ActionTabPrev},
			{"l/→", "next tab", "", ActionTabNext},
			{"j/↓", "down", "", ActionSelectNext},
			{"k/↑", "up", "", ActionSelectPrev},
			// Subject movement stays reachable from inside the panel so
			// comparing two plugins' logs does not mean leaving and
			// re-entering it for every switch.
			{"[", "prev subject", "", ActionSubjectPrev},
			{"]", "next subject", "", ActionSubjectNext},
			{"tab", "focus list", "", ActionFocusSidebar},
			{"z", "zoom", "", ActionZoom},
		}}
	}
	return Group{"Move", []Binding{
		{"j/↓", "next subject", "", ActionSubjectNext},
		{"k/↑", "prev subject", "", ActionSubjectPrev},
		// [ and ] stay bound on both sides. They are aliases here rather
		// than the only way, so a hand already trained on them keeps
		// working and the same two keys mean the same thing wherever focus
		// happens to be.
		{"[", "prev subject", "", ActionSubjectPrev},
		{"]", "next subject", "", ActionSubjectNext},
		{"tab/l/→", "focus panel", "", ActionFocusDetail},
		{"z", "zoom", "", ActionZoom},
	}}
}

// globalFor is the same set of keys in both focuses; only esc's DESCRIPTION
// changes. esc keeps one action deliberately: it closes whatever is open —
// help, the transient, a search — and only falls through to leaving the
// panel when nothing is. Binding it to a second action per focus would make
// "esc" ambiguous at exactly the moment a user reaches for it to get out of
// something.
func globalFor(f Focus) Group {
	esc := Binding{"esc", "cancel", "close whatever is open", ActionCancel}
	if f == FocusDetail {
		esc.Desc = "back to list"
	}
	return Group{"Global", []Binding{
		{"/", "search", "filter what this pane is showing", ActionSearch},
		{"n", "next match", "jump to the next search hit", ActionSearchNext},
		{"g", "goto subject", "jump to a subject by name", ActionGoto},
		{"a", "action log", "what this session has done so far", ActionActionLog},
		{"space", "actions", "this popup", ActionTransient},
		{"?", "help", "every key, grouped", ActionHelp},
		esc,
		{"q", "quit", "leave; core keeps running", ActionQuit},
	}}
}

// viewGroup is generated from the subject's tabs, so adding a tab adds its
// jump key. Digits rather than initials: the tab names change with the
// subject, and letters chosen per subject would collide with that subject's
// own verbs.
func viewGroup(k SubjectKind) Group {
	src := tabs[k]
	g := Group{Title: "View", Bindings: make([]Binding, 0, len(src))}
	for i, t := range src {
		g.Bindings = append(g.Bindings, Binding{
			Key:    strconv.Itoa(i + 1),
			Desc:   strings.ToLower(t.Name),
			Action: ActionTabJump + strconv.Itoa(i),
		})
	}
	return g
}

// For returns the transient's contents for a focused pane and a selected
// subject, in render order: what you can do to the subject, where you can go
// inside it, what this pane does, how to move, and the always-there keys.
//
// The result is a deep copy. Callers hold it while rendering and must not be
// able to write through it into the tables every other surface reads.
// For is the TRANSIENT POPUP's contents: the things you can DO here. It is
// deliberately not everything that is bound.
//
// Movement and the always-available chrome are excluded because they are
// already on screen permanently in the footer, and including them made the
// popup taller than the terminal — at which point it silently clipped the
// group that mattered. A menu you have to scroll is a worse menu than one
// that fits, and "what can I do to this thing" is a different question from
// "what does every key do". The second question is what `?` is for; see All.
func For(c Ctx, k SubjectKind, f Focus) []Group {
	var out []Group
	if g, ok := subjectGroups[k]; ok {
		out = append(out, cloneGroup(g))
	}
	out = append(out, viewGroup(k))
	// The pane's own controls are only offered when the pane has focus. On
	// the sidebar they would be a list of keys that do nothing, which is
	// worse than a shorter popup.
	if g, ok := ctxGroups[c]; ok && f == FocusDetail {
		out = append(out, cloneGroup(g))
	}
	return out
}

// All is every binding that resolves in this context, popup contents plus
// the movement and global keys. Lookup and the `?` help screen use it, so a
// key stays bound whether or not the popup chose to advertise it.
func All(c Ctx, k SubjectKind, f Focus) []Group {
	return append(For(c, k, f), navFor(f), globalFor(f))
}

func cloneGroup(g Group) Group {
	b := make([]Binding, len(g.Bindings))
	copy(b, g.Bindings)
	return Group{Title: g.Title, Bindings: b}
}

// footerCommon is the handful of keys worth a permanent line. Subject-kind
// specific keys are deliberately absent: the footer must read the same
// whichever row the sidebar has selected, and the transient is one keypress
// away for the rest.
func footerCommon(f Focus) []Binding {
	if f == FocusDetail {
		return []Binding{
			{"h/←", "prev tab", "", ActionTabPrev},
			{"l/→", "next tab", "", ActionTabNext},
			{"[", "prev subject", "", ActionSubjectPrev},
			{"]", "next subject", "", ActionSubjectNext},
			{"tab", "focus list", "", ActionFocusSidebar},
			{"z", "zoom", "", ActionZoom},
			{"/", "search", "", ActionSearch},
			{"space", "actions", "", ActionTransient},
			{"?", "help", "", ActionHelp},
			{"q", "quit", "", ActionQuit},
		}
	}
	return []Binding{
		{"j/↓", "next subject", "", ActionSubjectNext},
		{"k/↑", "prev subject", "", ActionSubjectPrev},
		{"tab/l/→", "focus panel", "", ActionFocusDetail},
		{"z", "zoom", "", ActionZoom},
		{"space", "actions", "", ActionTransient},
		{"?", "help", "", ActionHelp},
		{"q", "quit", "", ActionQuit},
	}
}

// Footer returns the two-line footer for a focused pane: the pane's own
// controls first, then the common keys. Every entry is by construction a
// binding For() also returns, which the tests assert.
func Footer(c Ctx, f Focus) []Binding {
	var out []Binding
	// Pane controls only when the pane is what the keyboard is driving;
	// advertising them from the sidebar would list keys that do nothing.
	if g, ok := ctxGroups[c]; ok && f == FocusDetail {
		out = append(out, g.Bindings...)
	}
	return append(out, footerCommon(f)...)
}

// Lookup resolves a pressed key in this context. Returns false when the key
// is unbound, which is the root model's signal to hand the event to the pane.
func Lookup(c Ctx, k SubjectKind, f Focus, key string) (Binding, bool) {
	for _, g := range All(c, k, f) {
		for _, b := range g.Bindings {
			if b.Matches(key) {
				return b, true
			}
		}
	}
	return Binding{}, false
}
