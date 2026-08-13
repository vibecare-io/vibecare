package kernel

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"go.uber.org/zap"
)

// reservedPrefix marks topics core itself originates. Plugins may not
// publish them, and core delivers them to the relevant plugin without the
// plugin declaring them in its manifest.
const reservedPrefix = "_core."

// TopicDemand carries the current subscriber count for one of a plugin's
// published topics back to that plugin. A provider that sees zero
// subscribers must close its capture session — this is a privacy property
// enforced by mechanism, which is exactly why the refcount lives in core
// rather than in each provider.
const TopicDemand = reservedPrefix + "demand.v1"

// DemandPayload is the JSON body of a TopicDemand event.
type DemandPayload struct {
	Topic       string `json:"topic"`
	Subscribers int    `json:"subscribers"`
}

// BusEvent is one delivery. Events are ephemeral: no persistence, no
// replay, no delivery guarantee.
type BusEvent struct {
	Topic   string
	Payload []byte
	TS      time.Time
}

// subChanCap bounds a subscriber's queue. Beyond it, events are dropped
// rather than buffered without bound — a slow subscriber must never become
// the publisher's problem.
const subChanCap = 64

type subscriber struct {
	id     string
	topics []string
	ch     chan BusEvent
	closed bool
}

// Bus is topic -> subscriber channels, in memory, fire-and-forget. It is
// the one mechanism with no alternative: cross-plugin communication is bus
// topics only, never the filesystem.
type Bus struct {
	log *zap.Logger

	mu         sync.Mutex
	subscribes map[string][]string // plugin id -> topics it subscribes to
	publishes  map[string][]string // plugin id -> topics it may publish
	subs       map[string]*subscriber
	byTopic    map[string]map[string]*subscriber // topic -> id -> subscriber

	onDelivered func(pluginID string, n int)
}

func NewBus(log *zap.Logger) *Bus {
	return &Bus{
		log:        log,
		subscribes: map[string][]string{},
		publishes:  map[string][]string{},
		subs:       map[string]*subscriber{},
		byTopic:    map[string]map[string]*subscriber{},
	}
}

// Declare records a plugin's manifest-declared topics. Subscriptions come
// from the manifest, not an RPC, so core knows what to deliver before the
// plugin ever connects.
func (b *Bus) Declare(pluginID string, subscribes, publishes []string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.subscribes[pluginID] = append([]string(nil), subscribes...)
	b.publishes[pluginID] = append([]string(nil), publishes...)
}

// OnDelivered installs a counter hook. It exists so the registry can count
// deliveries without the bus needing to know the registry exists.
func (b *Bus) OnDelivered(fn func(pluginID string, n int)) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.onDelivered = fn
}

// Subscribe attaches a plugin's Register stream to the bus. It returns the
// event channel and an idempotent unsubscribe func.
//
// Every subscriber also receives TopicDemand events for the topics IT
// publishes — including one immediately, so a provider that starts before
// any consumer learns to stay idle rather than assuming demand.
func (b *Bus) Subscribe(pluginID string) (<-chan BusEvent, func()) {
	b.mu.Lock()
	s := &subscriber{
		id:     pluginID,
		topics: append([]string(nil), b.subscribes[pluginID]...),
		ch:     make(chan BusEvent, subChanCap),
	}
	b.subs[pluginID] = s
	for _, t := range s.topics {
		if b.byTopic[t] == nil {
			b.byTopic[t] = map[string]*subscriber{}
		}
		b.byTopic[t][pluginID] = s
	}
	affected := append([]string(nil), s.topics...)
	own := append([]string(nil), b.publishes[pluginID]...)
	b.mu.Unlock()

	// Announce this plugin's own publish demand first (so a just-connected
	// provider immediately knows the count), then the change its arrival
	// caused for whoever publishes the topics it subscribes to.
	b.announceDemand(own)
	b.announceDemand(affected)

	var once sync.Once
	cancel := func() {
		once.Do(func() {
			b.mu.Lock()
			if cur, ok := b.subs[pluginID]; ok && cur == s {
				delete(b.subs, pluginID)
			}
			for _, t := range s.topics {
				delete(b.byTopic[t], pluginID)
				if len(b.byTopic[t]) == 0 {
					delete(b.byTopic, t)
				}
			}
			s.closed = true
			close(s.ch)
			b.mu.Unlock()
			b.announceDemand(affected)
		})
	}
	return s.ch, cancel
}

// Publish delivers to every subscriber of topic and returns how many got
// it. An undeclared or reserved topic is refused and nothing is delivered.
func (b *Bus) Publish(pluginID, topic string, payload []byte, ts time.Time) (int, error) {
	if strings.HasPrefix(topic, reservedPrefix) {
		return 0, fmt.Errorf("plugin %q may not publish reserved topic %q", pluginID, topic)
	}
	b.mu.Lock()
	declared := false
	for _, t := range b.publishes[pluginID] {
		if t == topic {
			declared = true
			break
		}
	}
	b.mu.Unlock()
	if !declared {
		return 0, fmt.Errorf("plugin %q publishes undeclared topic %q", pluginID, topic)
	}
	return b.deliver(topic, BusEvent{Topic: topic, Payload: payload, TS: ts}), nil
}

// deliver is the non-blocking fan-out. It snapshots the subscriber set
// under the lock and sends outside it, so a send can never be holding the
// bus lock.
func (b *Bus) deliver(topic string, e BusEvent) int {
	b.mu.Lock()
	targets := make([]*subscriber, 0, len(b.byTopic[topic]))
	for _, s := range b.byTopic[topic] {
		targets = append(targets, s)
	}
	hook := b.onDelivered
	b.mu.Unlock()

	n := 0
	for _, s := range targets {
		select {
		case s.ch <- e:
			n++
			if hook != nil {
				hook(s.id, 1)
			}
		default:
			b.log.Warn("dropping event for slow subscriber",
				zap.String("plugin", s.id), zap.String("topic", topic))
		}
	}
	return n
}

// announceDemand sends the current subscriber count for each topic to
// whichever plugin declares that topic in its publishes.
func (b *Bus) announceDemand(topics []string) {
	for _, topic := range topics {
		b.mu.Lock()
		count := len(b.byTopic[topic])
		var publisher *subscriber
		for id, pubTopics := range b.publishes {
			for _, t := range pubTopics {
				if t == topic {
					publisher = b.subs[id]
					break
				}
			}
			if publisher != nil {
				break
			}
		}
		b.mu.Unlock()

		if publisher == nil {
			continue // provider not connected; it gets the count on Subscribe
		}
		payload, err := json.Marshal(DemandPayload{Topic: topic, Subscribers: count})
		if err != nil {
			continue
		}
		e := BusEvent{Topic: TopicDemand, Payload: payload, TS: time.Now()}
		select {
		case publisher.ch <- e:
		default:
			b.log.Warn("dropping demand event for slow publisher",
				zap.String("plugin", publisher.id), zap.String("topic", topic))
		}
	}
}

// Demand reports the current subscriber count for a topic.
func (b *Bus) Demand(topic string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.byTopic[topic])
}
