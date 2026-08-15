package tui

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/vibecare-io/vibecare/clients/cli/internal/logtail"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
)

// logsPane is the pane people actually live in. Everything here serves one
// rule: the view never moves unless the reader moved it. Follow is a mode
// the reader turns on, and any backward scroll turns it off — silently
// yanking the viewport back to the bottom while someone is reading a stack
// trace is the single most infuriating bug a log viewer can have.
//
// The pane holds lines and nothing else; the tail itself is a goroutine
// started by cmds.go, which is why this file can be tested with no files on
// disk.

// tailSizes is what the `t` key cycles through — how much scrollback is kept
// in memory, not what the tail command opened with.
var tailSizes = []int{200, 500, 1000, 5000}

// sinceSteps is the `s` filter: how recent a line has to be to show. Zero is
// "everything", and it is first because that is the default.
var sinceSteps = []time.Duration{0, 5 * time.Minute, 15 * time.Minute, time.Hour}

const (
	// sourceColumn caps the prefix width so one long plugin id does not
	// steal half the screen from the text it is labelling.
	sourceColumn = 12
	logTimeFmt   = "15:04:05"
)

type logsPane struct {
	th      *theme.Theme
	subject Subject

	lines []logtail.Line
	// sources is discovery-ordered, because the filter cycles through it and
	// a set that reorders itself would move the chip under the finger.
	sources []string
	filter  string

	follow bool
	wrap   bool
	tail   int
	since  time.Duration
	// top is the first visible line while not following. It is only ever
	// changed by something the reader did.
	top  int
	winH int

	query    string
	typing   bool
	matchIdx int

	stale bool
}

func init() {
	for _, k := range []SubjectKind{SubjectAll, SubjectCore, SubjectPlugin} {
		Register(k, keymap.CtxLogs, func(p PaneCtx) Pane {
			return logsPane{
				th:      paneTheme(p.Theme),
				subject: p.Subject,
				follow:  true,
				tail:    tailLines,
				winH:    20,
			}
		})
	}
}

func (p logsPane) Init(PaneCtx) tea.Cmd   { return nil }
func (p logsPane) Title() string          { return "Logs" }
func (p logsPane) KeyContext() keymap.Ctx { return keymap.CtxLogs }

func (p logsPane) Chips() []Chip {
	chips := []Chip{
		{Label: "follow", Active: p.follow},
		{Label: "tail", Value: strconv.Itoa(p.tail)},
		{Label: "wrap", Active: p.wrap},
	}
	if p.since > 0 {
		chips = append(chips, Chip{Label: "since", Active: true, Value: humanAge(p.since)})
	}
	if p.typing || p.query != "" {
		chips = append(chips, Chip{Label: "search", Active: true, Value: p.searchLabel()})
	}
	if p.showSources() {
		chips = append(chips, Chip{Label: "all", Active: p.filter == "", Filter: true})
		for _, s := range p.sources {
			chips = append(chips, Chip{Label: s, Active: p.filter == s, Filter: true})
		}
	}
	return chips
}

// searchLabel is the query while it is being typed and the query plus the
// reader's position once it is committed. Counting while typing would make
// the chip flicker through every prefix of the word.
func (p logsPane) searchLabel() string {
	if p.typing || p.query == "" {
		return p.query
	}
	n := len(p.matches(p.visible()))
	if n == 0 {
		return p.query + " 0/0"
	}
	return fmt.Sprintf("%s %d/%d", p.query, p.matchIdx+1, n)
}

func (p logsPane) Update(msg tea.Msg) (Pane, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		if h := msg.Height - headerLines - footerLines - chromeLines; h > 0 {
			p.winH = h
		}

	case LogMsg:
		p.append(msg.Line)

	case RosterMsg:
		p.stale = false
		if p.subject.Kind == SubjectAll {
			// Knowing a source exists before it has said anything is what
			// lets the reader filter to a plugin that is silent — which is
			// usually the one they are worried about.
			p.addSource(coreID)
			for _, pl := range msg.Roster.Plugins {
				p.addSource(pl.ID)
			}
		}

	case ErrMsg:
		if unreachable(msg.Err) {
			p.stale = true
		}

	case ActionMsg:
		return p.act(msg.Action)

	case tea.KeyMsg:
		return p.key(msg)
	}
	return p, nil
}

func (p *logsPane) append(l logtail.Line) {
	p.lines = append(p.lines, l)
	p.addSource(l.Source)
	if over := len(p.lines) - p.tail; over > 0 {
		p.lines = p.lines[over:]
		// Dropping from the front moves every index, including the reader's.
		p.top -= over
		if p.top < 0 {
			p.top = 0
		}
	}
}

