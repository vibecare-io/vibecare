package vc

import (
	"context"
	"time"

	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
	"google.golang.org/protobuf/types/known/emptypb"
)

// alertBuffer absorbs a burst while the consumer is busy redrawing. Alerts
// are transient — core retains nothing — so a full buffer drops the newest
// rather than blocking the stream, and a consumer that has stopped reading
// has already stopped caring.
const alertBuffer = 32

// WatchAlerts follows Shell.Intents, converting each UIIntent into an Alert.
// The stream is reconnected with backoff, because a user leaves this open
// across a `just run` restart and expects it to come back on its own.
//
// The returned channel is closed when ctx is cancelled or the session is
// closed, so ranging over it terminates without a second signal.
func (s *Session) WatchAlerts(ctx context.Context) (<-chan Alert, error) {
	if s.ctx.Err() != nil {
		return nil, Errorf("session closed")
	}

	ch := make(chan Alert, alertBuffer)

	// The stream must die on either the caller's context or the session's,
	// and gRPC only takes one, so the two are merged here.
	sctx, cancel := context.WithCancel(ctx)
	go func() {
		select {
		case <-ctx.Done():
		case <-s.ctx.Done():
		}
		cancel()
	}()

	go func() {
		defer close(ch)
		defer cancel()

		wait := streamBackoff
		for sctx.Err() == nil {
			if s.streamAlerts(sctx, ch) {
				// A stream that delivered before it dropped is a restart,
				// not a broken target, so retry from the short pause.
				wait = streamBackoff
			}
			if sctx.Err() != nil {
				return
			}
			select {
			case <-sctx.Done():
				return
			case <-time.After(wait):
			}
			if wait < maxBackoff {
				wait *= 2
			}
		}
	}()

	return ch, nil
}

// streamAlerts runs one Intents stream to completion and reports whether it
// delivered anything, which is what tells the retry loop a restart from a
// target that was never there.
func (s *Session) streamAlerts(ctx context.Context, ch chan<- Alert) bool {
	stream, err := s.shell.Intents(ctx, &emptypb.Empty{})
	if err != nil {
		return false
	}
	delivered := false
	for {
		intent, err := stream.Recv()
		if err != nil {
			return delivered
		}
		a := intent.GetAlert()
		if a == nil {
			// UIIntent is a oneof with room to grow. An intent this client
			// does not understand is not an error, it is a newer core.
			continue
		}
		select {
		case ch <- alertFromProto(a):
			delivered = true
		case <-ctx.Done():
			return delivered
		default:
			// Buffer full: the consumer is behind, and holding the stream
			// open for it would stall every other subscriber too.
		}
	}
}

// alertFromProto stamps the client's receive time. Core carries no timestamp
// on an alert and retains nothing, so arrival here is the only time that
// exists.
func alertFromProto(a *clientv1.Alert) Alert {
	out := Alert{
		Received: time.Now(),
		Plugin:   a.GetPlugin(),
		Title:    a.GetTitle(),
		Body:     a.GetBody(),
		Level:    a.GetLevel(),
	}
	for _, act := range a.GetActions() {
		out.Actions = append(out.Actions, AlertAction{
			Label: act.GetLabel(),
			URL:   act.GetUrl(),
		})
	}
	return out
}
