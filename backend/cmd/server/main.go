package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/api"
	"github.com/vibecare-io/vibecare/backend/internal/mcp"
	"github.com/vibecare-io/vibecare/backend/internal/scheduler"
	"github.com/vibecare-io/vibecare/backend/internal/storage"
	"github.com/vibecare-io/vibecare/backend/internal/telemetry"
	"github.com/vibecare-io/vibecare/backend/internal/web"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

func main() {
	var (
		port          = flag.Int("port", 50051, "The gRPC server port")
		webPort       = flag.Int("web-port", 8080, "The HTTP web server port")
		dbPath        = flag.String("db", "", "Path to SQLite database")
		otlpEndpoint  = flag.String("otel-endpoint", "localhost:4317", "OpenTelemetry OTLP endpoint")
		enableTracing = flag.Bool("enable-tracing", true, "Enable OpenTelemetry tracing")
		withMCP       = flag.Bool("with-mcp", false, "Enable MCP server (Model Context Protocol)")
		mcpProfileID  = flag.String("mcp-profile-id", "", "Profile ID for MCP server (required if --with-mcp is set)")
	)
	flag.Parse()

	// Setup logger
	logger, err := zap.NewDevelopment()
	if err != nil {
		log.Fatalf("Failed to initialize logger: %v", err)
	}
	defer logger.Sync()

	// Initialize OpenTelemetry tracing
	var shutdownTracer func(context.Context) error
	if *enableTracing {
		shutdownTracer, err = telemetry.InitTracer("vibecare-backend", *otlpEndpoint, logger)
		if err != nil {
			logger.Warn("Failed to initialize tracing, continuing without it", zap.Error(err))
		} else {
			defer func() {
				if err := shutdownTracer(context.Background()); err != nil {
					logger.Error("Failed to shutdown tracer", zap.Error(err))
				}
			}()
		}
	}

	// Determine database path
	if *dbPath == "" {
		homeDir, err := os.UserHomeDir()
		if err != nil {
			logger.Fatal("Failed to get home directory", zap.Error(err))
		}
		*dbPath = filepath.Join(homeDir, ".vibecare", "vibecare.db")

		// Create directory if it doesn't exist
		dir := filepath.Dir(*dbPath)
		if err := os.MkdirAll(dir, 0755); err != nil {
			logger.Fatal("Failed to create database directory", zap.Error(err))
		}
	}

	// Initialize database
	logger.Info("Opening database", zap.String("path", *dbPath))
	db, err := storage.New(*dbPath)
	if err != nil {
		logger.Fatal("Failed to open database", zap.Error(err))
	}
	defer db.Close()

	// Initialize MCP server if enabled
	var mcpServer *mcp.Server
	var mcpTransport *mcp.STDIOTransport
	if *withMCP {
		if *mcpProfileID == "" {
			logger.Fatal("--mcp-profile-id is required when --with-mcp is enabled")
		}

		logger.Info("Initializing MCP server", zap.String("profile_id", *mcpProfileID))
		storage := mcp.NewDBStorageAdapter(db)
		mcpServer = mcp.NewServer(storage, *mcpProfileID, logger)
		mcpTransport = mcp.NewSTDIOTransport(mcpServer, logger)

		if err := mcpTransport.Start(); err != nil {
			logger.Fatal("Failed to start MCP transport", zap.Error(err))
		}
	}

	// Initialize event hub
	eventHub := scheduler.NewEventHub(logger)

	// Initialize and start scheduler
	sched := scheduler.NewScheduler(db, eventHub, logger)
	go sched.Start()

	// Initialize and start web server (pass MCP server if enabled)
	webServer := web.NewServer(*webPort, db, sched, mcpServer, logger)
	go func() {
		if err := webServer.Start(); err != nil {
			logger.Error("Web server failed", zap.Error(err))
		}
	}()

	// Create gRPC server with OpenTelemetry interceptors
	// Order matters: panic recovery first, then OTel, then custom
	serverOpts := []grpc.ServerOption{}
	if *enableTracing {
		serverOpts = append(serverOpts,
			grpc.ChainUnaryInterceptor(
				telemetry.PanicRecoveryInterceptor(logger), // First: catch panics
				otelgrpc.UnaryServerInterceptor(),          // Second: create spans
				telemetry.UnaryServerInterceptor(logger),   // Third: add custom attributes
			),
		)
	}
	grpcServer := grpc.NewServer(serverOpts...)

	// Register services
	api.RegisterServices(grpcServer, db, eventHub, logger)

	// Register reflection service for debugging
	reflection.Register(grpcServer)

	// Start listening
	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", *port))
	if err != nil {
		logger.Fatal("Failed to listen", zap.Error(err))
	}

	// Setup graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	go func() {
		<-sigChan
		logger.Info("Shutting down servers...")

		// Create shutdown context with timeout
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()

		// Stop MCP server if running
		if mcpTransport != nil {
			logger.Info("Stopping MCP server...")
			if err := mcpTransport.Stop(); err != nil {
				logger.Error("Failed to stop MCP transport", zap.Error(err))
			}
		}

		// Stop scheduler first to prevent new events
		logger.Info("Stopping scheduler...")
		sched.Stop()

		// Shutdown web server
		logger.Info("Stopping web server...")
		if err := webServer.Shutdown(ctx); err != nil {
			logger.Error("Failed to shutdown web server gracefully", zap.Error(err))
		}

		// Attempt graceful shutdown of gRPC server with timeout
		done := make(chan struct{})
		go func() {
			grpcServer.GracefulStop()
			close(done)
		}()

		select {
		case <-done:
			logger.Info("gRPC server gracefully stopped")
		case <-ctx.Done():
			logger.Warn("Graceful shutdown timeout, forcing stop")
			grpcServer.Stop()
		}
	}()

	logger.Info("VibeCare servers starting",
		zap.Int("grpc_port", *port),
		zap.Int("web_port", *webPort))
	if err := grpcServer.Serve(lis); err != nil {
		logger.Fatal("Failed to serve", zap.Error(err))
	}
}
