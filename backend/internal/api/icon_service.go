package api

import (
	"context"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// IconGetter interface for icon retrieval
type IconGetter interface {
	GetIcons() []*pb.SVGIcon
	GetCategories() []*pb.IconCategory
	GetIconsByCategory(category string) []*pb.SVGIcon
	SearchIcons(query string) []*pb.SVGIcon
}

// IconService implements the IconService gRPC service
type IconService struct {
	pb.UnimplementedIconServiceServer
	iconGetter IconGetter
	logger     *zap.Logger
}

// NewIconService creates a new icon service
func NewIconService(iconGetter IconGetter, logger *zap.Logger) *IconService {
	return &IconService{
		iconGetter: iconGetter,
		logger:     logger,
	}
}

// ListIcons returns SVG icons, optionally filtered by category or search query
func (s *IconService) ListIcons(
	ctx context.Context,
	req *pb.ListIconsRequest,
) (*pb.ListIconsResponse, error) {
	s.logger.Info("ListIcons called",
		zap.Any("category", req.GetCategory()),
		zap.String("search_query", req.GetSearchQuery()))

	var icons []*pb.SVGIcon

	// Apply filters
	if searchQuery := req.GetSearchQuery(); searchQuery != "" {
		// Search takes precedence
		icons = s.iconGetter.SearchIcons(searchQuery)
	} else if category := req.GetCategory(); category != "" {
		// Filter by category
		icons = s.iconGetter.GetIconsByCategory(category)
	} else {
		// Return all icons
		icons = s.iconGetter.GetIcons()
	}

	if icons == nil {
		return nil, status.Error(codes.Internal, "icons not loaded")
	}

	// Always return categories for UI organization
	categories := s.iconGetter.GetCategories()
	if categories == nil {
		return nil, status.Error(codes.Internal, "categories not loaded")
	}

	s.logger.Info("Returning icons",
		zap.Int("icon_count", len(icons)),
		zap.Int("category_count", len(categories)))

	return &pb.ListIconsResponse{
		Icons:      icons,
		Categories: categories,
	}, nil
}
