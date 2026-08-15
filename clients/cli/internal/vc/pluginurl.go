package vc

import (
	"context"
	"net/url"
	"strings"
)

// tokenParam is the kernel's one-time handoff parameter (backend/kernel/auth.go).
// The middleware accepts ?vc=<token> on a first load, swaps it for an
// HttpOnly cookie, and redirects to the same path without it — so the token
// does not survive in the address bar, the history, or a Referer header.
// That redirect is why this is the right thing to hand a browser and the
// wrong thing to paste into a chat log.
const tokenParam = "vc"

// PluginURL builds the address that opens a plugin's own UI in a browser,
// authenticated.
//
// Three things have to come together and none of them are guessable: the
// kernel's origin is an ephemeral 127.0.0.1 port, the token is minted fresh
// on every core start, and the proxied path belongs to the plugin. All three
// are read from what core actually reported rather than reconstructed.
func (s *Session) PluginURL(ctx context.Context, id string) (string, error) {
	base, token, err := s.kernelOrigin(ctx)
	if err != nil {
		return "", err
	}

	r, err := s.Roster(ctx)
	if err != nil {
		return "", err
	}

	for _, p := range r.Plugins {
		if p.ID != id {
			continue
		}
		if !p.HasUI() {
			return "", Errorf("plugin %q is headless (ui: none) and serves no page to open", id)
		}
		return joinURL(base, p.Path, token)
	}

	// The Shell roster omits headless plugins entirely, so a plugin that is
	// running fine but serves no UI arrives here looking exactly like a
	// typo. Ask the kernel directly rather than blaming the user's spelling.
	if stats, err := s.kernelPlugins(ctx); err == nil {
		for _, k := range stats {
			if k.ID == id {
				return "", Errorf("plugin %q is headless (ui: none) and serves no page to open", id)
			}
		}
	}
	return "", NotFound("plugin", id)
}

// joinURL glues the kernel origin to a plugin path and appends the handoff
// token. Built with net/url rather than string concatenation so a path that
// already carries a query, or an origin with a trailing slash, cannot
// silently produce a URL that 404s.
func joinURL(base, path, token string) (string, error) {
	u, err := url.Parse(base)
	if err != nil {
		return "", Errorf("kernel reported an unparseable origin %q: %v", base, err)
	}
	ref, err := url.Parse(path)
	if err != nil {
		return "", Errorf("plugin reported an unparseable path %q: %v", path, err)
	}

	out := u.ResolveReference(ref)
	q := out.Query()
	q.Set(tokenParam, token)
	out.RawQuery = q.Encode()

	// The kernel proxies /p/<id>/ with the trailing slash; without it the
	// plugin's relative asset links resolve one level too high.
	if !strings.HasSuffix(out.Path, "/") {
		out.Path += "/"
	}
	return out.String(), nil
}

// Buildable reports whether this plugin declares how to rebuild itself.
// Empty is the normal case for an installed plugin: nothing was shipped
// alongside it to build from.
func (p Plugin) Buildable() bool { return p.Build != "" && p.Dir != "" }

// PluginBuild returns where a plugin lives and the command it declares for
// rebuilding. The error distinguishes the two ways this can be unavailable,
// because "no such plugin" and "that plugin does not build from here" send a
// reader in completely different directions.
func (s *Session) PluginBuild(ctx context.Context, id string) (Plugin, error) {
	r, err := s.Roster(ctx)
	if err != nil {
		return Plugin{}, err
	}
	for _, p := range r.Plugins {
		if p.ID != id {
			continue
		}
		if !p.Buildable() {
			return Plugin{}, Errorf(
				"plugin %q declares no build: command in its manifest, so there is nothing to rebuild", id)
		}
		return p, nil
	}
	return Plugin{}, NotFound("plugin", id)
}
