package api

import (
	"context"

	"github.com/vibecare-io/vibecare/backend/internal/validation"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// CreateProfile creates a new profile
func (s *Server) CreateProfile(ctx context.Context, req *pb.CreateProfileRequest) (*pb.CreateProfileResponse, error) {
	s.logger.Info("Creating profile", zap.String("name", req.Name))

	// Validate inputs at API layer
	if err := validation.ValidateName("name", req.Name); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid name: %v", err)
	}

	if err := validation.ValidateEmail(req.Email); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid email: %v", err)
	}

	if err := validation.ValidateJSONMap("preferences", req.Preferences); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid preferences: %v", err)
	}

	// Check if profile with email already exists
	existing, err := s.db.GetProfileByEmail(req.Email)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to check existing profile: %v", err)
	}
	if existing != nil {
		return nil, status.Errorf(codes.AlreadyExists, "profile with email %s already exists", req.Email)
	}

	// Create the profile
	profile, err := s.db.CreateProfile(req.Name, req.Email, req.Preferences)
	if err != nil {
		s.logger.Error("Failed to create profile", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to create profile: %v", err)
	}

	return &pb.CreateProfileResponse{
		Profile: &pb.Profile{
			Id:          profile.ID,
			Name:        profile.Name,
			Email:       profile.Email,
			Preferences: req.Preferences,
			CreatedAt:   timestamppb.New(profile.CreatedAt),
			UpdatedAt:   timestamppb.New(profile.UpdatedAt),
		},
	}, nil
}

// GetProfile retrieves a profile by ID
func (s *Server) GetProfile(ctx context.Context, req *pb.GetProfileRequest) (*pb.Profile, error) {
	s.logger.Info("Getting profile", zap.String("id", req.Id))

	profile, err := s.db.GetProfile(req.Id)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get profile: %v", err)
	}
	if profile == nil {
		return nil, status.Errorf(codes.NotFound, "profile not found")
	}

	return &pb.Profile{
		Id:          profile.ID,
		Name:        profile.Name,
		Email:       profile.Email,
		Preferences: profile.Preferences,
		CreatedAt:   timestamppb.New(profile.CreatedAt),
		UpdatedAt:   timestamppb.New(profile.UpdatedAt),
	}, nil
}

// UpdateProfile updates a profile
func (s *Server) UpdateProfile(ctx context.Context, req *pb.UpdateProfileRequest) (*pb.Profile, error) {
	s.logger.Info("Updating profile", zap.String("id", req.Id))

	// Get existing profile
	profile, err := s.db.GetProfile(req.Id)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get profile: %v", err)
	}
	if profile == nil {
		return nil, status.Errorf(codes.NotFound, "profile not found")
	}

	// Update fields
	if req.Name != "" {
		profile.Name = req.Name
	}
	if req.Email != "" {
		profile.Email = req.Email
	}
	if len(req.Preferences) > 0 {
		profile.Preferences = req.Preferences
	}

	// Validate inputs at API layer
	if err := validation.ValidateName("name", profile.Name); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid name: %v", err)
	}

	if err := validation.ValidateEmail(profile.Email); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid email: %v", err)
	}

	if err := validation.ValidateJSONMap("preferences", profile.Preferences); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid preferences: %v", err)
	}

	// Save updates to database
	updatedProfile, err := s.db.UpdateProfile(req.Id, profile.Name, profile.Email, profile.Preferences)
	if err != nil {
		s.logger.Error("Failed to update profile", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to update profile: %v", err)
	}

	return &pb.Profile{
		Id:          updatedProfile.ID,
		Name:        updatedProfile.Name,
		Email:       updatedProfile.Email,
		Preferences: updatedProfile.Preferences,
		CreatedAt:   timestamppb.New(updatedProfile.CreatedAt),
		UpdatedAt:   timestamppb.New(updatedProfile.UpdatedAt),
	}, nil
}

// DeleteProfile deletes a profile
func (s *Server) DeleteProfile(ctx context.Context, req *pb.DeleteProfileRequest) (*emptypb.Empty, error) {
	s.logger.Info("Deleting profile", zap.String("id", req.Id))

	// Delete profile from database
	err := s.db.DeleteProfile(req.Id)
	if err != nil {
		s.logger.Error("Failed to delete profile", zap.Error(err))
		return nil, status.Errorf(codes.Internal, "failed to delete profile: %v", err)
	}

	return &emptypb.Empty{}, nil
}

// ListProfiles lists all profiles
func (s *Server) ListProfiles(ctx context.Context, req *pb.ListProfilesRequest) (*pb.ListProfilesResponse, error) {
	s.logger.Info("Listing profiles")

	profiles, err := s.db.ListProfiles()
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to list profiles: %v", err)
	}

	pbProfiles := make([]*pb.Profile, 0, len(profiles))
	for _, p := range profiles {
		pbProfiles = append(pbProfiles, &pb.Profile{
			Id:          p.ID,
			Name:        p.Name,
			Email:       p.Email,
			Preferences: p.Preferences,
			CreatedAt:   timestamppb.New(p.CreatedAt),
			UpdatedAt:   timestamppb.New(p.UpdatedAt),
		})
	}

	return &pb.ListProfilesResponse{
		Profiles:   pbProfiles,
		TotalCount: int32(len(profiles)),
	}, nil
}

// RegisterDevice registers a new device for a profile
func (s *Server) RegisterDevice(ctx context.Context, req *pb.RegisterDeviceRequest) (*pb.Device, error) {
	s.logger.Info("Registering device",
		zap.String("profile_id", req.ProfileId),
		zap.String("device_name", req.DeviceName))

	// Verify profile exists
	profile, err := s.db.GetProfile(req.ProfileId)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to get profile: %v", err)
	}
	if profile == nil {
		return nil, status.Errorf(codes.NotFound, "profile not found")
	}

	// Create device (simplified - implement in storage)
	device := &pb.Device{
		Id:        "device-" + req.DeviceName, // Generate proper ID
		Name:      req.DeviceName,
		Type:      req.DeviceType,
		PushToken: req.PushToken,
		Active:    true,
	}

	return device, nil
}

// UnregisterDevice unregisters a device
func (s *Server) UnregisterDevice(ctx context.Context, req *pb.UnregisterDeviceRequest) (*emptypb.Empty, error) {
	s.logger.Info("Unregistering device",
		zap.String("profile_id", req.ProfileId),
		zap.String("device_id", req.DeviceId))

	// Implement device unregistration
	return &emptypb.Empty{}, nil
}

// ListDevices lists all devices for a profile
func (s *Server) ListDevices(ctx context.Context, req *pb.ListDevicesRequest) (*pb.ListDevicesResponse, error) {
	s.logger.Info("Listing devices", zap.String("profile_id", req.ProfileId))

	// Implement device listing
	return &pb.ListDevicesResponse{
		Devices: []*pb.Device{},
	}, nil
}
