// Package vc is the Go SDK for authoring VibeCare plugins.
//
// A plugin is a subprocess that core spawns. It is ALWAYS a gRPC client and
// NEVER a gRPC server: it serves HTTP for its UI and makes three outbound
// calls (Register, Publish, Alert). That asymmetry is what keeps plugins
// cheap to write in any language — there are no service stubs to implement.
//
// The whole of a minimal plugin:
//
//	func main() {
//	    h, err := vc.Connect()          // reads env, registers, reconnects on drop,
//	    if err != nil { log.Fatal(err) } // serves /health, returns handle + listener
//	    http.HandleFunc("/", serveUI)
//	    http.Serve(h.Listener, nil)
//	}
package vc

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/vibecare-io/vibecare/backend/pkg/pluginwire"
	pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

var (
	// reconnectBase is the first reconnect delay; it doubles up to
	// reconnectMax. A var so tests can shrink it.
	reconnectBase = time.Second
	reconnectMax  = 30 * time.Second
	// reconnectStable is how long a session must stay connected before the
	// ladder resets to reconnectBase on its next drop, mirroring
	// Supervisor.stableUptime's reasoning in the kernel: a drop after
	// running fine for a while is a fresh problem, not a continuation of
	// whatever caused an earlier flapping streak, and earns the fast retry
	// again rather than whatever the ladder had climbed to. Without this, a
	// plugin that has reconnected a handful of times over its lifetime —
	// each drop entirely unrelated to the last — waits the full
	// reconnectMax on every later one. A var so tests can shrink it.
	reconnectStable = 60 * time.Second
	// readyTimeout bounds how long Connect waits for core's Ready. Core
	// kills an unregistered plugin after 10s anyway.
	readyTimeout = 10 * time.Second
)

// eventChanCap bounds the plugin's inbound queue. Events are
// fire-and-forget; a plugin that stops reading drops them rather than
// growing without bound.
const eventChanCap = 64

// Event is one delivery from the bus.
type Event struct {
	Topic   string
	Payload []byte
	TS      time.Time
}

// AlertAction is a button. URL is plugin-relative: pressing it navigates
// the client to /p/<plugin>/<url>.
type AlertAction struct {
	Label string
	URL   string
}

// Alert is a native, transient notification. It is the one UI path that is
// not HTML, because it must render with no window open.
type Alert struct {
	Title   string
	Body    string
	Level   string // "info" | "warn"
	Actions []AlertAction

	// Style is the typed, checked way to ask for a particular look. Nil
	// means "no opinion" and the client renders its default alert. Prefer
	// this over Appearance: every field is documented with its valid
	// values, units and client-side default, and the two enums are named
	// types, so a typo is a compile error instead of a field the client
	// silently drops.
	//
	// PRECEDENCE: if both Style and Appearance are set, Style WINS —
	// Appearance is not merged into it, not appended to it, and not sent.
	// The typed value is the one a reader can check, so it is the one that
	// gets to be authoritative; a raw blob left over from older code never
	// silently overrides a field someone set deliberately.
	Style *Appearance

	// Appearance is the raw escape hatch: an opaque, plugin-defined
	// presentation hint forwarded to the client verbatim; core never parses
	// it. Nil means "no opinion" and the client renders its own default
	// alert — which is a different thing from a pointer to "", so this is a
	// *string rather than a string.
	//
	// Use it only for a key the client understands but this SDK's
	// Appearance struct does not yet model. For everything else use Style,
	// which serialises to exactly this string for you.
	Appearance *string
}

// Position places the alert window on screen. It is the `position` key of
// an Appearance.
//
// Valid values — these five, and nothing else:
//
//	PositionCenter      "center"      (the client's default)
//	PositionTopLeft     "topLeft"
//	PositionTopRight    "topRight"
//	PositionBottomLeft  "bottomLeft"
//	PositionBottomRight "bottomRight"
//
// Anything else is rejected by Appearance.Validate (and so by Handle.Alert),
// because the client would silently ignore it and fall back to the default.
type Position string