func (p *logsPane) addSource(id string) {
	if id == "" {
		return
	}
	for _, s := range p.sources {
		if s == id {
			return
		}
	}
	p.sources = append(p.sources, id)
}

func (p logsPane) act(a string) (Pane, tea.Cmd) {
	switch a {
	case keymap.ActionLogFollow:
		p.follow = !p.follow

	case keymap.ActionLogWrap:
		p.wrap = !p.wrap

	case keymap.ActionLogTail:
		p.tail = nextIn(tailSizes, p.tail)
		if over := len(p.lines) - p.tail; over > 0 {
			p.lines = p.lines[over:]
			p.top = 0
		}

	case keymap.ActionLogSince:
		p.since = nextDurationIn(sinceSteps, p.since)

	case keymap.ActionClear:
		p.lines, p.top, p.matchIdx = nil, 0, 0

	case keymap.ActionSelectPrev:
		p.scroll(-1)

	case keymap.ActionSelectNext:
		p.scroll(1)

	case keymap.ActionSearch:
		p.typing, p.query, p.matchIdx = true, "", 0

	case keymap.ActionSearchNext:
		p.jump(1)

	case keymap.ActionCopy, keymap.ActionCopyAll:
		return p, noticeCmd("copy needs a clipboard command in cmds.go")
	}
	return p, nil
}

func (p logsPane) key(msg tea.KeyMsg) (Pane, tea.Cmd) {
	if p.typing {
		switch msg.Type {
		case tea.KeyRunes, tea.KeySpace:
			p.query += string(msg.Runes)
		case tea.KeyBackspace:
			if n := len(p.query); n > 0 {
				p.query = p.query[:n-1]
			}
		case tea.KeyEnter:
			p.typing = false
			p.matchIdx = 0
			p.jump(0)
		}
		return p, nil
	}

	switch msg.String() {
	case "N":
		p.jump(-1)
	case "k":
		p.scroll(-1)
	case "j":
		p.scroll(1)
	case "pgup":
		p.scroll(-p.winH)
	case "pgdown":
		p.scroll(p.winH)
	case "home":
		p.follow = false
		p.top = 0
	case "end":
		p.top = len(p.visible())
	case "tab":
		p.filter = nextSource(p.sources, p.filter)
		p.top = 0
	}
	return p, nil
}

// scroll moves the viewport by d lines. Any backward movement disengages
// follow; forward movement does not re-engage it, because re-arming a mode
// the reader turned off is the same surprise in the other direction.
func (p *logsPane) scroll(d int) {
	n := len(p.visible())
	if p.follow {
		if d >= 0 {
			return
		}
		p.follow = false
		p.top = n - p.winH
	}
	p.top += d
	if p.top > n-1 {
		p.top = n - 1
	}
	if p.top < 0 {
		p.top = 0
	}
}

// jump moves to the dir'th next match and puts it in the middle of the view.
// It is a scroll, so it turns follow off for exactly the same reason.
func (p *logsPane) jump(dir int) {
	vis := p.visible()
	m := p.matches(vis)
	if len(m) == 0 {
		return
	}
	p.matchIdx = ((p.matchIdx+dir)%len(m) + len(m)) % len(m)
	p.follow = false
	p.top = m[p.matchIdx] - p.winH/2
	if p.top < 0 {
		p.top = 0
	}
}

// visible applies the source and since filters. It is recomputed rather than
// cached because every filter change would have to invalidate the cache, and
// a stale cache here shows the reader lines that are not there.
func (p logsPane) visible() []logtail.Line {
	if p.filter == "" && p.since == 0 {
		return p.lines
	}
	cutoff := time.Now().Add(-p.since)
	out := make([]logtail.Line, 0, len(p.lines))
	for _, l := range p.lines {
		if p.filter != "" && l.Source != p.filter {
			continue
		}
		if p.since > 0 && !l.At.IsZero() && l.At.Before(cutoff) {
			continue
		}
		out = append(out, l)
	}
	return out
}

// matches returns the indices of the lines containing the query, folded to
// lower case: a reader searching for "error" means ERROR too.
func (p logsPane) matches(vis []logtail.Line) []int {
	if p.query == "" {
		return nil
	}
	q := strings.ToLower(p.query)
	var out []int
	for i, l := range vis {
		if strings.Contains(strings.ToLower(l.Text), q) {
			out = append(out, i)
		}
	}
	return out
}

func (p logsPane) showSources() bool {
	return p.subject.Kind == SubjectAll || len(p.sources) > 1
}

