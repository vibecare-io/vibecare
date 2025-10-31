package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/google/uuid"
	"go.uber.org/zap"
)

// StreamableHTTPTransport implements MCP Streamable HTTP transport (2025-06-18 spec)
// Single /mcp endpoint supporting POST (send messages) and GET (receive via SSE)
type StreamableHTTPTransport struct {
	server *Server
	logger *zap.Logger
	ctx    context.Context
	cancel context.CancelFunc

	// Session management
	mu       sync.RWMutex
	sessions map[string]*Session
}

// Session represents an MCP session
type Session struct {
	ID      string
	Created time.Time
	SSEConn chan *JSONRPCResponse
}

// NewStreamableHTTPTransport creates a new Streamable HTTP transport
func NewStreamableHTTPTransport(server *Server, logger *zap.Logger) *StreamableHTTPTransport {
	ctx, cancel := context.WithCancel(context.Background())
	return &StreamableHTTPTransport{
		server:   server,
		logger:   logger,
		ctx:      ctx,
		cancel:   cancel,
		sessions: make(map[string]*Session),
	}
}

// ServeHTTP implements http.Handler for the /mcp endpoint
func (t *StreamableHTTPTransport) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Set CORS headers
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version, Last-Event-ID")

	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	// Route based on method
	switch r.Method {
	case "POST":
		t.handlePOST(w, r)
	case "GET":
		t.handleGET(w, r)
	case "DELETE":
		t.handleDELETE(w, r)
	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

// handlePOST processes JSON-RPC messages from client
func (t *StreamableHTTPTransport) handlePOST(w http.ResponseWriter, r *http.Request) {
	// Read request body
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Failed to read body", http.StatusBadRequest)
		return
	}

	// Parse JSON-RPC request
	var req JSONRPCRequest
	if err := json.Unmarshal(body, &req); err != nil {
		t.logger.Error("Failed to parse request", zap.Error(err))
		http.Error(w, "Invalid JSON-RPC", http.StatusBadRequest)
		return
	}

	t.logger.Debug("Received POST message", zap.String("method", req.Method))

	// Handle the request
	resp := t.server.HandleRequest(t.ctx, &req)

	// Check if this is an initialize request
	if req.Method == "initialize" {
		// Create session
		sessionID := uuid.New().String()
		session := &Session{
			ID:      sessionID,
			Created: time.Now(),
			SSEConn: make(chan *JSONRPCResponse, 10),
		}

		t.mu.Lock()
		t.sessions[sessionID] = session
		t.mu.Unlock()

		t.logger.Info("Created new session", zap.String("session_id", sessionID))

		// Set session ID in response header
		w.Header().Set("Mcp-Session-Id", sessionID)
	} else {
		// Validate session for non-initialize requests
		sessionID := r.Header.Get("Mcp-Session-Id")
		if sessionID == "" {
			http.Error(w, "Missing Mcp-Session-Id header", http.StatusBadRequest)
			return
		}

		t.mu.RLock()
		_, exists := t.sessions[sessionID]
		t.mu.RUnlock()

		if !exists {
			http.Error(w, "Invalid session", http.StatusNotFound)
			return
		}
	}

	// Check Accept header to determine response format
	accept := r.Header.Get("Accept")
	wantsSSE := false
	for _, mediaType := range parseAcceptHeader(accept) {
		if mediaType == "text/event-stream" {
			wantsSSE = true
			break
		}
	}

	// If notification or response (no ID), return 202 Accepted
	if resp.ID == nil && resp.Error == nil {
		w.WriteHeader(http.StatusAccepted)
		return
	}

	// If client wants SSE and we can stream, use SSE
	if wantsSSE {
		t.streamSSEResponse(w, resp)
	} else {
		// Return JSON response
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(resp)
	}
}