// The complete set of alert positions. See Position.
const (
	// PositionCenter centres the alert on the active screen. This is what
	// the client uses when position is omitted.
	PositionCenter Position = "center"
	// PositionTopLeft pins the alert to the top-left corner.
	PositionTopLeft Position = "topLeft"
	// PositionTopRight pins the alert to the top-right corner.
	PositionTopRight Position = "topRight"
	// PositionBottomLeft pins the alert to the bottom-left corner.
	PositionBottomLeft Position = "bottomLeft"
	// PositionBottomRight pins the alert to the bottom-right corner.
	PositionBottomRight Position = "bottomRight"
)

// BlurIntensity is how strongly the screen behind the alert is blurred. It
// is the `screenBlurIntensity` key of an Appearance and has NO effect
// unless screenBlurEnabled is also true — set both at once with
// Appearance.WithScreenBlur.
//
// Valid values — these three, and nothing else:
//
//	BlurLight  "light"
//	BlurMedium "medium"  (the client's default)
//	BlurHeavy  "heavy"
//
// Anything else is rejected by Appearance.Validate.
type BlurIntensity string

// The complete set of blur intensities. See BlurIntensity.
const (
	// BlurLight is the subtlest backdrop blur.
	BlurLight BlurIntensity = "light"
	// BlurMedium is the client's default intensity.
	BlurMedium BlurIntensity = "medium"
	// BlurHeavy is the strongest backdrop blur.
	BlurHeavy BlurIntensity = "heavy"
)

