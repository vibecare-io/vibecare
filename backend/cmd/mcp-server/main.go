package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/mcp"
	"github.com/vibecare-io/vibecare/backend/pkg/config"
	"go.uber.org/zap"
)

func main() {
	// Load config from file first
	cfg, err := config.LoadOrDefault()
	if err != nil {
		log.Fatalf("Failed to load config: %v", err)
	}

	// Define flags with config values as defaults
	var (
		grpcAddr  = flag.String("grpc-addr", cfg.MCP.GRPCAddr, "VibeCare gRPC server address")
		profileID = flag.String("profile-id", cfg.MCP.ProfileID, "Profile ID for MCP operations")
		useHTTP   = flag.Bool("http", false, "Use HTTP+SSE transport instead of STDIO")
		httpPort  = flag.Int("port", cfg.MCP.Port, "HTTP server port (only with --http)")
	)
	flag.Parse()

	// Validate required profile ID (from config or flag)
	if *profileID == "" {
		configPath, _ := config.DefaultConfigPath()
		log.Fatalf("Profile ID is required. Either:\n  1. Run 'just mcp-configure' to set up config file, or\n  2. Provide --profile-id flag\n\nConfig file: %s", configPath)
	}

	// Setup logger
	logger, err := zap.NewDevelopment()
	if err != nil {
		log.Fatalf("Failed to initialize logger: %v", err)
	}
	defer logger.Sync()

	transportType := "STDIO"
	if *useHTTP {
		transportType = "HTTP+SSE"
	}

	logger.Info("Starting VibeCare MCP standalone server",
		zap.String("transport", transportType),
		zap.String("grpc_address", *grpcAddr),
		zap.String("profile_id", *profileID))

	// Create gRPC storage adapter
	storage, err := mcp.NewGRPCStorageAdapter(*grpcAddr, *profileID)
	if err != nil {
		logger.Fatal("Failed to create gRPC storage adapter", zap.Error(err))
	}

	// Type assertion to get Close method (if available)
	if closer, ok := storage.(interface{ Close() error }); ok {
		defer func() {
			if err := closer.Close(); err != nil {
				logger.Error("Failed to close gRPC connection", zap.Error(err))
			}
		}()
	}

	// Create MCP server
	mcpServer := mcp.NewServer(storage, *profileID, logger)

	// Setup graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	if *useHTTP {
		// HTTP+SSE mode
		runHTTPMode(mcpServer, *httpPort, logger, sigChan)
	} else {
		// STDIO mode
		runSTDIOMode(mcpServer, logger, sigChan)
	}

	logger.Info("MCP server stopped")
}

func runHTTPMode(mcpServer *mcp.Server, port int, logger *zap.Logger, sigChan chan os.Signal) {
	// Create Streamable HTTP transport (MCP 2025-06-18 spec)
	transport := mcp.NewStreamableHTTPTransport(mcpServer, logger)

	// Create HTTP server
	mux := http.NewServeMux()
	mux.Handle("/mcp", transport)

	server := &http.Server{
		Addr:         fmt.Sprintf(":%d", port),
		Handler:      mux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Start HTTP server
	go func() {
		logger.Info("MCP Streamable HTTP server listening", zap.Int("port", port))
		logger.Info("MCP endpoint", zap.String("url", fmt.Sprintf("http://localhost:%d/mcp", port)))
		logger.Info("Use with mcp-remote", zap.String("url", fmt.Sprintf("http://localhost:%d", port)))
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Fatal("HTTP server error", zap.Error(err))
		}
	}()

	// Wait for shutdown signal
	<-sigChan
	logger.Info("Shutting down HTTP server...")

	// Shutdown HTTP server
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		logger.Error("Failed to shutdown HTTP server", zap.Error(err))
	}

	// Shutdown transport
	if err := transport.Shutdown(); err != nil {
		logger.Error("Failed to shutdown HTTP transport", zap.Error(err))
	}

	// Shutdown MCP server
	if err := mcpServer.Shutdown(context.Background()); err != nil {
		logger.Error("Failed to shutdown MCP server", zap.Error(err))
	}
}

func runSTDIOMode(mcpServer *mcp.Server, logger *zap.Logger, sigChan chan os.Signal) {
	// Create STDIO transport
	transport := mcp.NewSTDIOTransport(mcpServer, logger)

	// Start transport
	if err := transport.Start(); err != nil {
		logger.Fatal("Failed to start MCP transport", zap.Error(err))
	}

	// Wait for shutdown signal
	<-sigChan
	logger.Info("Shutting down MCP server...")

	// Stop transport
	if err := transport.Stop(); err != nil {
		logger.Error("Failed to stop MCP transport", zap.Error(err))
	}

	// Shutdown MCP server
	if err := mcpServer.Shutdown(context.Background()); err != nil {
		logger.Error("Failed to shutdown MCP server", zap.Error(err))
	}
}
