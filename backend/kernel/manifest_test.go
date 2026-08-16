package kernel

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"go.uber.org/zap/zaptest/observer"
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

	got, err := Discover(root, zap.NewNop())
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
	got, err := Discover(root, zap.NewNop())
	if err != nil || len(got) != 1 || got[0].ID != "widget" {
		t.Fatalf("got %+v, %v", got, err)
	}
}

// Two plugins claiming the same id would collide on routing, data dir, and
// topic namespace. The error must name BOTH paths so it's actionable. This
// stays a hard, scan-aborting error — unlike a malformed manifest, which
// plugin is at fault is genuinely ambiguous, not just broken.
func TestDiscoverRejectsDuplicateIDs(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "one", "id: dup\nname: One\nexec: ./x\n")
	writePlugin(t, root, "two", "id: dup\nname: Two\nexec: ./x\n")

	_, err := Discover(root, zap.NewNop())
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
	got, err := Discover(filepath.Join(t.TempDir(), "nope"), zap.NewNop())
	if err != nil || len(got) != 0 {
		t.Fatalf("got %+v, %v", got, err)
	}
}

// A single malformed manifest (fails to parse, or fails validation like a
// bad id or missing exec) is that ONE plugin's problem, not the whole
// scan's. Skipping it — rather than aborting Discover entirely — is what
// stops one broken drop-in from disabling the entire plugin system. It
// must still be visible to an operator, so it's logged at warn naming the
// manifest path and the reason.
func TestDiscoverSkipsMalformedManifest(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "broken", "id: Not-Valid!\nname: Broken\nexec: ./x\n")

	core, logs := observer.New(zapcore.WarnLevel)
	log := zap.New(core)

	got, err := Discover(root, log)
	if err != nil {
		t.Fatalf("Discover: %v, want a skip rather than an aborted scan", err)
	}
	if len(got) != 0 {
		t.Fatalf("got %+v, want the malformed plugin excluded", got)
	}

	// This fixture yields zero usable plugins, so the empty-scan warning
	// fires too. Assert on the skip entry specifically rather than counting
	// every warning, so the two remain independent.
	skips := logs.FilterMessageSnippet("skipping invalid plugin manifest").All()
	if len(skips) != 1 {
		t.Fatalf("got %d skip warnings, want exactly 1: %+v", len(skips), logs.All())
	}
	fields := skips[0].ContextMap()
	path, _ := fields["path"].(string)
	if path != filepath.Join(root, "broken", manifestName) {
		t.Errorf("warn log path = %q, want the manifest's path", path)
	}
	if fields["error"] == nil {
		t.Errorf("warn log carries no reason for the skip")
	}
}

// A good plugin alongside a broken one must still be discovered: the bad
// manifest is skipped in isolation, not treated as a reason to give up on
// the rest of the directory.
func TestDiscoverSkipsBadManifestButKeepsGood(t *testing.T) {
	root := t.TempDir()
	writePlugin(t, root, "widget", goodManifest)
	writePlugin(t, root, "broken", "id: Not-Valid!\nname: Broken\nexec: ./x\n")

	got, err := Discover(root, zap.NewNop())
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if len(got) != 1 || got[0].ID != "widget" {
		t.Fatalf("got %+v, want only the good plugin", got)
	}
}

// An empty scan is nearly always a misconfigured directory rather than a
// deliberate choice, so it must be visible at warn — an INFO line in a
// debug-level log is where this question goes to die.
func TestDiscoverWarnsWhenNothingIsFound(t *testing.T) {
	core, logs := observer.New(zap.WarnLevel)
	root := t.TempDir()

	if _, err := Discover(root, zap.New(core)); err != nil {
		t.Fatalf("Discover: %v", err)
	}

	entries := logs.All()
	if len(entries) != 1 {
		t.Fatalf("got %d warn entries, want exactly 1: %+v", len(entries), entries)
	}
	if !strings.Contains(entries[0].Message, "no plugins") {
		t.Errorf("message = %q, want it to say no plugins were found", entries[0].Message)
	}
	if got := entries[0].ContextMap()["dir"]; got != root {
		t.Errorf("dir field = %v, want the scanned path %q", got, root)
	}
}

