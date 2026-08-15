package vc

import (
	"context"
	"time"
)

// Backoff is the reconnect schedule, defined once here because both
// frontends need it and they must not drift: the TUI shows the user the
// delay it is about to wait, and the CLI's --wait spends the same budget.
type Backoff struct {
	Base time.Duration
	Max  time.Duration
}

// DefaultBackoff starts responsive enough that a core coming up during
// `just run` is picked up almost immediately, and settles slow enough that a
// core which is never coming back costs one dial every eight seconds rather
// than a busy loop.
var DefaultBackoff = Backoff{Base: 250 * time.Millisecond, Max: 8 * time.Second}

// Delay is the wait before the given attempt, doubling per attempt and
// capped at Max.
//
// The clamp is not decoration. `Base << attempt` overflows to a NEGATIVE
// duration somewhere past attempt 50, and a client left running overnight
// against a dead core will get there — at which point an uncapped schedule
// would flip from "wait eight seconds" to "retry immediately, forever".
func (b Backoff) Delay(attempt int) time.Duration {
	if b.Base <= 0 {
		b.Base = DefaultBackoff.Base
	}
	if b.Max <= 0 {
		b.Max = DefaultBackoff.Max
	}
	if attempt < 0 {
		attempt = 0
	}
	// Bound the shift before performing it. Shifting by >= 63 is where the
	// sign bit goes, and Go does not panic on it — it silently produces
	// nonsense, which is worse.
	if attempt >= 63 {
		return b.Max
	}
	d := b.Base << uint(attempt)
	if d > b.Max || d <= 0 {
		return b.Max
	}
	return d
}

// DialWait is Dial with patience. Dial deliberately fails fast, because a
// CLI that hangs on a stopped backend is useless and a script needs an
// answer now. DialWait is the opt-in for the other case: a human who just
// ran `just run` in another pane and wants the client to hold on until core
// finishes coming up.
//
// It retries the whole dial rather than waiting on one connection, because
// the failure it exists to survive is "nothing is listening on that port
// yet", which no amount of waiting on an existing connection resolves.
func DialWait(ctx context.Context, opts Options, within time.Duration) (*Session, error) {
	if within <= 0 {
		return Dial(ctx, opts)
	}

	deadline := time.Now().Add(within)
	ctx, cancel := context.WithDeadline(ctx, deadline)
	defer cancel()

	var last error
	for attempt := 0; ; attempt++ {
		s, err := Dial(ctx, opts)
		if err == nil {
			return s, nil
		}
		last = err

		// Sleep the backoff, but never past the deadline: overrunning the
		// budget the user set is its own bug, and a 30s --wait that returns
		// at 38s is not honouring anything.
		delay := DefaultBackoff.Delay(attempt)
		if remaining := time.Until(deadline); remaining <= 0 {
			return nil, last
		} else if delay > remaining {
			delay = remaining
		}

		select {
		case <-ctx.Done():
			return nil, last
		case <-time.After(delay):
		}
	}
}
