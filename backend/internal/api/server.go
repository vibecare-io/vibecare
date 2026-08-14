package api

import (
	"github.com/vibecare-io/vibecare/backend/internal/scheduler"
	"github.com/vibecare-io/vibecare/backend/internal/storage"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/grpc"
)

// Server implements all gRPC services
type Server struct {
	pb.UnimplementedProfileServiceServer
	pb.UnimplementedRoutineServiceServer
	pb.UnimplementedScheduleServiceServer
	pb.UnimplementedActionServiceServer
	pb.UnimplementedEventServiceServer

	db       *storage.DB
	eventHub *scheduler.EventHub
	logger   *zap.Logger
}

// NewServer creates a new API server
func NewServer(db *storage.DB, eventHub *scheduler.EventHub, logger *zap.Logger) *Server {
	return &Server{
		db:       db,
		eventHub: eventHub,
		logger:   logger,
	}
}

// RegisterServices registers all gRPC services
func RegisterServices(grpcServer *grpc.Server, db *storage.DB, eventHub *scheduler.EventHub, templateLoader *storage.TemplateLoader, iconLoader *storage.IconLoader, logger *zap.Logger) {
	server := NewServer(db, eventHub, logger)

	pb.RegisterProfileServiceServer(grpcServer, server)
	pb.RegisterRoutineServiceServer(grpcServer, server)
	pb.RegisterScheduleServiceServer(grpcServer, server)
	pb.RegisterActionServiceServer(grpcServer, server)
	pb.RegisterEventServiceServer(grpcServer, server)

	// Register template service
	templateService := NewScheduleTemplateService(templateLoader, logger)
	pb.RegisterScheduleTemplateServiceServer(grpcServer, templateService)

	// Register icon service
	iconService := NewIconService(iconLoader, logger)
	pb.RegisterIconServiceServer(grpcServer, iconService)
}
