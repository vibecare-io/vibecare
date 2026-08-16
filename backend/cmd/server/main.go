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
	"github.com/vibecare-io/vibecare/backend/kernel"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

// version is the build version, overridden at build time via
// `-ldflags "-X main.version=$VERSION"`.
var version = "dev"

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

	// Also write logs to ~/.vibecare/logs/server.log. This is done
	// server-side (rather than via the LaunchAgent plist's StandardOutPath)
	// because launchd does not expand "~" in plist paths, and resolving it
	// here keeps behavior identical across the bundled LaunchAgent and
	// `just run`/direct invocation on any OS. stderr is kept in
	// OutputPaths/ErrorOutputPaths so console output is unaffected; if the
	// log directory can't be created, we degrade gracefully to stderr-only
	// instead of failing startup.
	if home, err := os.UserHomeDir(); err == nil {
		logDir := filepath.Join(home, ".vibecare", "logs")
		if err := os.MkdirAll(logDir, 0o755); err != nil {
			log.Printf("Failed to create log directory %q, logging to stderr only: %v", logDir, err)
		} else {
			logFile := filepath.Join(logDir, "server.log")
			config.OutputPaths = append(config.OutputPaths, logFile)
			config.ErrorOutputPaths = append(config.ErrorOutputPaths, logFile)
		}
	} else {
		log.Printf("Failed to resolve home directory, logging to stderr only: %v", err)
	}

	// Build and return logger
	return config.Build()
}

// resolvePluginsDirs decides where the kernel looks for plugins, returning
// the writable directory and the optional read-only bundled one in that
// precedence order.
//
// A packaged VibeCare ships its first-party plugins inside the application
// bundle, at VibeCare.app/Contents/Resources/plugins/, beside this binary at
// .../Resources/vibecare-server. Finding them from the binary's OWN path is
// what keeps the install location out of the LaunchAgent plist: the cask is
// free to move the .app, and nothing has to agree on an absolute path. The
// bundle is read-only — writing into it would break the app's code
// signature — so ~/.vibecare/plugins-v2 stays the writable half and takes
// precedence, which is what lets an updated plugin supersede a shipped one.
//
// An explicit --plugins-dir suppresses the bundled directory entirely. `just
// run` points it at this repo's plugins/, and a developer debugging one tree
// should get that tree alone, not that tree merged with whatever a packaged
// build left beside the binary.
//
// exeDir may be empty when os.Executable fails; that just means no bundled
// directory. Refusing to start because an OPTIONAL directory could not be
// located would be a worse failure than running without it.
func resolvePluginsDirs(flagValue, exeDir, home string) (user, bundled string) {
	if flagValue != "" {
		return flagValue, ""
	}
	user = filepath.Join(home, ".vibecare", "plugins-v2")
	if exeDir == "" {
		return user, ""
	}
	// Must be a directory: a stray file named `plugins` beside the binary
	// would otherwise be handed to discovery as a scan root and fail startup.
	candidate := filepath.Join(exeDir, "plugins")
	if fi, err := os.Stat(candidate); err == nil && fi.IsDir() {
		return user, candidate
	}
	return user, ""
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
		pluginsDir    = flag.String("plugins-dir", "", "Directory scanned for <id>/manifest.yaml plugins; suppresses the bundled directory (default ~/.vibecare/plugins-v2 plus any plugins/ beside this binary)")
	)
	flag.Parse()

	// Setup logger
	logger, err := initLogger(*logLevel, *logFormat)
	if err != nil {
		log.Fatalf("Failed to initialize logger: %v", err)
	}
	defer logger.Sync()
	logger.Info("VibeCare backend version", zap.String("version", version))

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

	// Determine home directory, using the same resolution as the default DB
	// path, independent of whether --db was overridden.
	homeDir, err := os.UserHomeDir()
	if err != nil {
		logger.Fatal("Failed to get home directory", zap.Error(err))
	}

	// Plugin kernel: discovers, launches, and supervises plugin subprocesses.
	// Its HTTP origin and unix socket are independent of Core's gRPC and web
	// ports — the kernel binds 127.0.0.1:0 for both. Where it looks for
	// plugins is resolvePluginsDirs' business.
	exeDir := ""
	if exe, err := os.Executable(); err == nil {
		exeDir = filepath.Dir(exe)
	}
	userPluginsDir, bundledPluginsDir := resolvePluginsDirs(*pluginsDir, exeDir, homeDir)
	kernelCfg := kernel.DefaultConfig(homeDir, userPluginsDir)
	kernelCfg.BundledPluginsDir = bundledPluginsDir
	k, err := kernel.New(kernelCfg, logger)
	if err != nil {
		logger.Warn("Failed to create plugin kernel; continuing without it", zap.Error(err))
		k = nil
	}

	// Create HTTP tracer for web server instrumentation
	httpTracer := telemetry.GetTracer("vibecare.http.server")

	// Initialize and start web server with OpenTelemetry instrumentation
	webServer := web.NewServer(*webPort, db, sched, mcpServer, iconLoader, httpTracer, logger, version)
	go func() {
		if err := webServer.Start(); err != nil {
			logger.Error("Web server failed", zap.Error(err))
		}
	}()

	// Create gRPC server interceptor chain. Order matters: panic recovery
	// first, then OTel, then custom telemetry. The tracing trio is only
	// added when tracing is enabled.
	interceptors := []grpc.UnaryServerInterceptor{}
	if *enableTracing {
		interceptors = append(interceptors,
			telemetry.PanicRecoveryInterceptor(logger), // First: catch panics
			otelgrpc.UnaryServerInterceptor(),          // Second: create spans
			telemetry.UnaryServerInterceptor(logger),   // Third: add custom attributes
		)
	}
	grpcServer := grpc.NewServer(grpc.ChainUnaryInterceptor(interceptors...))

	// Register services
	api.RegisterServices(grpcServer, db, eventHub, templateLoader, iconLoader, logger)

	// The client-facing plugin contract (roster + alerts) rides on the same
	// TCP gRPC server the client already connects to.
	if k != nil {
		k.RegisterShell(grpcServer)
	}

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

		if k != nil {
			logger.Info("Stopping plugin kernel...")
			k.Stop(ctx)
		}

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

	go func() {
		if err := grpcServer.Serve(lis); err != nil {
			logger.Fatal("Failed to serve", zap.Error(err))
		}
	}()

	// A kernel failure must not take down the server: it is logged and
	// startup continues without it.
	if k != nil {
		logger.Info("Starting plugin kernel", zap.String("dir", kernelCfg.PluginsDir))
		if err := k.Start(context.Background()); err != nil {
			logger.Warn("Failed to start plugin kernel; continuing without it", zap.Error(err))
		} else {
			logger.Info("Plugin kernel ready", zap.String("origin", k.BaseURL(context.Background())))
		}
	}

	<-shutdownComplete
}
