package scheduler

import (
	"sync"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
)

// EventHub manages client connections and broadcasts events to subscribed clients
type EventHub struct {
	// Map of profile_id -> list of event channels
	clients map[string][]chan *pb.DispatchEvent
	mu      sync.RWMutex
	logger  *zap.Logger
}

// NewEventHub creates a new EventHub
func NewEventHub(logger *zap.Logger) *EventHub {
	return &EventHub{
		clients: make(map[string][]chan *pb.DispatchEvent),
		logger:  logger,
	}
}

// Subscribe adds a new client subscription for a profile
func (h *EventHub) Subscribe(profileID string) chan *pb.DispatchEvent {
	h.mu.Lock()
	defer h.mu.Unlock()

	// Create buffered channel to prevent blocking
	eventChan := make(chan *pb.DispatchEvent, 100)

	h.clients[profileID] = append(h.clients[profileID], eventChan)
	h.logger.Info("Client subscribed to events",
		zap.String("profile_id", profileID),
		zap.Int("total_clients", len(h.clients[profileID])))

	return eventChan
}

// Unsubscribe removes a client subscription
func (h *EventHub) Unsubscribe(profileID string, eventChan chan *pb.DispatchEvent) {
	h.mu.Lock()
	defer h.mu.Unlock()

	clients := h.clients[profileID]
	for i, ch := range clients {
		if ch == eventChan {
			// Remove from slice
			h.clients[profileID] = append(clients[:i], clients[i+1:]...)
			close(eventChan)
			h.logger.Info("Client unsubscribed from events",
				zap.String("profile_id", profileID),
				zap.Int("remaining_clients", len(h.clients[profileID])))
			break
		}
	}

	// Clean up empty profile entries
	if len(h.clients[profileID]) == 0 {
		delete(h.clients, profileID)
	}
}

// Broadcast sends an event to all subscribed clients for a profile
func (h *EventHub) Broadcast(profileID string, event *pb.DispatchEvent) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	clients, exists := h.clients[profileID]
	if !exists {
		h.logger.Debug("No clients subscribed for profile",
			zap.String("profile_id", profileID))
		return
	}

	h.logger.Info("Broadcasting event to clients",
		zap.String("profile_id", profileID),
		zap.String("event_type", event.EventType.String()),
		zap.Int("client_count", len(clients)))

	// Send to all clients, non-blocking
	for _, ch := range clients {
		select {
		case ch <- event:
			// Event sent successfully
		default:
			// Channel buffer full, skip this client
			h.logger.Warn("Client channel buffer full, dropping event",
				zap.String("profile_id", profileID))
		}
	}
}

// BroadcastToAll sends an event to all connected clients
func (h *EventHub) BroadcastToAll(event *pb.DispatchEvent) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	h.logger.Info("Broadcasting event to all clients",
		zap.String("event_type", event.EventType.String()),
		zap.Int("profile_count", len(h.clients)))

	for profileID := range h.clients {
		for _, ch := range h.clients[profileID] {
			select {
			case ch <- event:
				// Event sent successfully
			default:
				// Channel buffer full, skip this client
				h.logger.Warn("Client channel buffer full, dropping event",
					zap.String("profile_id", profileID))
			}
		}
	}
}

// GetClientCount returns the number of connected clients for a profile
func (h *EventHub) GetClientCount(profileID string) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients[profileID])
}

// GetTotalClientCount returns the total number of connected clients
func (h *EventHub) GetTotalClientCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()

	total := 0
	for _, clients := range h.clients {
		total += len(clients)
	}
	return total
}
