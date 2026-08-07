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
	"github.com/vibecare-io/vibecare/backend/internal/plugins"
	"github.com/vibecare-io/vibecare/backend/internal/scheduler"
	"github.com/vibecare-io/vibecare/backend/internal/storage"
	"github.com/vibecare-io/vibecare/backend/internal/telemetry"
	"github.com/vibecare-io/vibecare/backend/internal/web"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

// initLogger creates a zap logger with configurable level and format
func initLogger(levelFlag, formatFlag string) (*zap.Logger, error) {
	// Environment variables take precedence over flags
	levelStr := os.Getenv("LOG_LEVEL")
	if levelStr == "" {
		levelStr = levelFlag
	}

	formatStr := os.Getenv("LOG_FORMAT")
	if formatStr == "" {
		formatStr = formatFlag
	}

	// Parse and validate log level
	level, err := zapcore.ParseLevel(levelStr)
	if err != nil {
		return nil, fmt.Errorf("invalid log level %q: %w", levelStr, err)
	}

	// Create base config based on format
	var config zap.Config
	switch formatStr {
	case "json":
		config = zap.NewProductionConfig()
	case "console":
		config = zap.NewDevelopmentConfig()
	default:
		return nil, fmt.Errorf("invalid log format %q: must be 'console' or 'json'", formatStr)
	}

	// Set the log level
	config.Level = zap.NewAtomicLevelAt(level)

	// Build and return logger
	return config.Build()
}

func main() {
	var (
		port          = flag.Int("port", 50051, "The gRPC server port")
		webPort       = flag.Int("web-port", 8080, "The HTTP web server port")
		dbPath        = flag.String("db", "", "Path to SQLite database")
		otlpEndpoint  = flag.String("otel-endpoint", "localhost:4317", "OpenTelemetry OTLP endpoint")
		enableTracing = flag.Bool("enable-tracing", true, "Enable OpenTelemetry tracing")
		withMCP       = flag.Bool("with-mcp", false, "Enable MCP server (Model Context Protocol)")
		mcpProfileID  = flag.String("mcp-profile-id", "", "Profile ID for MCP server (required if --with-mcp is set)")
		logLevel      = flag.String("log-level", "info", "Log level (debug, info, warn, error)")
		logFormat     = flag.String("log-format", "console", "Log format (console, json)")
	)
	flag.Parse()

	// Setup logger
	logger, err := initLogger(*logLevel, *logFormat)
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

	// Initialize template loader
	logger.Info("Loading schedule templates")
	templateLoader := storage.NewTemplateLoader(logger)
	dataDir := filepath.Join(filepath.Dir(*dbPath), "..", "backend", "internal", "storage", "data")
	// Try relative path from project root
	if _, err := os.Stat(filepath.Join("backend", "internal", "storage", "data", "schedule_templates.json")); err == nil {
		dataDir = filepath.Join("backend", "internal", "storage", "data")
	}
	if err := templateLoader.LoadTemplates(dataDir); err != nil {
		logger.Warn("Failed to load templates, template service will not be available", zap.Error(err))
	}

	// Initialize icon loader
	logger.Info("Loading SVG icon catalog")
	iconLoader := storage.NewIconLoader(logger)
	if err := iconLoader.LoadIcons(dataDir); err != nil {
		logger.Warn("Failed to load icons, icon service will not be available", zap.Error(err))
	}

	// Initialize event hub
	eventHub := scheduler.NewEventHub(logger)

	// Initialize and start scheduler
	sched := scheduler.NewScheduler(db, eventHub, logger)
	go sched.Start()

	// Determine plugins directory (~/.vibecare/plugins), using the same
	// home-dir resolution as the default DB path, independent of whether
	// --db was overridden.
	homeDir, err := os.UserHomeDir()
	if err != nil {
		logger.Fatal("Failed to get home directory", zap.Error(err))
	}
	pluginsDir := filepath.Join(homeDir, ".vibecare", "plugins")

	// Initialize the plugin host service (the callback API plugins use to
	// talk back into Core: storage/events/notify/log) and the plugin
	// registry (discovers, launches, and supervises plugin subprocesses).
	// hostAddr is the address plugins dial to reach Core's HostService —
	// it's the same address Core's own gRPC server binds below, so it must
	// only start accepting connections once the server is actually serving.
	hostService := plugins.NewHostService(db, eventHub, logger)
	hostAddr := fmt.Sprintf("localhost:%d", *port)
	pluginRegistry := plugins.NewRegistry(pluginsDir, hostService, hostAddr, logger)

	// Create HTTP tracer for web server instrumentation
	httpTracer := telemetry.GetTracer("vibecare.http.server")

	// Initialize and start web server with OpenTelemetry instrumentation
	webServer := web.NewServer(*webPort, db, sched, mcpServer, iconLoader, httpTracer, logger)
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
	api.RegisterServices(grpcServer, db, eventHub, templateLoader, iconLoader, pluginRegistry, logger)

	// Register the plugin HostService — the callback API plugin subprocesses
	// dial back into (at hostAddr, above) for storage/events/notify/log.
	//
	// KNOWN LIMITATION (v1): no interceptor is installed here to call
	// hostService.WithPluginID per call, so every plugin's Store/Query/
	// Delete calls land in the empty plugin_id namespace regardless of which
	// plugin made them. That's safe only because pluginRegistry (above)
	// refuses to load a second distinct plugin id. Fixing this — the SDK
	// sending the plugin id as call metadata plus a matching unary
	// interceptor here (or a per-plugin HostService listener) — is the
	// first task of the next slice; see
	// docs/superpowers/specs/2026-08-06-plugin-system-v1-design.md
	// "Known Limitations (v1)".
	pb.RegisterHostServiceServer(grpcServer, hostService)

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

	// shutdownComplete is closed once the shutdown goroutine below has
	// finished tearing everything down; main() blocks on it at the very
	// end now that grpcServer.Serve runs in its own goroutine (see below).
	shutdownComplete := make(chan struct{})

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

		// Stop plugin subprocesses and health polling
		logger.Info("Stopping plugin registry...")
		pluginRegistry.Stop()

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

		close(shutdownComplete)
	}()

	logger.Info("VibeCare servers starting",
		zap.Int("grpc_port", *port),
		zap.Int("web_port", *webPort))

	// Serve in the background so plugins can dial back into Core's
	// HostService (at hostAddr) as soon as the registry launches them below.
	go func() {
		if err := grpcServer.Serve(lis); err != nil {
			logger.Fatal("Failed to serve", zap.Error(err))
		}
	}()

	// Start the plugin registry only after the gRPC server has begun
	// serving. A plugin failing to load must not crash Core, so a registry
	// start error is logged and startup continues without it.
	logger.Info("Starting plugin registry", zap.String("dir", pluginsDir), zap.String("host_addr", hostAddr))
	if err := pluginRegistry.Start(context.Background()); err != nil {
		logger.Warn("Failed to start plugin registry; continuing without plugins", zap.Error(err))
	}

	<-shutdownComplete
}
