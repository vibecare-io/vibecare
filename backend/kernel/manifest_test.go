package kernel

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writePlugin creates root/<dir>/manifest.yaml with the given body and
// returns root, so tests can build a plugins tree without fixtures.
func writePlugin(t *testing.T, root, dir, body string) {
	t.Helper()
	d := filepath.Join(root, dir)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, "manifest.yaml"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

const goodManifest = `
id: widget
name: Widget
icon: checklist
exec: ./widget
subscribes: [activity.afk.v1]
publishes: [widget.created.v1]
ui: webview
`

func TestLoadManifestParsesAllFields(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "widget", goodManifest)

	m, err := LoadManifest(filepath.Join(root, "widget", "manifest.yaml"))
	if err != nil {
		t.Fatalf("LoadManifest: %v", err)
	}
	if m.ID != "widget" || m.Name != "Widget" || m.Icon != "checklist" || m.Exec != "./widget" {
		t.Errorf("scalar fields wrong: %+v", m)
	}
	if len(m.Subscribes) != 1 || m.Subscribes[0] != "activity.afk.v1" {
		t.Errorf("subscribes = %v", m.Subscribes)
	}
	if len(m.Publishes) != 1 || m.Publishes[0] != "widget.created.v1" {
		t.Errorf("publishes = %v", m.Publishes)
	}
	if m.UI != "webview" {
		t.Errorf("ui = %q", m.UI)
	}
	if m.Dir != filepath.Join(root, "widget") {
		t.Errorf("Dir = %q, want the manifest's own directory", m.Dir)
	}
}

// A plugin id is the routing key, the data-dir name, and the topic
// namespace prefix, so it is validated hard rather than sanitized.
func TestLoadManifestRejectsBadIDs(t *testing.T) {
	for _, id := range []string{"", "_core", "Widget", "9lives", "wid_get", "widget!", "to/do"} {
		t.Run(id, func(t *testing.T) {
			root := t.TempDir()
			writePlugin(t, root, "p", "id: "+id+"\nname: X\nexec: ./x\n")
			if _, err := LoadManifest(filepath.Join(root, "p", "manifest.yaml")); err == nil {
				t.Fatalf("expected error for id %q", id)
			}
		})
	}
}

func TestLoadManifestRequiresExec(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "widget", "id: widget\nname: Widget\n")
	_, err := LoadManifest(filepath.Join(root, "widget", "manifest.yaml"))
	if err == nil || !strings.Contains(err.Error(), "exec") {
		t.Fatalf("err = %v, want an error naming the missing exec field", err)
	}
}

// "ui: none" is a headless plugin — legal, and it gets no tab in clients.
// An unrecognized value is a typo, not a feature, so it fails loudly.
func TestLoadManifestUIValues(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "a", "id: a\nname: A\nexec: ./a\nui: none\n")
	if m, err := LoadManifest(filepath.Join(root, "a", "manifest.yaml")); err != nil || m.UI != "none" {
		t.Fatalf("ui: none -> %+v, %v", m, err)
	}
	writePlugin(t, root, "b", "id: b\nname: B\nexec: ./b\nui: native\n")
	if _, err := LoadManifest(filepath.Join(root, "b", "manifest.yaml")); err == nil {
		t.Fatal("expected error for unknown ui kind")
	}
}

// Omitting ui defaults to webview: the common case shouldn't need a line.
func TestLoadManifestUIDefaultsToWebview(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "a", "id: a\nname: A\nexec: ./a\n")
	m, err := LoadManifest(filepath.Join(root, "a", "manifest.yaml"))
	if err != nil || m.UI != "webview" {
		t.Fatalf("got %+v, %v", m, err)
	}
}

// Name is what the sidebar shows; falling back to the id beats a blank row.
func TestLoadManifestNameDefaultsToID(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "a", "id: a\nexec: ./a\n")
	m, err := LoadManifest(filepath.Join(root, "a", "manifest.yaml"))
	if err != nil || m.Name != "a" {
		t.Fatalf("got %+v, %v", m, err)
	}
}

func TestDiscoverFindsAllPluginsSorted(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "zeta", "id: zeta\nname: Z\nexec: ./z\n")
	writePlugin(t, root, "alpha", "id: alpha\nname: A\nexec: ./a\n")

	got, err := Discover(root)
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if len(got) != 2 || got[0].ID != "alpha" || got[1].ID != "zeta" {
		t.Fatalf("got %+v, want [alpha zeta]", got)
	}
}

// A directory with no manifest is not a plugin — it's a build artifact
// directory or a stray checkout. Skipping it keeps `plugins/` droppable.
func TestDiscoverSkipsDirsWithoutManifest(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "widget", goodManifest)
	if err := os.MkdirAll(filepath.Join(root, "notaplugin"), 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := Discover(root)
	if err != nil || len(got) != 1 || got[0].ID != "widget" {
		t.Fatalf("got %+v, %v", got, err)
	}
}

// Two plugins claiming the same id would collide on routing, data dir, and
// topic namespace. The error must name BOTH paths so it's actionable.
func TestDiscoverRejectsDuplicateIDs(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "one", "id: dup\nname: One\nexec: ./x\n")
	writePlugin(t, root, "two", "id: dup\nname: Two\nexec: ./x\n")

	_, err := Discover(root)
	if err == nil {
		t.Fatal("expected duplicate-id error")
	}
	if !strings.Contains(err.Error(), filepath.Join(root, "one")) ||
		!strings.Contains(err.Error(), filepath.Join(root, "two")) {
		t.Fatalf("error must name both dirs, got: %v", err)
	}
}

// A missing plugins dir is normal on a fresh install, not an error.
func TestDiscoverMissingRootReturnsEmpty(t *testing.T) {
	got, err := Discover(filepath.Join(t.TempDir(), "nope"))
	if err != nil || len(got) != 0 {
		t.Fatalf("got %+v, %v", got, err)
	}
}
