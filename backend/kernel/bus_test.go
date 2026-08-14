package kernel

import (
	"encoding/json"
	"fmt"
	"sync"
	"testing"
	"time"

	"go.uber.org/zap"
)

func recvEvent(t *testing.T, ch <-chan BusEvent) BusEvent {
	t.Helper()
	select {
	case e := <-ch:
		return e
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for bus event")
		return BusEvent{}
	}
}

func expectNoEvent(t *testing.T, ch <-chan BusEvent) {
	t.Helper()
	select {
	case e := <-ch:
		t.Fatalf("unexpected event %q", e.Topic)
	case <-time.After(100 * time.Millisecond):
	}
}

func TestPublishDeliversToSubscriber(t *testing.T) {
	b := NewBus(zap.NewNop())
	b.Declare("sensor", nil, []string{"sensor.landmarks.v1"})
	b.Declare("consumer", []string{"sensor.landmarks.v1"}, nil)

	ch, cancel := b.Subscribe("consumer")
	defer cancel()

	ts := time.Unix(1700000000, 0)
	n, err := b.Publish("sensor", "sensor.landmarks.v1", []byte("frame"), ts)
	if err != nil || n != 1 {
		t.Fatalf("Publish = %d, %v; want 1, nil", n, err)
	}

	e := recvEvent(t, ch)
	if e.Topic != "sensor.landmarks.v1" || string(e.Payload) != "frame" || !e.TS.Equal(ts) {
		t.Fatalf("event = %+v", e)
	}
}

func TestPublishFansOutToAllSubscribers(t *testing.T) {
	b := NewBus(zap.NewNop())
	b.Declare("sensor", nil, []string{"t.v1"})
	b.Declare("a", []string{"t.v1"}, nil)
	b.Declare("bee", []string{"t.v1"}, nil)

	chA, cancelA := b.Subscribe("a")
	defer cancelA()
	chB, cancelB := b.Subscribe("bee")
	defer cancelB()

	n, _ := b.Publish("sensor", "t.v1", []byte("x"), time.Now())
	if n != 2 {
		t.Fatalf("delivered to %d, want 2", n)
	}
	recvEvent(t, chA)
	recvEvent(t, chB)
}

// Manifests stay honest: publishing a topic you didn't declare is an error
// and the message is dropped, not delivered.
func TestPublishUndeclaredTopicIsRejected(t *testing.T) {
	b := NewBus(zap.NewNop())
	b.Declare("sensor", nil, []string{"declared.v1"})
	b.Declare("consumer", []string{"sneaky.v1"}, nil)
	ch, cancel := b.Subscribe("consumer")
	defer cancel()

	n, err := b.Publish("sensor", "sneaky.v1", []byte("x"), time.Now())
	if err == nil {
		t.Fatal("expected error publishing an undeclared topic")
	}
	if n != 0 {
		t.Fatalf("delivered %d, want 0", n)
	}
	expectNoEvent(t, ch)
}

func TestPluginCannotPublishReservedTopics(t *testing.T) {
	b := NewBus(zap.NewNop())
	b.Declare("evil", nil, []string{TopicDemand})
	if _, err := b.Publish("evil", TopicDemand, []byte("{}"), time.Now()); err == nil {
		t.Fatal("plugins must not be able to publish _core.* topics")
	}
}

// A plugin that subscribes to a topic nobody publishes simply receives
// nothing — cross-plugin coupling is always an enhancement gated on
// presence, never a requirement.
func TestSubscribeToUnpublishedTopicIsSilent(t *testing.T) {
	b := NewBus(zap.NewNop())
	b.Declare("lonely", []string{"nobody.publishes.v1"}, nil)
	ch, cancel := b.Subscribe("lonely")
	defer cancel()
	expectNoEvent(t, ch)
}

func TestUnsubscribeStopsDelivery(t *testing.T) {
	b := NewBus(zap.NewNop())
	b.Declare("pub", nil, []string{"t.v1"})
	b.Declare("sub", []string{"t.v1"}, nil)
	ch, cancel := b.Subscribe("sub")
	cancel()
	cancel() // idempotent

	n, _ := b.Publish("pub", "t.v1", []byte("x"), time.Now())
	if n != 0 {
		t.Fatalf("delivered %d after unsubscribe", n)
	}
	if _, open := <-ch; open {
		t.Fatal("channel should be closed after cancel")
	}
}

