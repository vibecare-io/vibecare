package vc

import (
	"context"
	"net/url"
	"strings"
	"testing"

	clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
)

// The URL has to be the one the kernel's Auth middleware actually accepts:
// ?vc=<token> on the first load, which it exchanges for an HttpOnly cookie
// and then redirects away so the secret does not linger in the address bar
// or a Referer header. Anything else lands on a 401.
func TestPluginURLCarriesTheHandoffToken(t *testing.T) {
	s, f := newTestServer(t)
	defer s.Close()

	got, err := s.PluginURL(context.Background(), "todo")
	if err != nil {
		t.Fatalf("PluginURL: %v", err)
	}

	u, err := url.Parse(got)
	if err != nil {
		t.Fatalf("PluginURL returned an unparseable URL %q: %v", got, err)
	}
	if !strings.HasPrefix(got, f.kernel.URL) {
		t.Errorf("URL %q is not on the kernel origin %q", got, f.kernel.URL)
	}
	if u.Path != "/p/todo/" {
		t.Errorf("path = %q, want the plugin's proxied path /p/todo/", u.Path)
	}
	if tok := u.Query().Get("vc"); tok != testToken {
		t.Errorf("vc = %q, want the session token %q", tok, testToken)
	}
}

// An unknown id is a not-found, with the exit code a script can act on.
func TestPluginURLUnknownID(t *testing.T) {
	s, _ := newTestServer(t)
	defer s.Close()

	if _, err := s.PluginURL(context.Background(), "nope"); err == nil {
		t.Fatal("PluginURL succeeded for an unknown plugin")
	} else if ExitCode(err) != ExitNotFound {
		t.Errorf("exit code = %d, want %d", ExitCode(err), ExitNotFound)
	}
}

// A headless plugin has no page to open. Saying "not found" would send the
// user looking for a typo in a plugin that is running perfectly well, so the
// error has to name the actual reason.
func TestPluginURLHeadlessPluginExplainsItself(t *testing.T) {
	s, _ := newTestServer(t,
		withRoster(&clientv1.PluginInfo{
			Id: "watcher", Name: "Watcher", Path: "/p/watcher/", State: clientv1.State_UP,
		}),
		withKernelPlugins(kernelPlugin{
			ID: "watcher", Name: "Watcher", Path: "/p/watcher/", UI: "none", State: "up",
		}),
	)
	defer s.Close()

	_, err := s.PluginURL(context.Background(), "watcher")
	if err == nil {
		t.Fatal("PluginURL succeeded for a headless plugin")
	}
	if !strings.Contains(err.Error(), "headless") && !strings.Contains(err.Error(), "ui: none") {
		t.Errorf("error %q does not explain that the plugin serves no UI", err)
	}
}

// "No such plugin" and "that plugin does not build from here" send a reader
// in completely different directions, so they must not share a message.
func TestPluginBuildRequiresAManifestEntry(t *testing.T) {
	s, _ := newTestServer(t)
	defer s.Close()

	// The default fixture declares no build command.
	_, err := s.PluginBuild(context.Background(), "todo")
	if err == nil {
		t.Fatal("PluginBuild succeeded for a plugin with no build: line")
	}
	if !strings.Contains(err.Error(), "build:") {
		t.Errorf("error does not point at the manifest: %v", err)
	}
	if ExitCode(err) == ExitNotFound {
		t.Error("a buildless plugin was reported as not found; it exists")
	}

	if _, err := s.PluginBuild(context.Background(), "nope"); ExitCode(err) != ExitNotFound {
		t.Errorf("unknown plugin exit code = %d, want %d", ExitCode(err), ExitNotFound)
	}
}

func TestPluginBuildReturnsDirAndCommand(t *testing.T) {
	s, _ := newTestServer(t, withKernelPlugins(kernelPlugin{
		ID: "todo", Name: "Todo", Path: "/p/todo/", UI: "webview", State: "up",
		Dir: "/repo/plugins/todo", Build: "just build-todo-plugin",
	}))
	defer s.Close()

	pl, err := s.PluginBuild(context.Background(), "todo")
	if err != nil {
		t.Fatalf("PluginBuild: %v", err)
	}
	if pl.Dir != "/repo/plugins/todo" || pl.Build != "just build-todo-plugin" {
		t.Errorf("got dir=%q build=%q", pl.Dir, pl.Build)
	}
}