// Appearance is the presentation hint that rides on one alert: the typed
// form of Alert.Appearance's JSON. Core forwards it to the client without
// parsing it; the client decodes it and styles that single notification.
//
// # Every field is optional, and omitted means "client default"
//
// Each field is a pointer so that "unset" and "set to the zero value" stay
// distinguishable on the wire: a nil field is not serialised at all, and
// only an absent key makes the client keep its own default. Sending
// `"width": 0` is a request for a zero-width window, not a request for the
// default one. Build values with the With… helpers (or the Ptr helper) and
// this is handled for you.
//
// # Runnable example
//
//	// A centred, 520-wide card with a bundled illustration, a heavy
//	// backdrop blur, dismissing itself after 30 seconds.
//	style := vc.NewAppearance().
//	    WithBundledIcon("yoga").
//	    WithPosition(vc.PositionCenter).
//	    WithSize(520, 260).
//	    WithSVGSize(240, 160).
//	    WithScreenBlur(vc.BlurHeavy).
//	    WithAutoDismissAfter(30 * time.Second).
//	    WithMoveable(false)
//
//	if err := h.Alert(vc.Alert{
//	    Title:   "Stretch break",
//	    Body:    "Ninety minutes at the desk. Stand up.",
//	    Level:   "info",
//	    Actions: []vc.AlertAction{{Label: "Snooze", URL: "snooze"}},
//	    Style:   style,
//	}); err != nil {
//	    log.Printf("alert: %v", err)
//	}
//
//	// That Style serialises to exactly:
//	// {"bundledIconId":"yoga","svgWidth":240,"svgHeight":160,
//	//  "position":"center","width":520,"height":260,"moveable":false,
//	//  "autoDismissAfter":30,"screenBlurEnabled":true,
//	//  "screenBlurIntensity":"heavy"}
//
// # Two client behaviours worth knowing
//
// An appearance whose keys match NONE of the ones below is rejected whole
// and the alert renders as a plain banner, so an all-nil Appearance (see
// IsEmpty) is worse than no Appearance at all — it serialises to `{}`.
// Unknown extra keys, by contrast, are tolerated, and one bad value costs
// only that one field.
type Appearance struct {
	// BundledIconID names an illustration from the client's own built-in
	// icon catalog, e.g. "yoga", "water-bottle", "timer", "focus",
	// "break", "sleep", "meeting". The full list is the `id` field of
	// every entry in the client's SVGIconCatalog.json. An id the client
	// does not know draws no illustration (and the alert falls back to the
	// plain banner rendering). Omitted: no illustration.
	//
	// Wire key: "bundledIconId". Set with WithBundledIcon.
	BundledIconID *string `json:"bundledIconId,omitempty"`

	// SVGPath points at an illustration the plugin supplies itself. Two
	// accepted forms:
	//
	//	absolute        "https://…", "http://…", "file://…", "/abs/path.svg"
	//	plugin-relative "assets/stretch.svg" — resolved by the client
	//	                against this plugin's own mount, /p/<id>/
	//
	// Prefer the relative form for anything the plugin serves itself: a
	// plugin cannot know which port core assigned it, so a relative path
	// is the only self-referential URL it can honestly produce. Omitted:
	// no custom illustration (BundledIconID, if set, is used instead).
	//
	// Wire key: "svgPath". Set with WithSVGPath or WithSVG.
	SVGPath *string `json:"svgPath,omitempty"`

	// SVGWidth is the illustration's drawn width in points. Client
	// default when omitted: 220.
	//
	// Wire key: "svgWidth". Set with WithSVGSize or WithSVG.
	SVGWidth *float64 `json:"svgWidth,omitempty"`

	// SVGHeight is the illustration's drawn height in points. Client
	// default when omitted: 150.
	//
	// Wire key: "svgHeight". Set with WithSVGSize or WithSVG.
	SVGHeight *float64 `json:"svgHeight,omitempty"`

	// Position places the window on the active screen. One of
	// PositionCenter, PositionTopLeft, PositionTopRight,
	// PositionBottomLeft, PositionBottomRight — see Position. Client
	// default when omitted: PositionCenter.
	//
	// Wire key: "position". Set with WithPosition.
	Position *Position `json:"position,omitempty"`

	// Width is the alert window's width in points. Client default when
	// omitted: 450.
	//
	// Wire key: "width". Set with WithSize.
	Width *float64 `json:"width,omitempty"`

	// Height is the alert window's height in points — a FLOOR, not a fixed
	// size. The client measures the assembled view and takes whichever is
	// larger, so adding action buttons can only grow the window, never
	// clip the message. Client default when omitted: 220.
	//
	// Wire key: "height". Set with WithSize.
	Height *float64 `json:"height,omitempty"`

	// Moveable lets the user drag the alert around. Client default when
	// omitted: true.
	//
	// Wire key: "moveable". Set with WithMoveable.
	Moveable *bool `json:"moveable,omitempty"`

	// AutoDismissAfter is the delay in SECONDS before the alert dismisses
	// itself. Client default when omitted: 20. Fractional values are
	// allowed.
	//
	// Wire key: "autoDismissAfter". Set with WithAutoDismissAfter, which
	// takes a time.Duration and converts.
	AutoDismissAfter *float64 `json:"autoDismissAfter,omitempty"`

	// ScreenBlurEnabled blurs the desktop behind the alert. Client default
	// when omitted: false. ScreenBlurIntensity is ignored unless this is
	// true, which is why WithScreenBlur sets both together.
	//
	// Wire key: "screenBlurEnabled".
	ScreenBlurEnabled *bool `json:"screenBlurEnabled,omitempty"`

	// ScreenBlurIntensity is how strong that blur is: BlurLight,
	// BlurMedium or BlurHeavy — see BlurIntensity. Client default when
	// omitted: BlurMedium. Only takes effect when ScreenBlurEnabled is
	// true.
	//
	// Wire key: "screenBlurIntensity". Set with WithScreenBlur.
	ScreenBlurIntensity *BlurIntensity `json:"screenBlurIntensity,omitempty"`

	// Title is ACCEPTED BY THE CLIENT BUT NEVER APPLIED. The alert's own
	// Title always wins, because the sender already worded it and may have
	// computed part of it at fire time. The field exists only so a plugin
	// that stores a full appearance blob can forward it verbatim without
	// stripping keys. Setting it has no visible effect — set Alert.Title.
	//
	// Wire key: "title".
	Title *string `json:"title,omitempty"`

	// Message is ACCEPTED BY THE CLIENT BUT NEVER APPLIED, for the same
	// reason as Title. Set Alert.Body instead.
	//
	// Wire key: "message".
	Message *string `json:"message,omitempty"`
}