// The provider must idle — camera closed, LED off — when nothing
// subscribes. It learns that from _core.demand.v1, which core delivers
// without the provider declaring it.
func TestDemandDeliveredToPublisherOnSubscribeAndUnsubscribe(t *testing.T) {
	b := NewBus(zap.NewNop())
	b.Declare("sensor", nil, []string{"sensor.landmarks.v1"})
	b.Declare("consumer", []string{"sensor.landmarks.v1"}, nil)

	sensorCh, cancelSensor := b.Subscribe("sensor")
	defer cancelSensor()

	// Demand starts at zero and is announced when the provider connects, so
	// a provider that starts before any consumer knows to stay idle.
	e := recvEvent(t, sensorCh)
	var d DemandPayload
	if e.Topic != TopicDemand {
		t.Fatalf("first event = %q, want %q", e.Topic, TopicDemand)
	}
	if err := json.Unmarshal(e.Payload, &d); err != nil {
		t.Fatal(err)
	}
	if d.Topic != "sensor.landmarks.v1" || d.Subscribers != 0 {
		t.Fatalf("initial demand = %+v, want 0 subscribers", d)
	}

	_, cancelConsumer := b.Subscribe("consumer")

	e = recvEvent(t, sensorCh)
	json.Unmarshal(e.Payload, &d)
	if d.Subscribers != 1 {
		t.Fatalf("demand after subscribe = %d, want 1", d.Subscribers)
	}

	cancelConsumer()

	e = recvEvent(t, sensorCh)
	json.Unmarshal(e.Payload, &d)
	if d.Subscribers != 0 {
		t.Fatalf("demand after unsubscribe = %d, want 0", d.Subscribers)
	}
}

func TestDemandCount(t *testing.T) {
	b := NewBus(zap.NewNop())
	b.Declare("pub", nil, []string{"t.v1"})
	b.Declare("a", []string{"t.v1"}, nil)
	b.Declare("bee", []string{"t.v1"}, nil)

	if got := b.Demand("t.v1"); got != 0 {
		t.Fatalf("demand = %d, want 0", got)
	}
	_, ca := b.Subscribe("a")
	_, cb := b.Subscribe("bee")
	if got := b.Demand("t.v1"); got != 2 {
		t.Fatalf("demand = %d, want 2", got)
	}
	ca()
	cb()
	if got := b.Demand("t.v1"); got != 0 {
		t.Fatalf("demand = %d, want 0", got)
	}
}

// Fire-and-forget: a subscriber that stops reading is dropped rather than
// buffered without bound, and must not stall the publisher.
func TestSlowSubscriberIsDroppedNotBuffered(t *testing.T) {
	b := NewBus(zap.NewNop())
	b.Declare("pub", nil, []string{"t.v1"})
	b.Declare("slow", []string{"t.v1"}, nil)
	_, cancel := b.Subscribe("slow")
	defer cancel()

	done := make(chan struct{})
	go func() {
		for i := 0; i < 5000; i++ {
			b.Publish("pub", "t.v1", []byte("x"), time.Now())
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("publisher blocked on a subscriber that never reads")
	}
}

func TestOnDeliveredHook(t *testing.T) {
	b := NewBus(zap.NewNop())
	got := map[string]int{}
	b.OnDelivered(func(id string, n int) { got[id] += n })

	b.Declare("pub", nil, []string{"t.v1"})
	b.Declare("sub", []string{"t.v1"}, nil)
	_, cancel := b.Subscribe("sub")
	defer cancel()

	b.Publish("pub", "t.v1", []byte("x"), time.Now())
	time.Sleep(50 * time.Millisecond)
	if got["sub"] != 1 {
		t.Fatalf("OnDelivered saw %v, want sub=1", got)
	}
}

// deliver and announceDemand snapshot subscriber pointers, unlock, then
// send. cancel concurrently locks, closes the channel, and unlocks. A
// select-with-default guards a FULL channel, not a CLOSED one, so a send
// racing a close panics unconditionally. This must survive heavy
// concurrent Publish/Subscribe/cancel traffic without ever panicking.
func TestConcurrentPublishAndCancelDoesNotPanic(t *testing.T) {
	b := NewBus(zap.NewNop())
	b.Declare("pub", nil, []string{"t.v1"})

	const flappers = 8
	ids := make([]string, flappers)
	for i := range ids {
		ids[i] = fmt.Sprintf("flap%d", i)
		b.Declare(ids[i], []string{"t.v1"}, nil)
	}

	const iterations = 3000
	var wg sync.WaitGroup

	// Publishers hammering the topic.
	for p := 0; p < 4; p++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < iterations; i++ {
				b.Publish("pub", "t.v1", []byte("x"), time.Now())
			}
		}()
	}

	// Flappers subscribing and immediately cancelling, racing the
	// publishers above and each other's own demand announcements.
	for _, id := range ids {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			for i := 0; i < iterations; i++ {
				_, cancel := b.Subscribe(id)
				cancel()
			}
		}(id)
	}

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		t.Fatal("timed out — possible deadlock")
	}
}

