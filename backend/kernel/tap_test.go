package kernel

import (
	"bufio"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"go.uber.org/zap"
)

func tapBus(t *testing.T) *Bus {
	t.Helper()
	b := NewBus(zap.NewNop())
	b.Declare("pub", nil, []string{"alpha.created.v1", "alpha.done.v1"})
	return b
}

// The whole reason Tap exists rather than Subscribe: an event nobody
// subscribed to still happened, and from outside, a plugin publishing into
// a topic with no listeners is indistinguishable from a plugin that is
// broken.
func TestTapSeesEventsWithNoSubscribers(t *testing.T) {
	b := tapBus(t)
	ch, cancel := b.Tap()
	defer cancel()

	if _, err := b.Publish("pub", "alpha.created.v1", []byte(`{"id":1}`), time.Now()); err != nil {
		t.Fatalf("Publish: %v", err)
	}

	select {
	case e := <-ch:
		if e.Plugin != "pub" || e.Topic != "alpha.created.v1" {
			t.Errorf("got %+v", e)
		}
		if string(e.Payload) != `{"id":1}` {
			t.Errorf("payload = %q", e.Payload)
		}
	case <-time.After(time.Second):
		t.Fatal("no event reached the tap")
	}
}

// A rejected publish never happened, so it must not appear.
func TestTapDoesNotSeeRejectedPublishes(t *testing.T) {
	b := tapBus(t)
	ch, cancel := b.Tap()
	defer cancel()

	if _, err := b.Publish("pub", "not.declared.v1", nil, time.Now()); err == nil {
		t.Fatal("Publish accepted an undeclared topic")
	}
	select {
	case e := <-ch:
		t.Errorf("a rejected publish reached the tap: %+v", e)
	case <-time.After(100 * time.Millisecond):
	}
}

func TestTapCancelIsIdempotent(t *testing.T) {
	b := tapBus(t)
	_, cancel := b.Tap()
	cancel()
	cancel() // must not panic on a double close
}

// A diagnostic that can stall the system it observes is worse than none.
func TestSlowTapDoesNotBlockPublishers(t *testing.T) {
	b := tapBus(t)
	_, cancel := b.Tap() // never read from
	defer cancel()

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < tapChanCap*3; i++ {
			_, _ = b.Publish("pub", "alpha.created.v1", []byte("x"), time.Now())
		}
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("publishing blocked on a tap nobody was reading")
	}
}

// Cancelling while a publisher is mid-fanout must not send on a closed
// channel. The bus takes sends under the same lock the close does, and this
// is the test that would catch it if that ever stopped being true.
func TestTapCancelRacesPublish(t *testing.T) {
	b := tapBus(t)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		ch, cancel := b.Tap()
		wg.Add(2)
		go func() {
			defer wg.Done()
			for j := 0; j < 200; j++ {
				_, _ = b.Publish("pub", "alpha.done.v1", nil, time.Now())
			}
		}()
		go func() {
			defer wg.Done()
			time.Sleep(time.Millisecond)
			cancel()
			for range ch {
			}
		}()
	}
	wg.Wait()
}

func TestEventsEndpointStreamsSSE(t *testing.T) {
	b := tapBus(t)
	srv := httptest.NewServer(NewEventsHandler(b))
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Errorf("Content-Type = %q", ct)
	}

	// The tap must be registered before the publish, or the event is gone:
	// this stream has no replay, by design.
	deadline := time.Now().Add(2 * time.Second)
	for {
		b.mu.Lock()
		n := len(b.taps)
		b.mu.Unlock()
		if n > 0 || time.Now().After(deadline) {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}

	go func() {
		time.Sleep(50 * time.Millisecond)
		_, _ = b.Publish("pub", "alpha.created.v1", []byte(`{"n":7}`), time.Now())
	}()

	sc := bufio.NewScanner(resp.Body)
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		var got eventJSON
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &got); err != nil {
			t.Fatalf("bad SSE payload %q: %v", line, err)
		}
		if got.Plugin != "pub" || got.Topic != "alpha.created.v1" || got.Payload != `{"n":7}` {
			t.Errorf("got %+v", got)
		}
		return
	}
	t.Fatal("stream ended without delivering the event")
}

// Core has no schema for a payload, so it forwards bytes — but not without
// limit, or a plugin shipping a megabyte turns the diagnostic into the
// problem.
func TestEventPayloadIsTruncated(t *testing.T) {
	big := strings.Repeat("x", maxPayloadBytes*2)
	got := toEventJSON(TapEvent{Plugin: "pub", Topic: "t", Payload: []byte(big), TS: time.Now()})
	if len(got.Payload) != maxPayloadBytes {
		t.Errorf("payload len = %d, want %d", len(got.Payload), maxPayloadBytes)
	}
}