// NewAppearance returns an empty Appearance ready to be chained through the
// With… helpers. An Appearance with no fields set is not a useful thing to
// send (see IsEmpty), so set at least one.
func NewAppearance() *Appearance { return &Appearance{} }

// Ptr returns a pointer to v. It exists so an Appearance can also be
// written as a plain struct literal without a local variable per field:
//
//	style := &vc.Appearance{Width: vc.Ptr(520.0), Moveable: vc.Ptr(false)}
func Ptr[T any](v T) *T { return &v }

// WithBundledIcon sets BundledIconID — an id from the client's built-in
// icon catalog, e.g. "yoga" or "water-bottle".
func (a *Appearance) WithBundledIcon(id string) *Appearance {
	a = a.ensure()
	a.BundledIconID = &id
	return a
}

// WithSVGPath sets SVGPath. The path may be absolute ("https://…",
// "file://…", "/abs/path.svg") or plugin-relative ("assets/x.svg", resolved
// against /p/<id>/).
func (a *Appearance) WithSVGPath(path string) *Appearance {
	a = a.ensure()
	a.SVGPath = &path
	return a
}

// WithSVGSize sets the illustration's drawn size in points (client
// defaults: 220 x 150).
func (a *Appearance) WithSVGSize(width, height float64) *Appearance {
	a = a.ensure()
	a.SVGWidth, a.SVGHeight = &width, &height
	return a
}

// WithSVG sets the illustration path and its drawn size in points in one
// call. Equivalent to WithSVGPath followed by WithSVGSize.
func (a *Appearance) WithSVG(path string, width, height float64) *Appearance {
	return a.WithSVGPath(path).WithSVGSize(width, height)
}

// WithPosition sets Position. Use one of the Position constants;
// Handle.Alert refuses to send any other value.
func (a *Appearance) WithPosition(p Position) *Appearance {
	a = a.ensure()
	a.Position = &p
	return a
}

// WithSize sets the alert window's width and height in points (client
// defaults: 450 x 220). Height is a floor, not a cap — see Appearance.Height.
func (a *Appearance) WithSize(width, height float64) *Appearance {
	a = a.ensure()
	a.Width, a.Height = &width, &height
	return a
}

// WithMoveable sets whether the user can drag the alert (client default:
// true).
func (a *Appearance) WithMoveable(moveable bool) *Appearance {
	a = a.ensure()
	a.Moveable = &moveable
	return a
}

// WithAutoDismissAfter sets how long the alert stays up before dismissing
// itself (client default: 20s). The wire field is in seconds; this takes a
// time.Duration and converts, so 90*time.Second and 90.0 are the same
// request.
func (a *Appearance) WithAutoDismissAfter(d time.Duration) *Appearance {
	a = a.ensure()
	secs := d.Seconds()
	a.AutoDismissAfter = &secs
	return a
}

// WithScreenBlur turns the backdrop blur ON at the given intensity. It sets
// BOTH ScreenBlurEnabled and ScreenBlurIntensity, because the client
// ignores the intensity unless the flag is true — setting only the
// intensity is the most common way to get no blur at all.
func (a *Appearance) WithScreenBlur(intensity BlurIntensity) *Appearance {
	a = a.ensure()
	enabled := true
	a.ScreenBlurEnabled, a.ScreenBlurIntensity = &enabled, &intensity
	return a
}