// A reconnecting plugin calls Subscribe again before its old stream's
// teardown gets around to calling cancel — both subscriptions share the
// same plugin id and the same topic list. The stale (first) cancel must
// not unroute the live (second) subscriber: b.byTopic is keyed by plugin
// id just like b.subs, so blindly deleting from it removes the entry the
// SECOND Subscribe call installed, not the first's, leaving the
// reconnected stream open, healthy, and permanently deaf to every topic it
// subscribes to.
func TestStaleCancelDoesNotUnrouteReplacementSubscriber(t *testing.T) {
	b := NewBus(zap.NewNop())
	b.Declare("pub", nil, []string{"t.v1"})
	b.Declare("alpha", []string{"t.v1"}, nil)

	_, cancelFirst := b.Subscribe("alpha")
	chSecond, cancelSecond := b.Subscribe("alpha") // simulates the reconnect
	defer cancelSecond()

	// Simulates the old Register stream's deferred teardown losing the
	// race against the new stream that already replaced it.
	cancelFirst()

	n, err := b.Publish("pub", "t.v1", []byte("x"), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("delivered to %d, want 1 (the replacement subscriber)", n)
	}
	recvEvent(t, chSecond)
}

// Finding 4: two plugins can publish the same topic (e.g. two camera
// providers). announceDemand must notify EVERY connected publisher of that
// topic, not just the first one a map iteration happens to find — a
// provider that never learns demand dropped to zero would keep its camera
// open, which the spec calls a privacy property enforced by mechanism
// (§10.2).
func TestDemandAnnouncedToEveryPublisherOfTheSameTopic(t *testing.T) {
	b := NewBus(zap.NewNop())
	b.Declare("providerA", nil, []string{"sensor.landmarks.v1"})
	b.Declare("providerB", nil, []string{"sensor.landmarks.v1"})
	b.Declare("consumer", []string{"sensor.landmarks.v1"}, nil)

	chA, cancelA := b.Subscribe("providerA")
	defer cancelA()
	// providerA gets a connect-time announcement (0 demand) for its own
	// topic the moment it connects, since it is the only publisher present
	// yet.
	recvEvent(t, chA)

	chB, cancelB := b.Subscribe("providerB")
	defer cancelB()
	// providerB connecting re-announces the topic's demand to EVERY
	// connected publisher (the fix under test), so BOTH channels get one
	// more event here (still 0 demand — no consumer yet).
	recvEvent(t, chA)
	recvEvent(t, chB)

	_, cancelConsumer := b.Subscribe("consumer")

	readDemand := func(ch <-chan BusEvent) int {
		t.Helper()
		e := recvEvent(t, ch)
		var d DemandPayload
		if err := json.Unmarshal(e.Payload, &d); err != nil {
			t.Fatal(err)
		}
		if d.Topic != "sensor.landmarks.v1" {
			t.Fatalf("event topic = %q, want sensor.landmarks.v1", d.Topic)
		}
		return d.Subscribers
	}

	if got := readDemand(chA); got != 1 {
		t.Fatalf("providerA demand after subscribe = %d, want 1", got)
	}
	if got := readDemand(chB); got != 1 {
		t.Fatalf("providerB demand after subscribe = %d, want 1 (BOTH publishers of a shared topic must be notified)", got)
	}

	cancelConsumer()

	if got := readDemand(chA); got != 0 {
		t.Fatalf("providerA demand after unsubscribe = %d, want 0", got)
	}
	if got := readDemand(chB); got != 0 {
		t.Fatalf("providerB demand after unsubscribe = %d, want 0 (a provider that never hears this keeps its camera open)", got)
	}
}

// TestDemandDeliveredToPublisherOnSubscribeAndUnsubscribe (above) can't
// distinguish announceDemand(own) from announceDemand(affected) because its
// sensor plugin only publishes and its consumer plugin only subscribes, so
// the "affected" announcement always lands on a different plugin's channel
// than the "own" one — swapping the two calls would produce identical
// output for that test.
//
// This test uses "relay", a plugin that publishes two topics (down.v1 and
// up.v1) and also subscribes to one of its own published topics (up.v1) —
// a deliberate self-loop so that BOTH the "own" announcement (down.v1,
// up.v1, in declared order) and the "affected" announcement (up.v1, because
// relay subscribes to it) resolve their publisher lookup back to relay
// itself and land on relay's own channel. That lets the very first event
// relay observes prove the order: if Subscribe announced affected before
// own, the first event would be up.v1, not down.v1.
func TestDemandAnnouncedForOwnTopicBeforeSubscribedTopic(t *testing.T) {
	b := NewBus(zap.NewNop())
	b.Declare("relay", []string{"up.v1"}, []string{"down.v1", "up.v1"})
	b.Declare("consumer", []string{"down.v1"}, nil)

	_, cancelConsumer := b.Subscribe("consumer")
	defer cancelConsumer()

	relayCh, cancelRelay := b.Subscribe("relay")
	defer cancelRelay()

	e := recvEvent(t, relayCh)
	var d DemandPayload
	if err := json.Unmarshal(e.Payload, &d); err != nil {
		t.Fatal(err)
	}
	if d.Topic != "down.v1" {
		t.Fatalf("first demand event topic = %q, want %q (own published topics announced before subscribed topics)", d.Topic, "down.v1")
	}
}
