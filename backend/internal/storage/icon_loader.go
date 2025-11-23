package storage

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"strings"
	"sync"

	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
)

//go:embed data/icons/*
var embeddedIcons embed.FS

// IconLoader loads and caches SVG icons from catalog
type IconLoader struct {
	icons      []*pb.SVGIcon
	categories []*pb.IconCategory
	mu         sync.RWMutex
	logger     *zap.Logger
}

// NewIconLoader creates a new icon loader
func NewIconLoader(logger *zap.Logger) *IconLoader {
	return &IconLoader{
		logger: logger,
	}
}

// LoadIcons loads icons from embedded catalog JSON file
func (il *IconLoader) LoadIcons(_ string) error {
	il.mu.Lock()
	defer il.mu.Unlock()

	// If already loaded, return
	if il.icons != nil {
		return nil
	}

	il.logger.Info("Loading SVG icon catalog from embedded data")

	data, err := embeddedIcons.ReadFile("data/icons/catalog.json")
	if err != nil {
		return fmt.Errorf("failed to read embedded catalog file: %w", err)
	}

	var catalog iconCatalog
	if err := json.Unmarshal(data, &catalog); err != nil {
		return fmt.Errorf("failed to parse catalog JSON: %w", err)
	}

	// Convert categories
	il.categories = make([]*pb.IconCategory, 0, len(catalog.Categories))
	for _, cat := range catalog.Categories {
		il.categories = append(il.categories, &pb.IconCategory{
			Id:    cat.ID,
			Name:  cat.Name,
			Order: cat.Order,
		})
	}

	// Convert icons
	il.icons = make([]*pb.SVGIcon, 0, len(catalog.Icons))
	for _, icon := range catalog.Icons {
		il.icons = append(il.icons, &pb.SVGIcon{
			Id:       icon.ID,
			Name:     icon.Name,
			Category: icon.Category,
			Filename: icon.Filename,
			Keywords: icon.Keywords,
		})
	}

	il.logger.Info("Loaded SVG icons",
		zap.Int("icon_count", len(il.icons)),
		zap.Int("category_count", len(il.categories)),
		zap.String("version", catalog.Version))

	return nil
}

// GetIcons returns all icons
func (il *IconLoader) GetIcons() []*pb.SVGIcon {
	il.mu.RLock()
	defer il.mu.RUnlock()
	return il.icons
}

// GetCategories returns all categories
func (il *IconLoader) GetCategories() []*pb.IconCategory {
	il.mu.RLock()
	defer il.mu.RUnlock()
	return il.categories
}

// GetIconsByCategory returns icons filtered by category
func (il *IconLoader) GetIconsByCategory(category string) []*pb.SVGIcon {
	il.mu.RLock()
	defer il.mu.RUnlock()

	filtered := make([]*pb.SVGIcon, 0)
	for _, icon := range il.icons {
		if icon.Category == category {
			filtered = append(filtered, icon)
		}
	}
	return filtered
}

// SearchIcons returns icons matching search query in name or keywords
func (il *IconLoader) SearchIcons(query string) []*pb.SVGIcon {
	il.mu.RLock()
	defer il.mu.RUnlock()

	if query == "" {
		return il.icons
	}

	query = strings.ToLower(query)
	filtered := make([]*pb.SVGIcon, 0)

	for _, icon := range il.icons {
		// Check name
		if strings.Contains(strings.ToLower(icon.Name), query) {
			filtered = append(filtered, icon)
			continue
		}

		// Check keywords
		for _, keyword := range icon.Keywords {
			if strings.Contains(strings.ToLower(keyword), query) {
				filtered = append(filtered, icon)
				break
			}
		}
	}

	return filtered
}

// GetIconData returns the SVG data for an icon from embedded files
func (il *IconLoader) GetIconData(iconID string) ([]byte, error) {
	il.mu.RLock()
	defer il.mu.RUnlock()

	for _, icon := range il.icons {
		if icon.Id == iconID {
			data, err := embeddedIcons.ReadFile("data/icons/" + icon.Filename)
			if err != nil {
				return nil, fmt.Errorf("icon file not found: %w", err)
			}
			return data, nil
		}
	}

	return nil, fmt.Errorf("icon not found: %s", iconID)
}

// GetIconFS returns the embedded filesystem for serving icons
func (il *IconLoader) GetIconFS() fs.FS {
	// Return a sub-filesystem rooted at data/icons/
	sub, _ := fs.Sub(embeddedIcons, "data/icons")
	return sub
}

// iconCatalog matches the JSON structure
type iconCatalog struct {
	Version    string                `json:"version"`
	Categories []iconCategoryItem    `json:"categories"`
	Icons      []iconItem            `json:"icons"`
}

type iconCategoryItem struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Order int32  `json:"order"`
}

type iconItem struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Category string   `json:"category"`
	Filename string   `json:"filename"`
	Keywords []string `json:"keywords"`
}
