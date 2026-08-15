package kernel

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

const apiEventsPath = corePrefix + "api/events"

// eventJSON is one event on the wire. Payload is sent verbatim as a string
// rather than decoded: the bus carries opaque bytes and core has no schema
// for them, so anything else here would be core inventing meaning it does
// not have.
type eventJSON struct {
	Plugin  string `json:"plugin"`
	Topic   string `json:"topic"`
	Payload string `json:"payload,omitempty"`
	TS      string `json:"ts"`
}

// maxPayloadBytes truncates what is forwarded. A watcher wants to see THAT
// an event fired and roughly what was in it; a plugin shipping a megabyte
// through the bus should not turn a diagnostic stream into a firehose that
// costs more than the thing it is diagnosing.
const maxPayloadBytes = 2048

// eventsHeartbeat keeps an idle stream from being closed by anything between
// here and the reader. Events are bursty — a quiet system emits none for
// minutes — and a connection that dies during the quiet is one that is
// always dead exactly when someone starts watching.
const eventsHeartbeat = 20 * time.Second

// NewEventsHandler streams every published event as server-sent events.
//
// SSE rather than a websocket because this is one-directional and needs no
// negotiation, and rather than a JSON array because the stream has no end.
// It lives on core's own /_core/ surface and NOT on the Shell gRPC contract:
// Shell is deliberately frozen at two RPCs so that clients stay free of
// plugin knowledge, and a firehose of plugin topics is exactly the kind of
// thing that freeze exists to keep out of a product client.
func NewEventsHandler(bus *Bus) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming unsupported", http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		// Without this an intermediary may hold the whole stream to buffer
		// it, which for a live tail means seeing nothing until it ends.
		w.Header().Set("X-Accel-Buffering", "no")
		w.WriteHeader(http.StatusOK)
		flusher.Flush()

		events, cancel := bus.Tap()
		defer cancel()

		tick := time.NewTicker(eventsHeartbeat)
		defer tick.Stop()

		for {
			select {
			case <-r.Context().Done():
				return
			case <-tick.C:
				// A comment line is a no-op to any SSE reader.
				fmt.Fprint(w, ": ping\n\n")
				flusher.Flush()
			case e, open := <-events:
				if !open {
					return
				}
				b, err := json.Marshal(toEventJSON(e))
				if err != nil {
					continue
				}
				fmt.Fprintf(w, "data: %s\n\n", b)
				flusher.Flush()
			}
		}
	})
}

func toEventJSON(e TapEvent) eventJSON {
	payload := e.Payload
	if len(payload) > maxPayloadBytes {
		payload = payload[:maxPayloadBytes]
	}
	return eventJSON{
		Plugin:  e.Plugin,
		Topic:   e.Topic,
		Payload: string(payload),
		TS:      e.TS.UTC().Format(time.RFC3339Nano),
	}
}
