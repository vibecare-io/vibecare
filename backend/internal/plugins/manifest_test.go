package plugins

import (
	"os"
	"path/filepath"
	"testing"
)

const sampleManifestYAML = `
id: com.vibecare.todos
name: Todos
version: 0.1.0
icon: checklist
exec: ./todos
provides:
  actions: [add_todo, complete_todo, delete_todo]
  events: []
  data: [todos]
ui:
  kind: shell-native
  entry: main
`

// TestParseManifestYAML verifies that a sample manifest.yaml string parses
// into a FileManifest with the expected id/name/exec/actions/ui fields.
func TestParseManifestYAML(t *testing.T) {
	m, err := parseManifestYAML([]byte(sampleManifestYAML))
	if err != nil {
		t.Fatalf("parseManifestYAML failed: %v", err)
	}

	if m.ID != "com.vibecare.todos" {
		t.Errorf("ID = %q, want %q", m.ID, "com.vibecare.todos")
	}
	if m.Name != "Todos" {
		t.Errorf("Name = %q, want %q", m.Name, "Todos")
	}
	if m.Version != "0.1.0" {
		t.Errorf("Version = %q, want %q", m.Version, "0.1.0")
	}
	if m.Icon != "checklist" {
		t.Errorf("Icon = %q, want %q", m.Icon, "checklist")
	}
	if m.Exec != "./todos" {
		t.Errorf("Exec = %q, want %q", m.Exec, "./todos")
	}

	wantActions := []string{"add_todo", "complete_todo", "delete_todo"}
	if len(m.Provides.Actions) != len(wantActions) {
		t.Fatalf("Provides.Actions = %v, want %v", m.Provides.Actions, wantActions)
	}
	for i, a := range wantActions {
		if m.Provides.Actions[i] != a {
			t.Errorf("Provides.Actions[%d] = %q, want %q", i, m.Provides.Actions[i], a)
		}
	}
	if len(m.Provides.Events) != 0 {
		t.Errorf("Provides.Events = %v, want empty", m.Provides.Events)
	}
	if len(m.Provides.Data) != 1 || m.Provides.Data[0] != "todos" {
		t.Errorf("Provides.Data = %v, want [todos]", m.Provides.Data)
	}

	if m.UI.Kind != "shell-native" {
		t.Errorf("UI.Kind = %q, want %q", m.UI.Kind, "shell-native")
	}
	if m.UI.Entry != "main" {
		t.Errorf("UI.Entry = %q, want %q", m.UI.Entry, "main")
	}
}

// TestLoadManifestFile verifies loadManifestFile reads and parses a
// manifest.yaml from disk.
func TestLoadManifestFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "manifest.yaml")
	if err := os.WriteFile(path, []byte(sampleManifestYAML), 0o644); err != nil {
		t.Fatalf("os.WriteFile failed: %v", err)
	}

	m, err := loadManifestFile(path)
	if err != nil {
		t.Fatalf("loadManifestFile failed: %v", err)
	}
	if m.ID != "com.vibecare.todos" {
		t.Errorf("ID = %q, want %q", m.ID, "com.vibecare.todos")
	}
}

// TestParseManifestYAMLInvalid verifies malformed yaml returns an error
// rather than a zero-value manifest, so the registry can skip bad plugins.
func TestParseManifestYAMLInvalid(t *testing.T) {
	_, err := parseManifestYAML([]byte("not: [valid: yaml"))
	if err == nil {
		t.Fatal("expected error for invalid yaml, got nil")
	}
}
