package api

import (
	"context"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// TemplateGetter interface for template retrieval
type TemplateGetter interface {
	GetTemplates() []*pb.ScheduleTemplate
	GetTemplatesByCategory(category pb.TemplateCategory) []*pb.ScheduleTemplate
}

// ScheduleTemplateService implements the ScheduleTemplateService gRPC service
type ScheduleTemplateService struct {
	pb.UnimplementedScheduleTemplateServiceServer
	templateGetter TemplateGetter
	logger         *zap.Logger
}

// NewScheduleTemplateService creates a new schedule template service
func NewScheduleTemplateService(templateGetter TemplateGetter, logger *zap.Logger) *ScheduleTemplateService {
	return &ScheduleTemplateService{
		templateGetter: templateGetter,
		logger:         logger,
	}
}

// ListScheduleTemplates returns schedule templates, optionally filtered by category
func (s *ScheduleTemplateService) ListScheduleTemplates(
	ctx context.Context,
	req *pb.ListScheduleTemplatesRequest,
) (*pb.ListScheduleTemplatesResponse, error) {
	s.logger.Info("ListScheduleTemplates called",
		zap.Any("category", req.GetCategory()))

	var templates []*pb.ScheduleTemplate

	// If category filter is specified, use it
	if req.Category != nil && *req.Category != pb.TemplateCategory_TEMPLATE_CATEGORY_UNSPECIFIED {
		templates = s.templateGetter.GetTemplatesByCategory(*req.Category)
	} else {
		templates = s.templateGetter.GetTemplates()
	}

	if templates == nil {
		return nil, status.Error(codes.Internal, "templates not loaded")
	}

	s.logger.Info("Returning templates",
		zap.Int("count", len(templates)))

	return &pb.ListScheduleTemplatesResponse{
		Templates: templates,
	}, nil
}
