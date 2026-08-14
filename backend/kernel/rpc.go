package kernel

import (
	"context"
	"sync"

	"github.com/vibecare-io/vibecare/backend/pkg/pluginwire"
	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
	pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Host implements PluginHost, the only gRPC surface plugins ever touch.
// Three RPCs, one of them a stream. A plugin author writes an HTTP server
// — trivial in every language — plus these three outbound calls, and never
// implements a service.
type Host struct {
	pluginv1.UnimplementedPluginHostServer

	reg     *Registry
	bus     *Bus
	sup     *Supervisor
	health  *Health
	intents *Intents
	log     *zap.Logger

	mu      sync.Mutex
	streams map[string]chan *pluginv1.CoreMsg // plugin id -> its stream's outbox
}

func NewHost(reg *Registry, bus *Bus, sup *Supervisor, h *Health, in *Intents, log *zap.Logger) *Host {
	return &Host{
		reg: reg, bus: bus, sup: sup, health: h, intents: in, log: log,
		streams: map[string]chan *pluginv1.CoreMsg{},
	}
}

// Register is the plugin's whole control plane. One open stream does three
// jobs: confirms registration, delivers subscribed events, and signals
// graceful shutdown.
func (h *Host) Register(req *pluginv1.RegisterReq, stream pluginv1.PluginHost_RegisterServer) error {
	id := req.GetId()
	if _, known := h.reg.Manifest(id); !known {
		return status.Errorf(codes.NotFound, "no discovered plugin with id %q", id)
	}
	if req.GetHttpPort() == 0 {
		return status.Error(codes.InvalidArgument, "http_port is required")
	}

	h.reg.SetPort(id, req.GetHttpPort())
	h.sup.NotifyRegistered(id)
	h.health.Reset(id)

	// Core-originated messages (currently only Shutdown) go through this
	// outbox so BroadcastShutdown never blocks on a wedged plugin.
	out := make(chan *pluginv1.CoreMsg, 4)
	h.mu.Lock()
	h.streams[id] = out
	h.mu.Unlock()

	events, unsubscribe := h.bus.Subscribe(id)

	defer func() {
		unsubscribe()

		h.mu.Lock()
		cur, ok := h.streams[id]
		stillCurrent := ok && cur == out
		if stillCurrent {
			delete(h.streams, id)
		}
		h.mu.Unlock()

		// A stream loss is only meaningful for the plugin's CURRENT
		// registration. Two Register calls can overlap across a
		// reconnect: the new one already ran (setting StateUp) while
		// this, the old handler, was still blocked in stream.Send on a
		// dead transport. If a newer stream has since taken over
		// h.streams[id] — the identity check above — then this teardown
		// belongs to a superseded connection and must not touch the
		// roster at all. Doing so would demote the healthy replacement to
		// "reconnecting" with nothing to ever recover it: Health.ProbeOnce
		// skips any plugin that isn't up/degraded.
		if !stillCurrent {
			return
		}

		// A dropped stream does NOT mean the process died — the SDK
		// reconnects without exiting, which is what makes a core restart
		// survivable. Only reflect it if the supervisor hasn't already
		// decided the plugin is down or failed, and commit the move
		// atomically: reading the state and writing it back as two
		// separately-locked steps would let the supervisor's own
		// down/failed transition land in between and be silently
		// clobbered by this one. CompareAndSetState closes that window;
		// if it reports the state moved on before we could act, we just
		// drop this transition.
		//
		// The identity check above and this CAS answer different
		// questions and both are required: identity asks "am I still the
		// live stream for this plugin?"; the CAS asks "did someone else
		// move the state while I was deciding?".
		if observed, ok := h.reg.State(id); ok && (observed == StateUp || observed == StateDegraded) {
			h.reg.CompareAndSetState(id, observed, StateStarting, "reconnecting")
		}
	}()

	if err := stream.Send(&pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Ready{Ready: &pluginv1.Ready{}}}); err != nil {
		return err
	}
	h.reg.SetState(id, StateUp, "")
	h.log.Info("plugin registered", zap.String("plugin", id), zap.Uint32("http_port", req.GetHttpPort()))

	for {
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()

		case msg := <-out:
			if err := stream.Send(msg); err != nil {
				return err
			}

		case e, ok := <-events:
			if !ok {
				return nil
			}
			err := stream.Send(&pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Event{Event: &pluginv1.Event{
				Topic:   e.Topic,
				Payload: e.Payload,
				Ts:      timestamppb.New(e.TS),
			}}})
			if err != nil {
				return err
			}
		}
	}
}

// Publish moves an event onto the bus. The caller is attributed from call
// metadata: Event carries no plugin field, and trusting a self-declared one
// would make the manifest's publishes list meaningless.
func (h *Host) Publish(ctx context.Context, e *pluginv1.Event) (*emptypb.Empty, error) {
	id, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	if _, known := h.reg.Manifest(id); !known {
		return nil, status.Errorf(codes.PermissionDenied, "unknown plugin %q", id)
	}

	ts := e.GetTs().AsTime()
	if !e.GetTs().IsValid() {
		ts = timestamppb.Now().AsTime()
	}

	// Delivery counts are attributed to each SUBSCRIBER by the bus's
	// OnDelivered hook (wired in kernel.go), so nothing is counted here
	// beyond the publish itself.
	if _, err := h.bus.Publish(id, e.GetTopic(), e.GetPayload(), ts); err != nil {
		// Manifests stay honest: the message is dropped and the author is
		// told why, rather than silently vanishing.
		h.log.Error("rejected publish", zap.String("plugin", id), zap.String("topic", e.GetTopic()), zap.Error(err))
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}
	h.reg.CountPublished(id)
	return &emptypb.Empty{}, nil
}

// Alert hands a user-facing notification to every connected client.
func (h *Host) Alert(ctx context.Context, r *pluginv1.AlertReq) (*emptypb.Empty, error) {
	id, err := callerID(ctx)
	if err != nil {
		return nil, err
	}
	if _, known := h.reg.Manifest(id); !known {
		return nil, status.Errorf(codes.PermissionDenied, "unknown plugin %q", id)
	}

	h.intents.Broadcast(&clientv1.Alert{
		Plugin:  id,
		Title:   r.GetTitle(),
		Body:    r.GetBody(),
		Level:   r.GetLevel(),
		Actions: r.GetActions(),
	})
	return &emptypb.Empty{}, nil
}

// BroadcastShutdown tells every connected plugin to close its listener and
// flush storage. Core follows it with SIGTERM (see Supervisor.Stop).
func (h *Host) BroadcastShutdown(reason string) {
	h.mu.Lock()
	outs := make([]chan *pluginv1.CoreMsg, 0, len(h.streams))
	for _, out := range h.streams {
		outs = append(outs, out)
	}
	h.mu.Unlock()

	msg := &pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Shutdown{Shutdown: &pluginv1.Shutdown{Reason: reason}}}
	for _, out := range outs {
		select {
		case out <- msg:
		default: // wedged plugin; SIGTERM/SIGKILL will handle it
		}
	}
}

// callerID reads the plugin id the SDK attaches to every outbound call.
func callerID(ctx context.Context) (string, error) {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return "", status.Error(codes.Unauthenticated, "missing call metadata")
	}
	vals := md.Get(pluginwire.PluginIDMetadataKey)
	if len(vals) == 0 || vals[0] == "" {
		return "", status.Error(codes.Unauthenticated, "missing plugin id in call metadata")
	}
	return vals[0], nil
}
