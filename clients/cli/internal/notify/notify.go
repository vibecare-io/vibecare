// Package notify bridges VibeCare alerts to the desktop notifier of the
// host OS. It is opt-in: `vibecare alerts --notify` asks for it, nothing
// else does. A CLI that pops system notifications nobody asked for is a
// misfeature, so the zero-effort path through this package is a noop.
//
// Every implementation is best-effort. Failing to draw a notification must
// never fail the command that produced the alert, and a host with no
// notifier installed must not turn every alert into an error line.
package notify

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// notifyTimeout bounds one notifier invocation. Notify is called from the
// TUI's alert path, so a wedged osascript or a notification daemon blocked
// on a modal must not hold that goroutine indefinitely.
const notifyTimeout = 5 * time.Second

// levelWarn is the only level that means "raise urgency". It matches
// vc.Alert.Level, which is "info" or "warn" on the wire.
const levelWarn = "warn"

// Notification is what the user sees. It is deliberately not vc.Alert:
// plugin-supplied action buttons have no portable desktop equivalent, so
// the caller flattens an alert down to this before it crosses the boundary.
type Notification struct {
	Title string
	Body  string
	// Level is "info" or "warn"; anything else is treated as "info".
	Level string
}

// Notifier delivers notifications to the desktop.
type Notifier interface {
	Notify(ctx context.Context, n Notification) error
}

// New returns the platform notifier when enabled, and a noop otherwise.
// Callers therefore never branch on the flag themselves.
func New(enabled bool) Notifier {
	if !enabled {
		return Noop()
	}
	return newPlatform()
}

// Noop returns a Notifier that discards everything. It is also what
// unsupported platforms get.
func Noop() Notifier { return noopNotifier{} }

type noopNotifier struct{}

func (noopNotifier) Notify(context.Context, Notification) error { return nil }

// runner executes the platform notifier. It is a field on cmdNotifier so
// tests can drive the degrade path without an OS notifier — and without
// ever spawning a process.
type runner func(ctx context.Context, name string, args ...string) error

func execRun(ctx context.Context, name string, args ...string) error {
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	if err == nil {
		return nil
	}
	if msg := strings.TrimSpace(string(out)); msg != "" {
		return fmt.Errorf("%s: %w: %s", name, err, msg)
	}
	return fmt.Errorf("%s: %w", name, err)
}

// cmdNotifier shells out to a single external binary. Both supported
// platforms work this way; only the binary and its argv differ.
type cmdNotifier struct {
	name string
	argv func(Notification) []string
	run  runner

	mu sync.Mutex
	// degraded is latched once the binary proves to be missing. A host
	// without libnotify installed would otherwise produce one identical
	// error per alert forever, which is noise, not information.
	degraded bool
}

func (c *cmdNotifier) Notify(ctx context.Context, n Notification) error {
	if err := ctx.Err(); err != nil {
		return err
	}

	c.mu.Lock()
	degraded := c.degraded
	c.mu.Unlock()
	if degraded {
		return nil
	}

	ctx, cancel := context.WithTimeout(ctx, notifyTimeout)
	defer cancel()

	err := c.run(ctx, c.name, c.argv(n)...)
	if err == nil {
		return nil
	}
	if !errors.Is(err, exec.ErrNotFound) {
		// Transient: a busy daemon or a non-zero exit says nothing about
		// the next alert, so keep trying.
		return err
	}

	c.mu.Lock()
	first := !c.degraded
	c.degraded = true
	c.mu.Unlock()
	if !first {
		return nil
	}
	return fmt.Errorf("desktop notifications unavailable: %s not found in PATH (further alerts will not be shown)", c.name)
}

// The argv builders below live in this file rather than in their
// platform-tagged files on purpose: they are pure string handling, and the
// AppleScript escaping in particular is the one piece of this package that
// can be dangerous when wrong. Keeping them untagged means the tests that
// prove they cannot be broken out of run on every platform, not only on a
// Mac.

func osascriptArgs(n Notification) []string {
	script := `display notification "` + escapeAppleScript(n.Body) +
		`" with title "` + escapeAppleScript(n.Title) + `"`
	// One argv element, never a shell string: osascript gets the script
	// verbatim and no shell ever sees it.
	return []string{"-e", script}
}

// escapeAppleScript renders s safe to embed inside an AppleScript double
// quoted literal. Alert text is plugin-supplied, so a title containing a
// quote must terminate as text, not as syntax.
func escapeAppleScript(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 8)
	for _, r := range s {
		switch r {
		case '\\':
			b.WriteString(`\\`)
		case '"':
			b.WriteString(`\"`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if r < 0x20 || r == 0x7f {
				// AppleScript has no escape for the remaining control
				// bytes; dropping them beats emitting something the
				// parser may or may not accept.
				continue
			}
			b.WriteRune(r)
		}
	}
	return b.String()
}

func notifySendArgs(n Notification) []string {
	urgency := "normal"
	if n.Level == levelWarn {
		urgency = "critical"
	}
	// "--" matters: notify-send parses GNU options, and a plugin is free to
	// send a title beginning with a dash.
	args := []string{"-a", "vibecare", "-u", urgency, "--", n.Title}
	if n.Body != "" {
		args = append(args, n.Body)
	}
	return args
}
