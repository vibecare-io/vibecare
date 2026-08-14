package api

import (
	"github.com/vibecare-io/vibecare/backend/internal/scheduler"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// SubscribeEvents allows clients to subscribe to dispatch events
func (s *Server) SubscribeEvents(req *pb.SubscribeEventsRequest, stream pb.EventService_SubscribeEventsServer) error {
	profileID := req.ProfileId
	if profileID == "" {
		return status.Errorf(codes.InvalidArgument, "profile_id is required")
	}

	s.logger.Info("Client subscribing to events",
		zap.String("profile_id", profileID),
		zap.Any("event_types", req.EventTypes))

	// Subscribe to the event hub
	eventChan := s.eventHub.Subscribe(profileID)
	defer s.eventHub.Unsubscribe(profileID, eventChan)

	// Stream events to the client
	for {
		select {
		case event, ok := <-eventChan:
			if !ok {
				// Channel closed, client unsubscribed
				s.logger.Info("Event channel closed",
					zap.String("profile_id", profileID))
				return nil
			}

			// Filter by event types if specified
			if len(req.EventTypes) > 0 {
				if !s.shouldSendEvent(event.EventType, req.EventTypes) {
					continue
				}
			}

			// Send event to client
			if err := stream.Send(event); err != nil {
				s.logger.Error("Failed to send event to client",
					zap.String("profile_id", profileID),
					zap.Error(err))
				return err
			}

			s.logger.Debug("Sent event to client",
				zap.String("profile_id", profileID),
				zap.String("event_id", event.EventId),
				zap.String("event_type", event.EventType.String()))

		case <-stream.Context().Done():
			// Client disconnected
			s.logger.Info("Client disconnected",
				zap.String("profile_id", profileID))
			return stream.Context().Err()
		}
	}
}

// shouldSendEvent checks if an event matches the requested event types
func (s *Server) shouldSendEvent(eventType pb.EventType, requestedTypes []pb.EventType) bool {
	for _, reqType := range requestedTypes {
		if eventType == reqType {
			return true
		}
	}
	return false
}

// SetEventHub sets the event hub for the server
func (s *Server) SetEventHub(hub *scheduler.EventHub) {
	s.eventHub = hub
}
