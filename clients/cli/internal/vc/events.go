package vc

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

// eventsPath is core's diagnostic firehose. It is on the kernel's own HTTP
// surface rather than the Shell gRPC contract on purpose: Shell is frozen at
// two RPCs so product clients stay free of plugin knowledge, and a stream of
// arbitrary plugin topics is exactly what that freeze keeps out.
const eventsPath = "/_core/api/events"

// WatchEvents streams every event published on core's bus, including ones no
// plugin subscribed to.
//
// The stream has no replay: it starts from the moment it connects, because
// core retains nothing. A watcher that attaches after the interesting event
// has to make it happen again — which, for a debugging tool, is the honest
// contract rather than a buffer that is always the wrong size.
//
// The channel closes when ctx is done or the stream ends. Like the roster
// and alert streams, it reconnects on its own: core restarting under
// `just run` is the normal case, not an error worth tearing the view down
// for.
func (s *Session) WatchEvents(ctx context.Context) (<-chan Event, error) {
	if _, err := s.KernelBaseURL(ctx); err != nil {
		return nil, err
	}

	out := make(chan Event, 64)
	go func() {
		defer close(out)
		for attempt := 0; ; attempt++ {
			if ctx.Err() != nil {
				return
			}
			if s.streamEvents(ctx, out) {
				// Delivered something, so this was a live connection that
				// dropped rather than one that never worked: start the
				// backoff over.
				attempt = 0
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(DefaultBackoff.Delay(attempt)):
			}
		}
	}()
	return out, nil
}

// streamEvents runs one connection and reports whether it delivered
// anything, which is what tells the caller a reconnect is a resumption
// rather than a retry.
func (s *Session) streamEvents(ctx context.Context, out chan<- Event) bool {
	resp, err := s.kernelDo(ctx, http.MethodGet, eventsPath)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}

	var delivered bool
	sc := bufio.NewScanner(resp.Body)
	// One event is one line, but a payload can be long; the default 64 KiB
	// token limit would silently end the stream on the first big one.
	sc.Buffer(make([]byte, 0, 8192), 1<<20)

	for sc.Scan() {
		line := sc.Text()
		// Comment lines are the heartbeat that keeps an idle stream open.
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		var e wireEvent
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &e); err != nil {
			continue
		}
		select {
		case out <- e.event():
			delivered = true
		case <-ctx.Done():
			return delivered
		}
	}
	return delivered
}

type wireEvent struct {
	Plugin  string `json:"plugin"`
	Topic   string `json:"topic"`
	Payload string `json:"payload"`
	TS      string `json:"ts"`
}

func (w wireEvent) event() Event {
	at, err := time.Parse(time.RFC3339Nano, w.TS)
	if err != nil {
		// A timestamp core could not format is not worth dropping the event
		// over; arrival time is close enough for a live tail.
		at = time.Now()
	}
	return Event{Plugin: w.Plugin, Topic: w.Topic, Payload: w.Payload, At: at}
}
