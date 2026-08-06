package plugins

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// FileManifest is the on-disk manifest.yaml shape that Core reads to
// discover and launch a plugin. It is distinct from pb.Manifest (the proto
// message a running plugin returns from GetManifest over gRPC) — the name
// FileManifest was chosen to keep the two unambiguous even though pb.Manifest
// is always package-qualified as pb.Manifest in this codebase.
type FileManifest struct {
	ID       string           `yaml:"id"`
	Name     string           `yaml:"name"`
	Version  string           `yaml:"version"`
	Icon     string           `yaml:"icon"`
	Exec     string           `yaml:"exec"`
	Provides ManifestProvides `yaml:"provides"`
	UI       ManifestUI       `yaml:"ui"`
}

// ManifestProvides lists the capabilities a plugin declares it provides.
type ManifestProvides struct {
	Actions []string `yaml:"actions"`
	Events  []string `yaml:"events"`
	Data    []string `yaml:"data"`
}

// ManifestUI describes how Core should render the plugin's UI.
type ManifestUI struct {
	Kind  string `yaml:"kind"`
	Entry string `yaml:"entry"`
}

// parseManifestYAML parses raw manifest.yaml bytes into a FileManifest.
func parseManifestYAML(data []byte) (FileManifest, error) {
	var m FileManifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		return FileManifest{}, fmt.Errorf("parse manifest yaml: %w", err)
	}
	return m, nil
}

// loadManifestFile reads and parses a manifest.yaml from disk.
func loadManifestFile(path string) (FileManifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return FileManifest{}, fmt.Errorf("read manifest file %s: %w", path, err)
	}
	return parseManifestYAML(data)
}