func (p logsPane) View(w, h int) string {
	vis := p.visible()
	head, avail := "", h
	if p.stale {
		head = p.th.Bad.Render("core unreachable — showing last known") + "\n"
		avail--
	}
	if avail < 1 {
		return clamp(head, w, h)
	}

	if len(vis) == 0 {
		return clamp(head+p.th.Dim.Render(p.emptyText()), w, h)
	}

	start := p.top
	if p.follow {
		start = len(vis) - avail
	}
	if start > len(vis)-avail {
		start = len(vis) - avail
	}
	if start < 0 {
		start = 0
	}

	cur := -1
	if m := p.matches(vis); len(m) > 0 && p.matchIdx < len(m) {
		cur = m[p.matchIdx]
	}

	prefixW := 0
	if p.showSources() {
		for _, s := range p.sources {
			if n := len(s); n > prefixW {
				prefixW = n
			}
		}
		if prefixW > sourceColumn {
			prefixW = sourceColumn
		}
	}

	out := make([]string, 0, avail)
	for i := start; i < len(vis) && len(out) < avail; i++ {
		for _, seg := range p.renderLine(vis[i], i == cur, prefixW, w) {
			if len(out) == avail {
				break
			}
			out = append(out, seg)
		}
	}
	return clamp(head+strings.Join(out, "\n"), w, h)
}

// renderLine turns one line into the rows it occupies: one when cutting,
// possibly several when wrapping.
func (p logsPane) renderLine(l logtail.Line, current bool, prefixW, w int) []string {
	gutter := " "
	if current {
		gutter = cursor
	}

	head := gutter
	if !l.At.IsZero() {
		head += p.th.Dim.Render(l.At.Format(logTimeFmt)) + " "
	}
	if prefixW > 0 {
		head += p.th.Dim.Render(pad(clamp(l.Source, prefixW, 1), prefixW) + " │ ")
	}

	text := p.highlight(l.Text)
	if !p.wrap {
		return []string{clamp(head+text, w, 1)}
	}

	// Wrapping is applied to the raw text and the highlight re-applied per
	// row: splitting styled text would cut an escape sequence in half.
	body := w - lipgloss.Width(head)
	if body < 1 {
		body = 1
	}
	var rows []string
	indent := strings.Repeat(" ", lipgloss.Width(head))
	for i, chunk := range chunkRunes(l.Text, body) {
		lead := head
		if i > 0 {
			lead = indent
		}
		rows = append(rows, clamp(lead+p.highlight(chunk), w, 1))
	}
	if len(rows) == 0 {
		rows = append(rows, clamp(head, w, 1))
	}
	return rows
}

// highlight marks every occurrence of the query with reverse video. Reverse
// rather than a colour because the palette is the theme's to pick and a
// match has to stand out against whatever the line is already coloured.
func (p logsPane) highlight(s string) string {
	if p.query == "" {
		return s
	}
	q := strings.ToLower(p.query)
	low := strings.ToLower(s)
	style := lipgloss.NewStyle().Reverse(true)

	var b strings.Builder
	for {
		i := strings.Index(low, q)
		if i < 0 {
			b.WriteString(s)
			return b.String()
		}
		b.WriteString(s[:i])
		b.WriteString(style.Render(s[i : i+len(q)]))
		s, low = s[i+len(q):], low[i+len(q):]
	}
}

// emptyText says why there is nothing, which is nearly always the question
// being asked when a log pane is empty.
func (p logsPane) emptyText() string {
	if p.filter != "" {
		return "no lines from " + p.filter + " yet"
	}
	if pl := p.subject.Plugin; pl != nil && pl.Stats && pl.LogPath == "" {
		return "this plugin has never run, so it has no log yet"
	}
	if p.stale {
		return "core is unreachable, so no log source could be resolved"
	}
	return "waiting for log lines…"
}

// nextIn and nextDurationIn cycle a chip through its steps, restarting from
// the first when the current value is not one of them.
func nextIn(steps []int, cur int) int {
	for i, s := range steps {
		if s == cur {
			return steps[(i+1)%len(steps)]
		}
	}
	return steps[0]
}

func nextDurationIn(steps []time.Duration, cur time.Duration) time.Duration {
	for i, s := range steps {
		if s == cur {
			return steps[(i+1)%len(steps)]
		}
	}
	return steps[0]
}

// nextSource cycles "all" and each known source, in discovery order.
func nextSource(sources []string, cur string) string {
	if len(sources) == 0 {
		return ""
	}
	if cur == "" {
		return sources[0]
	}
	for i, s := range sources {
		if s == cur {
			if i+1 == len(sources) {
				return ""
			}
			return sources[i+1]
		}
	}
	return ""
}

// chunkRunes splits by printed runes rather than bytes so a multi-byte
// character is never cut in half.
func chunkRunes(s string, n int) []string {
	if n < 1 {
		n = 1
	}
	r := []rune(s)
	var out []string
	for len(r) > n {
		out = append(out, string(r[:n]))
		r = r[n:]
	}
	if len(r) > 0 {
		out = append(out, string(r))
	}
	return out
}
