package config

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

// Config represents the VibeCare configuration
type Config struct {
	MCP MCPConfig `yaml:"mcp"`
}

// MCPConfig holds MCP server configuration
type MCPConfig struct {
	ProfileID string `yaml:"profile_id"`
	GRPCAddr  string `yaml:"grpc_addr"`
	Port      int    `yaml:"port"`
}

// DefaultConfigPath returns the default configuration file path
func DefaultConfigPath() (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("failed to get home directory: %w", err)
	}
	return filepath.Join(homeDir, ".vibecare", "config.yaml"), nil
}

// LoadConfig loads configuration from the specified path
// Returns an empty config if the file doesn't exist
func LoadConfig(path string) (*Config, error) {
	// Check if file exists
	if _, err := os.Stat(path); os.IsNotExist(err) {
		// Return empty config with defaults
		return &Config{
			MCP: MCPConfig{
				GRPCAddr: "localhost:50051",
				Port:     8081,
			},
		}, nil
	}

	// Read file
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	// Parse YAML
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config file: %w", err)
	}

	// Set defaults for missing values
	if cfg.MCP.GRPCAddr == "" {
		cfg.MCP.GRPCAddr = "localhost:50051"
	}
	if cfg.MCP.Port == 0 {
		cfg.MCP.Port = 8081
	}

	return &cfg, nil
}

// SaveConfig saves configuration to the specified path
func SaveConfig(path string, cfg *Config) error {
	// Ensure directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create config directory: %w", err)
	}

	// Marshal to YAML
	data, err := yaml.Marshal(cfg)
	if err != nil {
		return fmt.Errorf("failed to marshal config: %w", err)
	}

	// Write file
	if err := os.WriteFile(path, data, 0644); err != nil {
		return fmt.Errorf("failed to write config file: %w", err)
	}

	return nil
}

// LoadOrDefault loads config from default path or returns default config
func LoadOrDefault() (*Config, error) {
	configPath, err := DefaultConfigPath()
	if err != nil {
		return nil, err
	}
	return LoadConfig(configPath)
}