// WithoutScreenBlur turns the backdrop blur explicitly OFF. Only needed to
// override an appearance that had it on; the client's default is already
// off.
func (a *Appearance) WithoutScreenBlur() *Appearance {
	a = a.ensure()
	disabled := false
	a.ScreenBlurEnabled = &disabled
	a.ScreenBlurIntensity = nil
	return a
}

// ensure makes the With… helpers safe to chain off a nil *Appearance, so
// that a value threaded through optional configuration
// (style = style.WithSize(…)) never panics on the path where nothing set it.
func (a *Appearance) ensure() *Appearance {
	if a == nil {
		return &Appearance{}
	}
	return a
}

// IsEmpty reports whether no field is set. Such an appearance serialises to
// `{}`, which the client REJECTS outright — it renders the plain default
// banner — so an empty Appearance is never worth sending. Leave Alert.Style
// nil instead.
func (a *Appearance) IsEmpty() bool {
	return a == nil || *a == Appearance{}
}

// Validate reports the first field whose value the client would silently
// drop: a Position or BlurIntensity outside its documented set, or a
// negative size or duration. Handle.Alert calls it, so a bad value fails
// loudly at the call site instead of arriving as an alert that quietly
// looks wrong.
func (a *Appearance) Validate() error {
	if a == nil {
		return nil
	}
	if p := a.Position; p != nil {
		switch *p {
		case PositionCenter, PositionTopLeft, PositionTopRight, PositionBottomLeft, PositionBottomRight:
		default:
			return fmt.Errorf("vc: Appearance.Position %q is not one of %q, %q, %q, %q, %q",
				*p, PositionCenter, PositionTopLeft, PositionTopRight, PositionBottomLeft, PositionBottomRight)
		}
	}
	if b := a.ScreenBlurIntensity; b != nil {
		switch *b {
		case BlurLight, BlurMedium, BlurHeavy:
		default:
			return fmt.Errorf("vc: Appearance.ScreenBlurIntensity %q is not one of %q, %q, %q",
				*b, BlurLight, BlurMedium, BlurHeavy)
		}
	}
	for _, f := range []struct {
		name string
		v    *float64
	}{
		{"Width", a.Width}, {"Height", a.Height},
		{"SVGWidth", a.SVGWidth}, {"SVGHeight", a.SVGHeight},
		{"AutoDismissAfter", a.AutoDismissAfter},
	} {
		if f.v != nil && *f.v < 0 {
			return fmt.Errorf("vc: Appearance.%s must not be negative, got %v", f.name, *f.v)
		}
	}
	return nil
}

// JSON renders the appearance as the exact wire blob Alert.Appearance
// carries: a JSON object holding only the fields that were set. Handle.Alert
// does this for you; it is exported for plugins that persist an appearance
// or build one somewhere other than at the call site.
func (a *Appearance) JSON() (string, error) {
	if a == nil {
		return "", fmt.Errorf("vc: (*Appearance)(nil).JSON: nil means \"no opinion\", leave Alert.Style nil instead")
	}
	if err := a.Validate(); err != nil {
		return "", err
	}
	b, err := json.Marshal(a)
	if err != nil {
		return "", fmt.Errorf("vc: encode Appearance: %w", err)
	}
	return string(b), nil
}

// Handle is a connected plugin.
type Handle struct {
	ID       string
	DataDir  string
	Listener net.Listener

	// Events delivers bus events the plugin subscribed to in its manifest.
	// It is never closed — not by Close, not on shutdown — so a plugin
	// that ranges over Events expecting the loop to end on its own will
	// block forever after Close instead of seeing the channel close.
	// OnShutdown, not channel closure, is the termination signal.
	Events <-chan Event

	conn   *grpc.ClientConn
	client pluginv1.PluginHostClient
	events chan Event

	ctx    context.Context
	cancel context.CancelFunc

	// sigCh is the channel signal.Notify delivers SIGTERM to. Stored so
	// Close can signal.Stop it — otherwise a plugin process that calls
	// Connect more than once (this package's own tests do) would pile up
	// one registration per call, all still live.
	sigCh chan os.Signal

	mu           sync.Mutex
	onShutdown   func()
	healthFn     func() (status, detail string)
	shutdownOnce sync.Once
}

