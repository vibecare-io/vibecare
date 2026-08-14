package kernel

import (
	"sync"

	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
	"go.uber.org/zap"
)

// intentChanCap bounds one client's pending alerts. Alerts are transient
// and user-facing; a backlog of them is noise, not data worth keeping.
const intentChanCap = 16

type intentSub struct {
	ch     chan *clientv1.Alert
	closed bool
}

// Intents fans alerts out to every connected client. Alerts are the one UI
// path that is not HTML, because they must render with no window open and
// with the plugin's webview never loaded.
//
// Nothing is retained: a client that connects after an alert fired does not
// see it.
type Intents struct {
	log *zap.Logger

	mu   sync.Mutex
	subs map[*intentSub]struct{}
}

func NewIntents(log *zap.Logger) *Intents {
	return &Intents{log: log, subs: map[*intentSub]struct{}{}}
}

func (i *Intents) Subscribe() (<-chan *clientv1.Alert, func()) {
	s := &intentSub{ch: make(chan *clientv1.Alert, intentChanCap)}
	i.mu.Lock()
	i.subs[s] = struct{}{}
	i.mu.Unlock()

	var once sync.Once
	return s.ch, func() {
		once.Do(func() {
			i.mu.Lock()
			defer i.mu.Unlock()
			delete(i.subs, s)
			s.closed = true
			close(s.ch)
		})
	}
}

func (i *Intents) Broadcast(a *clientv1.Alert) {
	i.mu.Lock()
	defer i.mu.Unlock()
	for s := range i.subs {
		if s.closed {
			continue
		}
		select {
		case s.ch <- a:
		default:
			i.log.Warn("dropping alert for a client that is not keeping up",
				zap.String("plugin", a.GetPlugin()))
		}
	}
}
