package kernel

import (
	"encoding/json"
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
