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
	ID                  string               `json:"id"`
	Category            string               `json:"category"`
	RoutineName         string               `json:"routine_name"`
	RoutineDescription  string               `json:"routine_description,omitempty"`
	RoutineIcon         string               `json:"routine_icon"`
	RoutineColor        string               `json:"routine_color"`
	ScheduleName        string               `json:"schedule_name"`
	ScheduleDescription string               `json:"schedule_description,omitempty"`
	RRule               string               `json:"rrule"`
	DefaultTimes        []string             `json:"default_times"`
	Actions             []templateActionItem `json:"actions,omitempty"`
}

type templateActionItem struct {
	Type       string            `json:"type"`
	Name       string            `json:"name,omitempty"`
	Parameters map[string]string `json:"parameters"`
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

	// Convert actions array
	if len(item.Actions) > 0 {
		template.Actions = make([]*pb.ScheduleTemplate_TemplateAction, 0, len(item.Actions))
		for _, action := range item.Actions {
			pbAction := &pb.ScheduleTemplate_TemplateAction{
				Type:       parseActionType(action.Type),
				Name:       action.Name,
				Parameters: action.Parameters,
			}
			template.Actions = append(template.Actions, pbAction)
		}
	}

	return template
}

// parseActionType converts string action type to enum
func parseActionType(actionType string) pb.ActionType {
	switch actionType {
	case "notification":
		return pb.ActionType_ACTION_TYPE_NOTIFICATION
	case "open_link":
		return pb.ActionType_ACTION_TYPE_OPEN_LINK
	case "send_email":
		return pb.ActionType_ACTION_TYPE_SEND_EMAIL
	case "run_script":
		return pb.ActionType_ACTION_TYPE_RUN_SCRIPT
	case "play_sound":
		return pb.ActionType_ACTION_TYPE_PLAY_SOUND
	case "system_command":
		return pb.ActionType_ACTION_TYPE_SYSTEM_COMMAND
	case "api_call":
		return pb.ActionType_ACTION_TYPE_API_CALL
	case "log_entry":
		return pb.ActionType_ACTION_TYPE_LOG_ENTRY
	default:
		return pb.ActionType_ACTION_TYPE_UNSPECIFIED
	}
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
