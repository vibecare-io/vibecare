// Package kernel is VibeCare's plugin kernel: it discovers, spawns, and
// supervises plugin subprocesses, reverse-proxies their HTTP UI, and moves
// events between them over an in-memory bus.
//
// The kernel contains ZERO product semantics (design D10). Nothing in this
// package may name a specific plugin or the domain it models; every plugin
// is just an id, a port, and a state. A test in kernel_test.go enforces
// this by scanning the package's own source.
package kernel

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"

	"go.uber.org/zap"
	"gopkg.in/yaml.v3"
)

// idPattern is the plugin id contract. The id is simultaneously the proxy
// routing key (/p/<id>/), the data directory name, and the topic namespace
// prefix, so it is deliberately narrow. Rejecting a leading underscore is
// what guarantees a plugin can never shadow core's reserved /_core/* paths.
var idPattern = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

// Manifest is the on-disk plugins/<id>/manifest.yaml. Core reads this
// BEFORE spawning: subscriptions come from the manifest rather than an RPC
// so the bus knows what to deliver before the plugin ever connects.
type Manifest struct {
	ID         string   `yaml:"id"`
	Name       string   `yaml:"name"`
	Icon       string   `yaml:"icon"`
	Exec       string   `yaml:"exec"`
	Subscribes []string `yaml:"subscribes"`
	Publishes  []string `yaml:"publishes"`
	UI         string   `yaml:"ui"`
	// Dir is the absolute directory the manifest was loaded from. It is the
	// plugin's working directory at spawn and the base for resolving Exec.
	Dir string `yaml:"-"`
}

const manifestName = "manifest.yaml"

// LoadManifest reads and validates a single manifest file. Validation is
// strict — a malformed manifest fails startup loudly rather than producing
// a half-configured plugin that misbehaves later.
func LoadManifest(path string) (Manifest, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Manifest{}, fmt.Errorf("read manifest %s: %w", path, err)
	}
	var m Manifest
	if err := yaml.Unmarshal(b, &m); err != nil {
		return Manifest{}, fmt.Errorf("parse manifest %s: %w", path, err)
	}
	if !idPattern.MatchString(m.ID) {
		return Manifest{}, fmt.Errorf("manifest %s: id %q must match %s", path, m.ID, idPattern)
	}
	if m.Exec == "" {
		return Manifest{}, fmt.Errorf("manifest %s: exec is required", path)
	}
	if m.Name == "" {
		m.Name = m.ID
	}
	if m.UI == "" {
		m.UI = "webview"
	}
	if m.UI != "webview" && m.UI != "none" {
		return Manifest{}, fmt.Errorf("manifest %s: ui %q must be \"webview\" or \"none\"", path, m.UI)
	}
	abs, err := filepath.Abs(filepath.Dir(path))
	if err != nil {
		return Manifest{}, fmt.Errorf("resolve dir for %s: %w", path, err)
	}
	m.Dir = abs
	return m, nil
}

// Discover scans root for <dir>/manifest.yaml and returns the manifests
// sorted by id. This file-based scan is what makes plugins droppable:
// adding one requires no registration in core and no rebuild of anything
// but the plugin itself.
//
// A missing root is not an error (fresh install, no plugins yet). A
// directory without a manifest is silently skipped. A directory WITH a
// manifest that fails to parse or validate is logged at warn (naming the
// path and the reason) and skipped, rather than aborting the whole scan —
// one broken drop-in must not disable every other plugin. A duplicate id
// IS a hard error, naming both offending directories: unlike a malformed
// manifest, which plugin dropped in badly, two plugins claiming the same
// id is genuinely ambiguous rather than merely broken, and there is no
// safe way to pick a winner.
func Discover(root string, log *zap.Logger) ([]Manifest, error) {
	entries, err := os.ReadDir(root)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("scan plugins dir %s: %w", root, err)
	}

	var out []Manifest
	seen := map[string]string{} // id -> dir that claimed it
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		dir := filepath.Join(root, e.Name())
		path := filepath.Join(dir, manifestName)
		if _, err := os.Stat(path); err != nil {
			continue
		}
		m, err := LoadManifest(path)
		if err != nil {
			log.Warn("skipping invalid plugin manifest", zap.String("path", path), zap.Error(err))
			continue
		}
		if prev, dup := seen[m.ID]; dup {
			return nil, fmt.Errorf("duplicate plugin id %q claimed by %s and %s", m.ID, prev, m.Dir)
		}
		seen[m.ID] = m.Dir
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })

	// An empty scan is almost always the wrong directory rather than a
	// deliberately empty one, and the symptom — a client that lists no
	// plugins — looks identical either way. Say so at warn, naming the path,
	// so the log answers the question instead of restating it.
	if len(out) == 0 {
		log.Warn("no plugins found; drop a <id>/manifest.yaml directory here and restart",
			zap.String("dir", root))
	}
	return out, nil
}
