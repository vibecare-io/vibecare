package kernel

import (
	"sync"
	"time"
)

// TapEvent is one published event, as an observer sees it. It carries the
// publisher, which BusEvent does not: a subscriber already knows why it was
// given an event, but something watching everything needs to be told who
// fired it.
type TapEvent struct {
	Plugin  string
	Topic   string
	Payload []byte
	TS      time.Time
}

// tapChanCap bounds an observer's queue, and drops beyond it, for the same
// reason subChanCap does: a slow reader must never become the publisher's
// problem. An observer is a diagnostic, and a diagnostic that can stall the
// system it observes is worse than no diagnostic.
const tapChanCap = 256

// Tap returns a channel carrying EVERY published event, whether or not any
// plugin subscribed to it.
//
// That difference is the entire point. Subscribe answers "what am I meant to
// receive"; Tap answers "what is actually happening", including a plugin
// firing into a topic nobody listens to — which looks identical to a broken
// plugin from the outside and is one of the harder things to diagnose
// without this.
//
// The returned func deregisters and closes the channel. It is safe to call
// more than once.
func (b *Bus) Tap() (<-chan TapEvent, func()) {
	ch := make(chan TapEvent, tapChanCap)

	b.mu.Lock()
	if b.taps == nil {
		b.taps = map[chan TapEvent]struct{}{}
	}
	b.taps[ch] = struct{}{}
	b.mu.Unlock()

	var once sync.Once
	return ch, func() {
		once.Do(func() {
			// Deregistered and closed under the same lock the publisher
			// sends beneath, so a send can never race the close. See
			// deliver's comment for why a select-with-default is not
			// sufficient on its own.
			b.mu.Lock()
			defer b.mu.Unlock()
			if _, live := b.taps[ch]; live {
				delete(b.taps, ch)
				close(ch)
			}
		})
	}
}

// publishToTaps fans one event out to every observer. Non-blocking: an
// observer that has fallen behind loses events rather than slowing the bus.
// Called with b.mu held.
func (b *Bus) publishToTaps(e TapEvent) {
	for ch := range b.taps {
		select {
		case ch <- e:
		default:
		}
	}
}
