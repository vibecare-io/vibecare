package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"

	"go.uber.org/zap"
)

const (
	MCPProtocolVersion = "2024-11-05"
	ServerName         = "vibecare-mcp"
	ServerVersion      = "0.1.0"
)

// Server represents the MCP server
type Server struct {
	storage   Storage
	logger    *zap.Logger
	profileID string

	// Handler registry
	handlers map[string]HandlerFunc
	mu       sync.RWMutex

	// State
	initialized bool
}

// HandlerFunc is the signature for MCP method handlers
type HandlerFunc func(ctx context.Context, params json.RawMessage) (interface{}, error)

// NewServer creates a new MCP server instance
func NewServer(storage Storage, profileID string, logger *zap.Logger) *Server {
	s := &Server{
		storage:   storage,
		logger:    logger,
		profileID: profileID,
		handlers:  make(map[string]HandlerFunc),
	}

	// Register core protocol handlers
	s.RegisterHandler(MethodInitialize, s.handleInitialize)
	s.RegisterHandler(MethodListTools, s.handleListTools)
	s.RegisterHandler(MethodCallTool, s.handleCallTool)
	s.RegisterHandler(MethodListResources, s.handleListResources)
	s.RegisterHandler(MethodReadResource, s.handleReadResource)

	return s
}

// RegisterHandler registers a handler for a specific method
func (s *Server) RegisterHandler(method string, handler HandlerFunc) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.handlers[method] = handler
}

// HandleRequest processes an incoming JSON-RPC request
func (s *Server) HandleRequest(ctx context.Context, req *JSONRPCRequest) *JSONRPCResponse {
	s.logger.Debug("Handling MCP request",
		zap.String("method", req.Method),
		zap.Any("id", req.ID),
	)

	// Validate JSON-RPC version
	if req.JSONRPC != JSONRPCVersion {
		return NewErrorResponse(req.ID, InvalidRequest,
			"Invalid JSON-RPC version", nil)
	}

	// Check if method requires initialization
	if !s.initialized && req.Method != MethodInitialize {
		return NewErrorResponse(req.ID, InternalError,
			"Server not initialized", nil)
	}

	// Find handler
	s.mu.RLock()
	handler, exists := s.handlers[req.Method]
	s.mu.RUnlock()

	if !exists {
		return NewErrorResponse(req.ID, MethodNotFound,
			fmt.Sprintf("Method not found: %s", req.Method), nil)
	}

	// Execute handler
	result, err := handler(ctx, req.Params)
	if err != nil {
		s.logger.Error("Handler error",
			zap.String("method", req.Method),
			zap.Error(err),
		)
		return NewErrorResponse(req.ID, InternalError, err.Error(), nil)
	}

	return NewSuccessResponse(req.ID, result)
}

// handleInitialize handles the initialize request
func (s *Server) handleInitialize(ctx context.Context, params json.RawMessage) (interface{}, error) {
	var req InitializeRequest
	if len(params) > 0 {
		if err := json.Unmarshal(params, &req); err != nil {
			return nil, fmt.Errorf("invalid initialize params: %w", err)
		}
	}

	s.logger.Info("MCP client initializing",
		zap.String("protocol_version", req.ProtocolVersion),
		zap.String("client_name", req.ClientInfo.Name),
		zap.String("client_version", req.ClientInfo.Version),
	)

	// Mark as initialized
	s.initialized = true

	// Build server capabilities
	result := InitializeResult{
		ProtocolVersion: MCPProtocolVersion,
		Capabilities: ServerCapabilities{
			Tools: &ToolsCapability{
				ListChanged: false,
			},
			Resources: &ResourcesCapability{
				Subscribe:   false,
				ListChanged: false,
			},
		},
		ServerInfo: Implementation{
			Name:    ServerName,
			Version: ServerVersion,
		},
	}

	return result, nil
}

// handleListTools returns the list of available tools
func (s *Server) handleListTools(ctx context.Context, params json.RawMessage) (interface{}, error) {
	tools := s.GetTools()

	s.logger.Debug("Listing tools", zap.Int("count", len(tools)))

	return ListToolsResult{
		Tools: tools,
	}, nil
}

// handleCallTool executes a tool
func (s *Server) handleCallTool(ctx context.Context, params json.RawMessage) (interface{}, error) {
	var req CallToolRequest
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, fmt.Errorf("invalid tool call params: %w", err)
	}

	// Log tool name at Info level
	s.logger.Info("Calling tool", zap.String("tool", req.Name))

	// Log parameters at Debug level only (conditional to avoid serialization overhead)
	if s.logger.Core().Enabled(zap.DebugLevel) {
		s.logger.Debug("Tool parameters",
			zap.String("tool", req.Name),
			zap.Any("arguments", req.Arguments),
		)
	}

	// Execute the tool
	result, err := s.executeTool(ctx, req.Name, req.Arguments)
	if err != nil {
		s.logger.Error("Tool execution failed",
			zap.String("tool", req.Name),
			zap.Error(err),
		)
		return CallToolResult{
			Content: []Content{ErrorContent(err.Error())},
			IsError: true,
		}, nil
	}

	return result, nil
}

// handleListResources returns the list of available resources
func (s *Server) handleListResources(ctx context.Context, params json.RawMessage) (interface{}, error) {
	resources := s.GetResources()

	s.logger.Debug("Listing resources", zap.Int("count", len(resources)))

	return ListResourcesResult{
		Resources: resources,
	}, nil
}

// handleReadResource reads a specific resource
func (s *Server) handleReadResource(ctx context.Context, params json.RawMessage) (interface{}, error) {
	var req ReadResourceRequest
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, fmt.Errorf("invalid read resource params: %w", err)
	}

	s.logger.Info("Reading resource", zap.String("uri", req.URI))

	// Read the resource
	contents, err := s.readResource(ctx, req.URI)
	if err != nil {
		return nil, fmt.Errorf("failed to read resource: %w", err)
	}

	return ReadResourceResult{
		Contents: contents,
	}, nil
}

// Shutdown gracefully shuts down the MCP server
func (s *Server) Shutdown(ctx context.Context) error {
	s.logger.Info("Shutting down MCP server")
	s.initialized = false
	return nil
}
