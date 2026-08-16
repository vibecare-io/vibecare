package main

import (
	"os"
	"path/filepath"
	"testing"
)

// resolvePluginsDirs is what makes a brew-installed VibeCare find the
// plugins that shipped with it. The binary lives at
// VibeCare.app/Contents/Resources/vibecare-server and its plugins sit in a
// `plugins` directory right beside it, so the server locates them from its
// own path rather than from anything baked into the LaunchAgent — which
// would hard-code an install location the cask is free to change.

func TestResolvePluginsDirsFlagWins(t *testing.T) {
	// A source checkout: `just run` passes --plugins-dir ../plugins and must
	// get exactly that, with no second directory quietly merged in. A dev
	// debugging one tree does not want ~/.vibecare/plugins-v2 in the mix.
	user, bundled := resolvePluginsDirs("/somewhere/plugins", t.TempDir(), "/home/u")
	if user != "/somewhere/plugins" || bundled != "" {
		t.Fatalf("got (%q, %q), want the flag alone", user, bundled)
	}
}

// Even when a sibling plugins dir exists, an explicit flag still means
// "only this one" — otherwise running the packaged binary against a test
// tree would silently pick up the shipped plugins too.
func TestResolvePluginsDirsFlagSuppressesBundled(t *testing.T) {
	exeDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(exeDir, "plugins"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, bundled := resolvePluginsDirs("/somewhere/plugins", exeDir, "/home/u"); bundled != "" {
		t.Fatalf("bundled = %q, want none when --plugins-dir is explicit", bundled)
	}
}

func TestResolvePluginsDirsFindsBundledBesideExecutable(t *testing.T) {
	exeDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(exeDir, "plugins"), 0o755); err != nil {
		t.Fatal(err)
	}

	user, bundled := resolvePluginsDirs("", exeDir, "/home/u")

	if want := filepath.Join("/home/u", ".vibecare", "plugins-v2"); user != want {
		t.Fatalf("user = %q, want %q", user, want)
	}
	if want := filepath.Join(exeDir, "plugins"); bundled != want {
		t.Fatalf("bundled = %q, want %q", bundled, want)
	}
}

// A source build (go run ./cmd/server) has no plugins dir beside the
// binary. Reporting one anyway would point discovery at Go's build cache.
func TestResolvePluginsDirsNoBundledWhenAbsent(t *testing.T) {
	user, bundled := resolvePluginsDirs("", t.TempDir(), "/home/u")

	if want := filepath.Join("/home/u", ".vibecare", "plugins-v2"); user != want {
		t.Fatalf("user = %q, want %q", user, want)
	}
	if bundled != "" {
		t.Fatalf("bundled = %q, want none", bundled)
	}
}

// A *file* named `plugins` beside the binary is not a plugins directory.
// Passing it on would turn a stray file into a scan error at startup.
func TestResolvePluginsDirsIgnoresNonDirectory(t *testing.T) {
	exeDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(exeDir, "plugins"), []byte("not a dir"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, bundled := resolvePluginsDirs("", exeDir, "/home/u"); bundled != "" {
		t.Fatalf("bundled = %q, want none for a non-directory", bundled)
	}
}

// os.Executable can fail, and a server that refuses to start because it
// could not find an optional directory would be worse than one with no
// bundled plugins. An empty exeDir just means "no bundled dir".
func TestResolvePluginsDirsToleratesUnknownExeDir(t *testing.T) {
	user, bundled := resolvePluginsDirs("", "", "/home/u")

	if want := filepath.Join("/home/u", ".vibecare", "plugins-v2"); user != want {
		t.Fatalf("user = %q, want %q", user, want)
	}
	if bundled != "" {
		t.Fatalf("bundled = %q, want none", bundled)
	}
}
