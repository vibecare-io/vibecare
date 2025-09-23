package api

import (
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

	db     *storage.DB
	logger *zap.Logger
}

// NewServer creates a new API server
func NewServer(db *storage.DB, logger *zap.Logger) *Server {
	return &Server{
		db:     db,
		logger: logger,
	}
}

// RegisterServices registers all gRPC services
func RegisterServices(grpcServer *grpc.Server, db *storage.DB, logger *zap.Logger) {
	server := NewServer(db, logger)

	pb.RegisterProfileServiceServer(grpcServer, server)
	pb.RegisterRoutineServiceServer(grpcServer, server)
	pb.RegisterScheduleServiceServer(grpcServer, server)
	pb.RegisterActionServiceServer(grpcServer, server)
}