package web

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/pprof"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/mcp"
	"github.com/vibecare-io/vibecare/backend/internal/scheduler"
	"github.com/vibecare-io/vibecare/backend/internal/storage"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/zap"
)

// Server represents the HTTP server for the web dashboard
type Server struct {
	httpServer *http.Server
	mux        *http.ServeMux
	logger     *zap.Logger
	tracer     trace.Tracer
}

// NewServer creates a new web server with OpenTelemetry instrumentation
func NewServer(port int, db *storage.DB, sched *scheduler.Scheduler, mcpServer *mcp.Server, iconLoader IconDataGetter, tracer trace.Tracer, logger *zap.Logger, version string) *Server {
	handler := NewHandler(db, sched, mcpServer, logger)

	mux := http.NewServeMux()

	// Helper function to apply middleware stack to handlers
	// Middleware order (outer to inner): Panic Recovery → Request ID → OpenTelemetry → Logging → Handler
	applyMiddleware := func(h http.HandlerFunc, operationName string) http.Handler {
		// Start with the handler
		var handler http.Handler = h

		// Apply logging middleware (innermost, runs last)
		handler = LoggingMiddleware(logger)(handler)

		// Apply OpenTelemetry instrumentation (creates spans, propagates context)
		handler = otelhttp.NewHandler(handler, operationName)

		// Apply request ID middleware (early for logging correlation)
		handler = RequestIDMiddleware(handler)

		// Apply panic recovery (outermost, catches everything)
		handler = PanicRecoveryMiddleware(logger)(handler)

		return handler
	}

	// Version endpoint — reports the running server's build version so
	// clients can detect a stale/older backend. Intentionally independent
	// of db/sched/mcp so it works even when those are nil.
	versionHandler := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{"version": version})
	}
	mux.Handle("/version", applyMiddleware(versionHandler, "version"))

	// Register handlers with full middleware stack
	mux.Handle("/status", applyMiddleware(handler.DashboardHandler, "dashboard_page"))
	mux.Handle("/api/scheduler/status", applyMiddleware(handler.StatusHandler, "scheduler_status"))
	mux.Handle("/api/mcp/tools", applyMiddleware(handler.MCPToolsHandler, "mcp_tools"))

	// SVG icon serving endpoint
	if iconLoader != nil {
		iconHandler := func(w http.ResponseWriter, r *http.Request) {
			ServeSVGIcon(w, r, iconLoader, logger)
		}
		mux.Handle("/api/icons/", applyMiddleware(iconHandler, "serve_icon"))
	}

	// Redirect root to /status
	rootHandler := func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.Redirect(w, r, "/status", http.StatusFound)
			return
		}
		http.NotFound(w, r)
	}
	mux.Handle("/", applyMiddleware(rootHandler, "root"))

	// Register pprof handlers for profiling
	// These are NOT wrapped with middleware to avoid overhead during profiling
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
	logger.Info("pprof handlers registered at /debug/pprof/")

	return &Server{
		httpServer: &http.Server{
			Addr:         fmt.Sprintf(":%d", port),
			Handler:      mux,
			ReadTimeout:  15 * time.Second,
			WriteTimeout: 15 * time.Second,
			IdleTimeout:  60 * time.Second,
		},
		mux:    mux,
		logger: logger,
		tracer: tracer,
	}
}

// Handler exposes the server's mux directly, primarily for testing routes
// without starting a real listener.
func (s *Server) Handler() http.Handler {
	return s.mux
}

// Start starts the HTTP server
func (s *Server) Start() error {
	s.logger.Info("Starting web server", zap.String("addr", s.httpServer.Addr))
	if err := s.httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

// Shutdown gracefully shuts down the server
func (s *Server) Shutdown(ctx context.Context) error {
	s.logger.Info("Shutting down web server")
	return s.httpServer.Shutdown(ctx)
}
