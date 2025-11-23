package storage

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"sync"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
)

//go:embed data/schedule_templates.json
var embeddedTemplates []byte

// TemplateLoader loads and caches schedule templates from JSON configuration
type TemplateLoader struct {
	templates []*pb.ScheduleTemplate
	mu        sync.RWMutex
	logger    *zap.Logger
}

// NewTemplateLoader creates a new template loader
func NewTemplateLoader(logger *zap.Logger) *TemplateLoader {
	return &TemplateLoader{
		logger: logger,
	}
}

// LoadTemplates loads templates from embedded JSON file
func (tl *TemplateLoader) LoadTemplates(_ string) error {
	tl.mu.Lock()
	defer tl.mu.Unlock()

	// If already loaded, return
	if tl.templates != nil {
		return nil
	}

	tl.logger.Info("Loading schedule templates from embedded data")

	var config templateConfig
	if err := json.Unmarshal(embeddedTemplates, &config); err != nil {
		return fmt.Errorf("failed to parse template JSON: %w", err)
	}

	// Convert to protobuf messages
	tl.templates = make([]*pb.ScheduleTemplate, 0, len(config.Templates))
	for _, t := range config.Templates {
		pbTemplate := convertToProto(t)
		tl.templates = append(tl.templates, pbTemplate)
	}

	tl.logger.Info("Loaded schedule templates",
		zap.Int("count", len(tl.templates)),
		zap.String("version", config.Version))

	return nil
}

// GetTemplates returns all templates
func (tl *TemplateLoader) GetTemplates() []*pb.ScheduleTemplate {
	tl.mu.RLock()
	defer tl.mu.RUnlock()
	return tl.templates
}

// GetTemplatesByCategory returns templates filtered by category
func (tl *TemplateLoader) GetTemplatesByCategory(category pb.TemplateCategory) []*pb.ScheduleTemplate {
	tl.mu.RLock()
	defer tl.mu.RUnlock()

	filtered := make([]*pb.ScheduleTemplate, 0)
	for _, t := range tl.templates {
		if t.Category == category {
			filtered = append(filtered, t)
		}
	}
	return filtered
}

// templateConfig matches the JSON structure
type templateConfig struct {
	Version   string             `json:"version"`
	Templates []templateConfigItem `json:"templates"`
}

type templateConfigItem struct {
	ID                  string                     `json:"id"`
	Category            string                     `json:"category"`
	RoutineName         string                     `json:"routine_name"`
	RoutineDescription  string                     `json:"routine_description,omitempty"`
	RoutineIcon         string                     `json:"routine_icon"`
	RoutineColor        string                     `json:"routine_color"`
	ScheduleName        string                     `json:"schedule_name"`
	ScheduleDescription string                     `json:"schedule_description,omitempty"`
	RRule               string                     `json:"rrule"`
	DefaultTimes        []string                   `json:"default_times"`
	Notification        *notificationConfigItem    `json:"notification,omitempty"`
}

type notificationConfigItem struct {
	Title       string `json:"title"`
	Body        string `json:"body"`
	IconID      string `json:"icon_id,omitempty"`
	Position    string `json:"position,omitempty"`
	AutoDismiss int32  `json:"auto_dismiss,omitempty"`
	Width       int32  `json:"width,omitempty"`
	Height      int32  `json:"height,omitempty"`
}

// convertToProto converts JSON config to protobuf message
func convertToProto(item templateConfigItem) *pb.ScheduleTemplate {
	template := &pb.ScheduleTemplate{
		Id:                  item.ID,
		Category:            parseCategory(item.Category),
		RoutineName:         item.RoutineName,
		RoutineDescription:  item.RoutineDescription,
		RoutineIcon:         item.RoutineIcon,
		RoutineColor:        item.RoutineColor,
		ScheduleName:        item.ScheduleName,
		ScheduleDescription: item.ScheduleDescription,
		Rrule:               item.RRule,
		DefaultTimes:        item.DefaultTimes,
	}

	// Convert notification config if present
	if item.Notification != nil {
		template.Notification = &pb.ScheduleTemplate_NotificationConfig{
			Title:       item.Notification.Title,
			Body:        item.Notification.Body,
			IconId:      item.Notification.IconID,
			Position:    item.Notification.Position,
			AutoDismiss: item.Notification.AutoDismiss,
			Width:       item.Notification.Width,
			Height:      item.Notification.Height,
		}
	}

	return template
}

// parseCategory converts string category to enum
func parseCategory(cat string) pb.TemplateCategory {
	switch cat {
	case "daily":
		return pb.TemplateCategory_TEMPLATE_CATEGORY_DAILY
	case "weekly":
		return pb.TemplateCategory_TEMPLATE_CATEGORY_WEEKLY
	case "monthly_yearly":
		return pb.TemplateCategory_TEMPLATE_CATEGORY_MONTHLY_YEARLY
	default:
		return pb.TemplateCategory_TEMPLATE_CATEGORY_UNSPECIFIED
	}
}