// runShutdown invokes the registered OnShutdown callback at most once, no
// matter which of the two independent paths triggers it first: the
// Shutdown message arriving on the Register stream, or the process
// receiving SIGTERM directly. Both exist because a direct signal beats a
// gRPC round trip over a unix socket essentially always — SIGTERM is not a
// fallback for a rare case, it is the path that normally wins.
func (h *Handle) runShutdown() {
	h.shutdownOnce.Do(func() {
		h.mu.Lock()
		fn := h.onShutdown
		h.mu.Unlock()
		if fn != nil {
			fn()
		}
	})
}

// Connect reads the spawn environment, binds the plugin's HTTP listener,
// dials core, registers, and starts the reconnect loop. It returns once
// core has acknowledged with Ready.
//
// A plugin process is expected to call Connect exactly once. A second
// Connect in the same process is not an error: it does not fail or
// panic, it simply repoints the /health handler already installed on
// http.DefaultServeMux at the newer Handle (see registerDefaultHealth).
func Connect() (*Handle, error) {
	socket := os.Getenv("VIBECARE_SOCKET")
	id := os.Getenv("VIBECARE_PLUGIN_ID")
	dataDir := os.Getenv("VIBECARE_DATA_DIR")
	if socket == "" || id == "" || dataDir == "" {
		return nil, fmt.Errorf("vc: VIBECARE_SOCKET, VIBECARE_PLUGIN_ID and VIBECARE_DATA_DIR must all be set (is this plugin being run outside VibeCare?)")
	}

	// Bind before registering: RegisterReq.http_port must carry the port
	// the kernel actually assigned.
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("vc: bind plugin http listener: %w", err)
	}

	conn, err := grpc.NewClient("unix://"+socket,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithUnaryInterceptor(attributionInterceptor(id)),
		grpc.WithStreamInterceptor(attributionStreamInterceptor(id)),
	)
	if err != nil {
		lis.Close()
		return nil, fmt.Errorf("vc: dial core: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	h := &Handle{
		ID: id, DataDir: dataDir, Listener: lis,
		conn: conn, client: pluginv1.NewPluginHostClient(conn),
		events: make(chan Event, eventChanCap),
		ctx:    ctx, cancel: cancel,
	}
	h.Events = h.events

	// A direct SIGTERM beats a gRPC round trip over a unix socket
	// essentially always, so core's Shutdown message (handled below in
	// session, via runShutdown) frequently loses that race even though core
	// sends it first. This is the SDK-side half of that fix: trap SIGTERM
	// here too and run the SAME onShutdown callback, guarded by the same
	// sync.Once, so a plugin flushes its buffered state regardless of which
	// path wins. Core still follows up with SIGKILL after its grace period
	// if the process doesn't exit on its own — this handler does not call
	// os.Exit, so a plugin author who wants SIGTERM itself to end the
	// process (as closing the HTTP listener naturally does, e.g. in
	// plugins/todo) gets that from their own OnShutdown body, exactly as
	// the Shutdown-message path already requires.
	h.sigCh = make(chan os.Signal, 1)
	signal.Notify(h.sigCh, syscall.SIGTERM)
	go func() {
		select {
		case <-h.sigCh:
			h.runShutdown()
		case <-h.ctx.Done():
		}
	}()

	// The default /health handler, so most plugin authors write none. A
	// plugin process calls Connect exactly once in production, but this
	// package's own tests call it many times against the single
	// process-wide http.DefaultServeMux, and *ServeMux.HandleFunc panics
	// on a duplicate pattern. Register the indirection handler at most
	// once and repoint it at the latest Handle on every call instead.
	registerDefaultHealth(h)

	ready := make(chan struct{})
	var readyOnce sync.Once
	go h.run(func() { readyOnce.Do(func() { close(ready) }) })

	select {
	case <-ready:
		return h, nil
	case <-time.After(readyTimeout):
		h.Close()
		return nil, fmt.Errorf("vc: core did not acknowledge registration within %s", readyTimeout)
	}
}

