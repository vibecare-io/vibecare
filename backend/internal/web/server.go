package web

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/vibecare-io/vibecare/backend/internal/mcp"
	"github.com/vibecare-io/vibecare/backend/internal/scheduler"
	"github.com/vibecare-io/vibecare/backend/internal/storage"
	"go.uber.org/zap"
)

// Server represents the HTTP server for the web dashboard
type Server struct {
	httpServer *http.Server
	logger     *zap.Logger
}

// NewServer creates a new web server
func NewServer(port int, db *storage.DB, sched *scheduler.Scheduler, mcpServer *mcp.Server, logger *zap.Logger) *Server {
	handler := NewHandler(db, sched, mcpServer, logger)

	mux := http.NewServeMux()
	mux.HandleFunc("/status", handler.DashboardHandler)
	mux.HandleFunc("/api/scheduler/status", handler.StatusHandler)
	mux.HandleFunc("/api/mcp/tools", handler.MCPToolsHandler)

	// Redirect root to /status
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.Redirect(w, r, "/status", http.StatusFound)
			return
		}
		http.NotFound(w, r)
	})

	return &Server{
		httpServer: &http.Server{
			Addr:         fmt.Sprintf(":%d", port),
			Handler:      mux,
			ReadTimeout:  15 * time.Second,
			WriteTimeout: 15 * time.Second,
			IdleTimeout:  60 * time.Second,
		},
		logger: logger,
	}
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