// A populated scan must stay quiet, or the warning becomes noise nobody reads.
func TestDiscoverDoesNotWarnWhenPluginsExist(t *testing.T) {
	core, logs := observer.New(zap.WarnLevel)
	root := t.TempDir()
	writePlugin(t, root, "widget", goodManifest)

	if _, err := Discover(root, zap.New(core)); err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if n := logs.Len(); n != 0 {
		t.Fatalf("got %d warn entries on a populated scan: %+v", n, logs.All())
	}
}

// --- DiscoverAll: the two-root search path -------------------------------
//
// A packaged VibeCare ships its first-party plugins read-only inside the
// application bundle while the user's own directory stays writable, so
// discovery has to span both. These tests pin the precedence rule, because
// getting it backwards means an installed update is silently ignored in
// favour of the copy that shipped months ago.

func TestDiscoverAllMergesRoots(t *testing.T) {
	user, bundled := t.TempDir(), t.TempDir()
	writePlugin(t, user, "zeta", "id: zeta\nname: Z\nexec: ./z\n")
	writePlugin(t, bundled, "alpha", "id: alpha\nname: A\nexec: ./a\n")

	got, err := DiscoverAll([]string{user, bundled}, zap.NewNop())
	if err != nil {
		t.Fatalf("DiscoverAll: %v", err)
	}
	if len(got) != 2 || got[0].ID != "alpha" || got[1].ID != "zeta" {
		t.Fatalf("got %+v, want [alpha zeta] across both roots", got)
	}
}

// The whole point of a writable directory beside a read-only bundle: an
// installed copy must be able to supersede the one that shipped. Roots are
// in precedence order, so the FIRST root claiming an id wins.
func TestDiscoverAllEarlierRootShadowsLater(t *testing.T) {
	user, bundled := t.TempDir(), t.TempDir()
	writePlugin(t, user, "widget", "id: widget\nname: Updated\nexec: ./w\n")
	writePlugin(t, bundled, "widget", "id: widget\nname: Shipped\nexec: ./w\n")

	got, err := DiscoverAll([]string{user, bundled}, zap.NewNop())
	if err != nil {
		t.Fatalf("DiscoverAll: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("shadowing must yield one plugin, got %+v", got)
	}
	if got[0].Name != "Updated" || got[0].Dir != filepath.Join(user, "widget") {
		t.Fatalf("earlier root must win, got %+v", got[0])
	}
}

// Shadowing is deliberate and expected; a duplicate id WITHIN one root is
// still genuinely ambiguous and must stay a hard error.
func TestDiscoverAllStillRejectsDuplicatesWithinARoot(t *testing.T) {
	user := t.TempDir()
	writePlugin(t, user, "one", "id: dup\nname: One\nexec: ./x\n")
	writePlugin(t, user, "two", "id: dup\nname: Two\nexec: ./x\n")

	if _, err := DiscoverAll([]string{user, t.TempDir()}, zap.NewNop()); err == nil {
		t.Fatal("expected duplicate-id error within a single root")
	}
}

// An empty root is the normal case for the bundled directory in a dev
// checkout and for the user directory on a fresh install. Neither is an
// error, and an empty string root is skipped entirely so callers can pass
// "no bundled dir" without a branch.
func TestDiscoverAllToleratesEmptyAndMissingRoots(t *testing.T) {
	user := t.TempDir()
	writePlugin(t, user, "widget", goodManifest)

	got, err := DiscoverAll([]string{"", user, filepath.Join(t.TempDir(), "nope")}, zap.NewNop())
	if err != nil || len(got) != 1 || got[0].ID != "widget" {
		t.Fatalf("got %+v, %v", got, err)
	}
}

// The "no plugins found" warning is the one that answers "why is my plugin
// list empty" — with a search path it has to name every root that was
// searched, or it sends the reader to the wrong directory.
func TestDiscoverAllWarnsNamingEveryRoot(t *testing.T) {
	user, bundled := t.TempDir(), t.TempDir()
	core, logs := observer.New(zapcore.WarnLevel)

	if _, err := DiscoverAll([]string{user, bundled}, zap.New(core)); err != nil {
		t.Fatalf("DiscoverAll: %v", err)
	}
	if logs.Len() != 1 {
		t.Fatalf("want exactly one warning, got %d", logs.Len())
	}
	msg := logs.All()[0].ContextMap()["dirs"]
	if !strings.Contains(msg.(string), user) || !strings.Contains(msg.(string), bundled) {
		t.Fatalf("warning must name both roots, got %v", msg)
	}
}