// run owns the Register stream for the life of the process. A dropped
// stream is NOT fatal: the plugin keeps serving HTTP and re-dials with
// backoff. Without this, restarting core would kill every running plugin.
func (h *Handle) run(onReady func()) {
	delay := reconnectBase
	for {
		if h.ctx.Err() != nil {
			return
		}
		startedAt := time.Now()
		err := h.session(onReady)
		if h.ctx.Err() != nil {
			return
		}
		// A session that stayed connected for a meaningful stretch is a
		// fresh problem when it drops, not a continuation of whatever
		// caused an earlier flapping streak — reset the ladder rather than
		// let one rough patch years ago keep costing reconnectMax on every
		// later, unrelated drop.
		if time.Since(startedAt) >= reconnectStable {
			delay = reconnectBase
		}
		if err != nil {
			// stderr only: stdout belongs to the plugin author.
			fmt.Fprintf(os.Stderr, "vc: register stream ended (%v); reconnecting in %s\n", err, delay)
		}
		select {
		case <-h.ctx.Done():
			return
		case <-time.After(delay):
		}
		if delay < reconnectMax {
			delay *= 2
			if delay > reconnectMax {
				delay = reconnectMax
			}
		}
	}
}

// session runs one Register stream to completion.
func (h *Handle) session(onReady func()) error {
	_, portStr, err := net.SplitHostPort(h.Listener.Addr().String())
	if err != nil {
		return err
	}
	var port int
	if _, err := fmt.Sscanf(portStr, "%d", &port); err != nil {
		return err
	}

	stream, err := h.client.Register(h.ctx, &pluginv1.RegisterReq{
		Id: h.ID, HttpPort: uint32(port),
	})
	if err != nil {
		return err
	}

	for {
		msg, err := stream.Recv()
		if err != nil {
			return err
		}
		switch {
		case msg.GetReady() != nil:
			onReady()

		case msg.GetEvent() != nil:
			e := msg.GetEvent()
			select {
			case h.events <- Event{Topic: e.GetTopic(), Payload: e.GetPayload(), TS: e.GetTs().AsTime()}:
			default: // fire-and-forget: a plugin that isn't reading drops events
			}

		case msg.GetShutdown() != nil:
			h.runShutdown()
		}
	}
}

// Publish puts raw bytes on a topic. The topic must be declared in the
// plugin's manifest under publishes, or core rejects it.
func (h *Handle) Publish(topic string, payload []byte) error {
	_, err := h.client.Publish(h.ctx, &pluginv1.Event{
		Topic:   topic,
		Payload: payload,
		Ts:      timestamppb.Now(),
	})
	return err
}

// PublishProto marshals m and publishes it. Topic payloads evolve by
// bumping the version in the topic name, never by changing a message in
// place.
func (h *Handle) PublishProto(topic string, m proto.Message) error {
	b, err := proto.Marshal(m)
	if err != nil {
		return err
	}
	return h.Publish(topic, b)
}

// Alert raises a native notification on the client.
//
// If a.Style is set it is validated and serialised, and the result REPLACES
// a.Appearance — see Alert.Style for why the typed value wins. An invalid
// Style (an out-of-set Position or BlurIntensity, a negative size) is an
// error and no alert is sent, because the alternative is a notification
// that quietly renders wrong. If a.Style is nil, a.Appearance is forwarded
// verbatim exactly as it always has been.
func (h *Handle) Alert(a Alert) error {
	appearance := a.Appearance
	if a.Style != nil {
		blob, err := a.Style.JSON()
		if err != nil {
			return err
		}
		appearance = &blob
	}

	req := &pluginv1.AlertReq{Title: a.Title, Body: a.Body, Level: a.Level, Appearance: appearance}
	for _, act := range a.Actions {
		req.Actions = append(req.Actions, &pluginv1.AlertAction{Label: act.Label, Url: act.URL})
	}
	_, err := h.client.Alert(h.ctx, req)
	return err
}