// handleGET opens SSE stream for server-to-client messages
func (t *StreamableHTTPTransport) handleGET(w http.ResponseWriter, r *http.Request) {
	// Check Accept header
	accept := r.Header.Get("Accept")
	wantsSSE := false
	for _, mediaType := range parseAcceptHeader(accept) {
		if mediaType == "text/event-stream" {
			wantsSSE = true
			break
		}
	}

	if !wantsSSE {
		http.Error(w, "Must accept text/event-stream", http.StatusNotAcceptable)
		return
	}

	// Validate session
	sessionID := r.Header.Get("Mcp-Session-Id")
	if sessionID == "" {
		http.Error(w, "Missing Mcp-Session-Id header", http.StatusBadRequest)
		return
	}

	t.mu.RLock()
	session, exists := t.sessions[sessionID]
	t.mu.RUnlock()

	if !exists {
		http.Error(w, "Invalid session", http.StatusNotFound)
		return
	}

	// Check if we can do SSE
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "Streaming unsupported", http.StatusInternalServerError)
		return
	}

	// Set SSE headers
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)

	t.logger.Info("SSE stream opened", zap.String("session", sessionID))

	// Stream responses
	for {
		select {
		case <-r.Context().Done():
			t.logger.Info("SSE stream closed by client", zap.String("session", sessionID))
			return
		case <-t.ctx.Done():
			t.logger.Info("SSE stream closed by server", zap.String("session", sessionID))
			return
		case resp := <-session.SSEConn:
			data, err := json.Marshal(resp)
			if err != nil {
				t.logger.Error("Failed to marshal response", zap.Error(err))
				continue
			}

			fmt.Fprintf(w, "data: %s\n\n", data)
			flusher.Flush()
		}
	}
}

// handleDELETE terminates a session
func (t *StreamableHTTPTransport) handleDELETE(w http.ResponseWriter, r *http.Request) {
	sessionID := r.Header.Get("Mcp-Session-Id")
	if sessionID == "" {
		http.Error(w, "Missing Mcp-Session-Id header", http.StatusBadRequest)
		return
	}

	t.mu.Lock()
	session, exists := t.sessions[sessionID]
	if exists {
		close(session.SSEConn)
		delete(t.sessions, sessionID)
	}
	t.mu.Unlock()

	if !exists {
		http.Error(w, "Invalid session", http.StatusNotFound)
		return
	}

	t.logger.Info("Session terminated", zap.String("session", sessionID))
	w.WriteHeader(http.StatusOK)
}

// streamSSEResponse sends a response via SSE
func (t *StreamableHTTPTransport) streamSSEResponse(w http.ResponseWriter, resp *JSONRPCResponse) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		// Fallback to JSON
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(resp)
		return
	}

	// Set SSE headers
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)

	// Send response as SSE event
	data, err := json.Marshal(resp)
	if err != nil {
		t.logger.Error("Failed to marshal response", zap.Error(err))
		return
	}

	fmt.Fprintf(w, "data: %s\n\n", data)
	flusher.Flush()

	// Close the stream after sending response
	// (per spec: stream should close after sending response)
}

// Shutdown gracefully shuts down the transport
func (t *StreamableHTTPTransport) Shutdown() error {
	t.logger.Info("Shutting down Streamable HTTP transport")
	t.cancel()

	// Close all sessions
	t.mu.Lock()
	for sessionID, session := range t.sessions {
		close(session.SSEConn)
		delete(t.sessions, sessionID)
	}
	t.mu.Unlock()

	return nil
}

// parseAcceptHeader parses Accept header and returns media types
func parseAcceptHeader(accept string) []string {
	if accept == "" {
		return []string{}
	}

	var mediaTypes []string
	for _, part := range splitAndTrim(accept, ",") {
		// Simple parsing: just get the media type before any parameters
		mediaType := splitAndTrim(part, ";")[0]
		if mediaType != "" {
			mediaTypes = append(mediaTypes, mediaType)
		}
	}
	return mediaTypes
}

// splitAndTrim splits a string and trims whitespace from each part
func splitAndTrim(s string, sep string) []string {
	parts := []string{}
	for _, part := range splitString(s, sep) {
		trimmed := trimSpace(part)
		if trimmed != "" {
			parts = append(parts, trimmed)
		}
	}
	return parts
}

// splitString splits a string by separator
func splitString(s, sep string) []string {
	if s == "" {
		return []string{}
	}

	result := []string{}
	start := 0
	for i := 0; i < len(s); i++ {
		if i+len(sep) <= len(s) && s[i:i+len(sep)] == sep {
			result = append(result, s[start:i])
			start = i + len(sep)
			i += len(sep) - 1
		}
	}
	result = append(result, s[start:])
	return result
}

// trimSpace trims leading and trailing whitespace
func trimSpace(s string) string {
	start := 0
	end := len(s)

	for start < end && (s[start] == ' ' || s[start] == '\t' || s[start] == '\n' || s[start] == '\r') {
		start++
	}

	for end > start && (s[end-1] == ' ' || s[end-1] == '\t' || s[end-1] == '\n' || s[end-1] == '\r') {
		end--
	}

	return s[start:end]
}
