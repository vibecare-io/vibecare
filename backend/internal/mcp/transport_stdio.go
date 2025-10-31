package mcp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"

	"go.uber.org/zap"
)

// STDIOTransport handles MCP communication over stdin/stdout
type STDIOTransport struct {
	server *Server
	logger *zap.Logger

	stdin  io.Reader
	stdout io.Writer

	wg     sync.WaitGroup
	ctx    context.Context
	cancel context.CancelFunc
}

// NewSTDIOTransport creates a new STDIO transport
func NewSTDIOTransport(server *Server, logger *zap.Logger) *STDIOTransport {
	ctx, cancel := context.WithCancel(context.Background())

	return &STDIOTransport{
		server: server,
		logger: logger,
		stdin:  os.Stdin,
		stdout: os.Stdout,
		ctx:    ctx,
		cancel: cancel,
	}
}

// Start begins listening on stdin and processing requests
func (t *STDIOTransport) Start() error {
	t.logger.Info("Starting MCP STDIO transport")

	t.wg.Add(1)
	go t.readLoop()

	return nil
}

// readLoop reads JSON-RPC messages from stdin
func (t *STDIOTransport) readLoop() {
	defer t.wg.Done()

	scanner := bufio.NewScanner(t.stdin)
	// Increase buffer size for large messages
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, 1024*1024) // 1MB max

	for scanner.Scan() {
		select {
		case <-t.ctx.Done():
			return
		default:
		}

		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		t.logger.Debug("Received message", zap.Int("bytes", len(line)))

		// Try to parse as JSON-RPC request
		var req JSONRPCRequest
		if err := json.Unmarshal(line, &req); err != nil {
			t.logger.Error("Failed to parse request", zap.Error(err))
			t.sendError(nil, ParseError, "Parse error", err.Error())
			continue
		}

		// Handle the request
		t.handleRequest(&req)
	}

	if err := scanner.Err(); err != nil {
		if err != io.EOF {
			t.logger.Error("Error reading from stdin", zap.Error(err))
		}
	}
}

// handleRequest processes a single request
func (t *STDIOTransport) handleRequest(req *JSONRPCRequest) {
	// Handle notification (no response expected)
	if req.ID == nil && req.Method == MethodInitialized {
		t.logger.Info("Client initialized notification received")
		return
	}

	// Process request and get response
	resp := t.server.HandleRequest(t.ctx, req)

	// Send response
	if err := t.sendResponse(resp); err != nil {
		t.logger.Error("Failed to send response", zap.Error(err))
	}
}

// sendResponse sends a JSON-RPC response to stdout
func (t *STDIOTransport) sendResponse(resp *JSONRPCResponse) error {
	data, err := json.Marshal(resp)
	if err != nil {
		return fmt.Errorf("failed to marshal response: %w", err)
	}

	t.logger.Debug("Sending response", zap.Int("bytes", len(data)))

	// Write to stdout with newline delimiter
	if _, err := t.stdout.Write(append(data, '\n')); err != nil {
		return fmt.Errorf("failed to write response: %w", err)
	}

	return nil
}

// sendError sends an error response
func (t *STDIOTransport) sendError(id interface{}, code int, message string, data interface{}) {
	resp := NewErrorResponse(id, code, message, data)
	if err := t.sendResponse(resp); err != nil {
		t.logger.Error("Failed to send error response", zap.Error(err))
	}
}

// SendNotification sends a JSON-RPC notification
func (t *STDIOTransport) SendNotification(method string, params interface{}) error {
	notif, err := NewNotification(method, params)
	if err != nil {
		return fmt.Errorf("failed to create notification: %w", err)
	}

	data, err := json.Marshal(notif)
	if err != nil {
		return fmt.Errorf("failed to marshal notification: %w", err)
	}

	t.logger.Debug("Sending notification",
		zap.String("method", method),
		zap.Int("bytes", len(data)),
	)

	if _, err := t.stdout.Write(append(data, '\n')); err != nil {
		return fmt.Errorf("failed to write notification: %w", err)
	}

	return nil
}

// Stop gracefully stops the transport
func (t *STDIOTransport) Stop() error {
	t.logger.Info("Stopping MCP STDIO transport")
	t.cancel()
	t.wg.Wait()
	return nil
}