// OnShutdown registers a callback run when core sends Shutdown. Plugins
// should close their HTTP listener and flush storage there; SIGTERM
// follows, and SIGKILL 5s after that.
func (h *Handle) OnShutdown(fn func()) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.onShutdown = fn
}

// SetHealth overrides the default /health body. status is "ok" or
// "degraded"; a plugin reporting degraded moves to that state immediately
// rather than waiting for probes to fail.
func (h *Handle) SetHealth(fn func() (status, detail string)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.healthFn = fn
}

var (
	defaultHealthOnce sync.Once
	defaultHealthMu   sync.Mutex
	defaultHealthH    *Handle
)

// registerDefaultHealth wires http.DefaultServeMux's /health to whichever
// Handle most recently connected. The mux registration itself happens at
// most once per process; the target Handle is swapped under a mutex so a
// second Connect (a process reconnecting, or this package's own tests)
// never panics on a duplicate pattern.
func registerDefaultHealth(h *Handle) {
	defaultHealthMu.Lock()
	defaultHealthH = h
	defaultHealthMu.Unlock()

	defaultHealthOnce.Do(func() {
		http.DefaultServeMux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
			defaultHealthMu.Lock()
			cur := defaultHealthH
			defaultHealthMu.Unlock()
			if cur == nil {
				http.NotFound(w, r)
				return
			}
			cur.handleHealth(w, r)
		})
	})
}

func (h *Handle) handleHealth(w http.ResponseWriter, _ *http.Request) {
	h.mu.Lock()
	fn := h.healthFn
	h.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	status, detail := "ok", ""
	if fn != nil {
		status, detail = fn()
	}
	_ = json.NewEncoder(w).Encode(map[string]string{"status": status, "detail": detail})
}

// Serve installs the default /health handler on mux and serves the
// plugin's HTTP on the listener core assigned. Passing nil uses
// http.DefaultServeMux, where Connect already installed /health.
//
// Passing http.DefaultServeMux explicitly is also safe: Connect already
// registered /health there, and *http.ServeMux.HandleFunc panics on a
// duplicate pattern, so Serve detects that case and repoints the
// existing indirection at this Handle instead of registering again.
func (h *Handle) Serve(mux *http.ServeMux) error {
	if mux == nil {
		return http.Serve(h.Listener, nil)
	}
	if mux == http.DefaultServeMux {
		defaultHealthMu.Lock()
		defaultHealthH = h
		defaultHealthMu.Unlock()
	} else {
		mux.HandleFunc("/health", h.handleHealth)
	}
	return http.Serve(h.Listener, mux)
}

func (h *Handle) Close() error {
	h.cancel()
	if h.sigCh != nil {
		signal.Stop(h.sigCh)
	}
	if h.Listener != nil {
		h.Listener.Close()
	}
	return h.conn.Close()
}

// attributionInterceptor attaches the plugin id to every unary call. Core
// uses it to attribute publishes and alerts; Event carries no plugin field
// precisely so a plugin cannot claim to be another one.
func attributionInterceptor(id string) grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		ctx = metadata.AppendToOutgoingContext(ctx, pluginwire.PluginIDMetadataKey, id)
		return invoker(ctx, method, req, reply, cc, opts...)
	}
}

func attributionStreamInterceptor(id string) grpc.StreamClientInterceptor {
	return func(ctx context.Context, desc *grpc.StreamDesc, cc *grpc.ClientConn, method string, streamer grpc.Streamer, opts ...grpc.CallOption) (grpc.ClientStream, error) {
		ctx = metadata.AppendToOutgoingContext(ctx, pluginwire.PluginIDMetadataKey, id)
		return streamer(ctx, desc, cc, method, opts...)
	}
}
