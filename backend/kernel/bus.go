package kernel

import (
	"encoding/json"
	"fmt"
	"slices"
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
			// A reconnecting plugin calls Subscribe again before its old
			// stream's teardown runs cancel. Both subscriptions share the
			// same plugin id AND the same topic list, so b.byTopic[t][id]
			// now points at the NEW subscriber, not this one. Blindly
			// deleting from b.byTopic here would unroute the live
			// replacement — it would stay open, report up, and pass
			// health probes while receiving zero events for the rest of
			// its life. The identity check on b.subs guards the map entry
			// but NOT b.byTopic, which is keyed the same way and just as
			// exposed, so it needs the same guard. A stale cancel that
			// does nothing is strictly better than one that unroutes a
			// live subscriber, so skip the byTopic deletes, the channel
			// close, and the demand re-announce entirely when this
			// subscriber has already been superseded.
			cur, ok := b.subs[pluginID]
			current := ok && cur == s
			if !current {
				b.mu.Unlock()
				return
			}
			delete(b.subs, pluginID)
			for _, t := range s.topics {
				delete(b.byTopic[t], pluginID)
				if len(b.byTopic[t]) == 0 {
					delete(b.byTopic, t)
				}
			}
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
	declared := slices.Contains(b.publishes[pluginID], topic)
	b.mu.Unlock()
	if !declared {
		return 0, fmt.Errorf("plugin %q publishes undeclared topic %q", pluginID, topic)
	}
	return b.deliver(topic, BusEvent{Topic: topic, Payload: payload, TS: ts}), nil
}

// deliver is the non-blocking fan-out. Sends happen WHILE holding b.mu, not
// after releasing it: cancel() also closes a subscriber's channel under
// b.mu, and a select-with-default only guards a full channel, not a closed
// one — sending on a closed channel panics unconditionally, and -race
// cannot see that particular race. Holding the lock across the sends makes
// send and close mutually exclusive, which is what actually prevents the
// panic. The onDelivered hook is invoked afterward, outside the lock: a
// hook that re-entered the bus while the bus held its own mutex would
// deadlock.
func (b *Bus) deliver(topic string, e BusEvent) int {
	b.mu.Lock()
	var delivered []string
	for _, s := range b.byTopic[topic] {
		select {
		case s.ch <- e:
			delivered = append(delivered, s.id)
		default:
			b.log.Warn("dropping event for slow subscriber",
				zap.String("plugin", s.id), zap.String("topic", topic))
		}
	}
	hook := b.onDelivered
	b.mu.Unlock()

	if hook != nil {
		for _, id := range delivered {
			hook(id, 1)
		}
	}
	return len(delivered)
}

// announceDemand sends the current subscriber count for each topic to EVERY
// connected plugin that declares that topic in its publishes — not just the
// first one found. Two plugins can publish the same topic (e.g. two camera
// providers), and this is a privacy property enforced by mechanism (§10.2):
// if only one of several publishers were notified, the others could miss
// demand dropping to zero and keep a capture session open indefinitely.
// Like deliver, the send happens WHILE holding b.mu so it can never race a
// concurrent cancel() closing the same channel — see the comment on
// deliver.
func (b *Bus) announceDemand(topics []string) {
	for _, topic := range topics {
		b.mu.Lock()
		count := len(b.byTopic[topic])
		var publishers []*subscriber
		for id, pubTopics := range b.publishes {
			if !slices.Contains(pubTopics, topic) {
				continue
			}
			if s, ok := b.subs[id]; ok {
				publishers = append(publishers, s)
			}
			// Not connected: it gets the count on its own Subscribe.
		}
		if len(publishers) == 0 {
			b.mu.Unlock()
			continue
		}
		payload, err := json.Marshal(DemandPayload{Topic: topic, Subscribers: count})
		if err != nil {
			b.mu.Unlock()
			continue
		}
		e := BusEvent{Topic: TopicDemand, Payload: payload, TS: time.Now()}
		for _, publisher := range publishers {
			select {
			case publisher.ch <- e:
			default:
				b.log.Warn("dropping demand event for slow publisher",
					zap.String("plugin", publisher.id), zap.String("topic", topic))
			}
		}
		b.mu.Unlock()
	}
}

// Demand reports the current subscriber count for a topic.
func (b *Bus) Demand(topic string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.byTopic[topic])
}
