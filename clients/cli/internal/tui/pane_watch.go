package tui

import (
	"fmt"
	"hash/fnv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/keymap"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui/theme"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// watchPane is the bus firehose: every event any plugin publishes, as it
// happens, whether or not anything subscribed to it.
//
// It answers the question the logs pane cannot. A log says what a plugin
// chose to write down; this says what it actually put on the wire, which is
// how you find a plugin publishing a topic nobody listens to — from the
// outside that is indistinguishable from a plugin doing nothing at all.
//
// Nothing is stored anywhere: core retains no events, so this view starts
// from the moment it opens. That is deliberate rather than a gap — a replay
// buffer is always the wrong size, and for a debugging tool "make it happen
// again" is an honest instruction.
type watchPane struct {
	th      *theme.Theme
	subject Subject

	events []vc.Event
	// topics is discovery-ordered so the filter chips do not reshuffle
	// under the finger as new topics appear.
	topics []string
	filter string

	follow bool
	top    int
	winH   int
	sel    int
}

// watchMax bounds the scrollback. A session left open all day on a busy bus
// must not grow without limit, and nobody scrolls back past a few thousand
// events in a live tail.
const watchMax = 2000

func init() {
	Register(SubjectAll, keymap.CtxWatch, func(p PaneCtx) Pane {
		return watchPane{th: paneTheme(p.Theme), subject: p.Subject, follow: true}
	})
}

func (p watchPane) Init(PaneCtx) tea.Cmd   { return nil }
func (p watchPane) Title() string          { return "Watch" }
func (p watchPane) KeyContext() keymap.Ctx { return keymap.CtxWatch }

func (p watchPane) Chips() []Chip {
	chips := []Chip{
		{Label: "follow", Active: p.follow},
		{Label: "events", Value: fmt.Sprintf("%d", len(p.events))},
	}
	chips = append(chips, Chip{Label: "all", Active: p.filter == "", Filter: true})
	for _, t := range p.topics {
		chips = append(chips, Chip{Label: t, Active: p.filter == t, Filter: true})
	}
	return chips
}

func (p watchPane) Update(msg tea.Msg) (Pane, tea.Cmd) {
	switch msg := msg.(type) {
	case EventMsg:
		p.events = append(p.events, msg.Event)
		if len(p.events) > watchMax {
			p.events = p.events[len(p.events)-watchMax:]
		}
		if !containsStr(p.topics, msg.Event.Topic) {
			p.topics = append(p.topics, msg.Event.Topic)
		}

	case tea.WindowSizeMsg:
		if h := msg.Height - headerLines - footerLines - chromeLines; h > 0 {
			p.winH = h
		}

	case ActionMsg:
		return p.act(msg.Action)
	}
	return p, nil
}

func (p watchPane) act(action string) (Pane, tea.Cmd) {
	switch action {
	case keymap.ActionLogFollow:
		p.follow = !p.follow
	case keymap.ActionClear:
		p.events = nil
		p.top, p.sel = 0, 0
	case keymap.ActionSelectNext:
		p = p.scroll(1)
	case keymap.ActionSelectPrev:
		p = p.scroll(-1)
	case keymap.ActionCopy, keymap.ActionCopyAll:
		return p, noticeCmd("copy needs a clipboard command in cmds.go")
	}
	return p, nil
}

// scroll moves the view. Any backward movement disengages follow, for the
// same reason it does in the logs pane: yanking someone back to the bottom
// while they are reading is the single most infuriating thing a live tail
// can do.
func (p watchPane) scroll(d int) watchPane {
	if d < 0 && p.follow {
		p.follow = false
		p.top = maxInt(0, len(p.visible())-p.rows())
	}
	p.top = clampInt(p.top+d, 0, maxInt(0, len(p.visible())-p.rows()))
	return p
}

func (p watchPane) rows() int {
	if p.winH > 0 {
		return p.winH
	}
	return 20
}

func (p watchPane) visible() []vc.Event {
	if p.filter == "" {
		return p.events
	}
	out := make([]vc.Event, 0, len(p.events))
	for _, e := range p.events {
		if e.Topic == p.filter {
			out = append(out, e)
		}
	}
	return out
}

func (p watchPane) View(w, h int) string {
	events := p.visible()
	if len(events) == 0 {
		return clamp(p.th.Dim.Render(
			"watching the bus — nothing published yet\n\n"+
				"  every event any plugin fires shows here, including ones\n"+
				"  no plugin subscribed to. core keeps none, so this starts\n"+
				"  from the moment you opened it."), w, h)
	}

	from := p.top
	if p.follow {
		from = maxInt(0, len(events)-h)
	}
	from = clampInt(from, 0, maxInt(0, len(events)-1))
	to := minInt(len(events), from+h)

	lines := make([]string, 0, to-from)
	for _, e := range events[from:to] {
		lines = append(lines, p.row(e, w))
	}
	return clamp(strings.Join(lines, "\n"), w, h)
}

// row renders one event: when, who, what, and as much of the payload as
// fits. The topic is the thing the eye is scanning for, so it is the one
// part that gets a colour of its own.
func (p watchPane) row(e vc.Event, w int) string {
	ts := p.th.Dim.Render(e.At.Format("15:04:05.000"))
	who := p.th.Item.Render(padPlain(e.Plugin, 12))
	topic := topicStyle(e.Topic, p.th).Render(e.Topic)

	row := ts + " " + who + " " + topic
	if body := payloadPreview(e.Payload); body != "" {
		if room := w - lipgloss.Width(row) - 2; room > 8 {
			row += "  " + p.th.Dim.Render(clampLine(body, room))
		}
	}
	return clampLine(row, w)
}

// payloadPreview flattens a payload onto one line. Newlines and tabs are
// turned into spaces rather than escaped: this is a glance, and \n rendered
// literally costs two columns to say nothing.
func payloadPreview(s string) string {
	if s == "" {
		return ""
	}
	r := strings.NewReplacer("\n", " ", "\r", " ", "\t", " ")
	return strings.Join(strings.Fields(r.Replace(s)), " ")
}

// topicPalette is the set a topic can be coloured from. ANSI slots, so the
// user's own terminal theme still applies — the same reason the rest of this
// package avoids hex.
var topicPalette = []lipgloss.Color{"2", "3", "4", "5", "6", "10", "11", "12", "13", "14"}

// topicStyle gives a topic a stable colour derived from its name, so
// `todo.created.v1` is the same colour every time it appears and in every
// session. A rotating palette assigned in arrival order would look the same
// but mean nothing: the point is that the eye can lock onto one topic in a
// fast-moving stream without reading it.
func topicStyle(topic string, th *theme.Theme) lipgloss.Style {
	h := fnv.New32a()
	_, _ = h.Write([]byte(topic))
	return lipgloss.NewStyle().Foreground(topicPalette[int(h.Sum32())%len(topicPalette)]).Bold(true)
}

func containsStr(ss []string, s string) bool {
	for _, v := range ss {
		if v == s {
			return true
		}
	}
	return false
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func clampInt(v, lo, hi int) int {
	return maxInt(lo, minInt(hi, v))
}

var _ = time.Now
