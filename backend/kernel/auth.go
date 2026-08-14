package kernel

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
)

const (
	// sessionCookie is set once from the ?vc= handoff and validated on
	// every subsequent request.
	sessionCookie = "vc_session"
	// tokenParam carries the token on the initial webview load only.
	tokenParam = "vc"
)

// Auth is core's entire authentication story. One token is minted at
// startup, handed to clients over gRPC, exchanged for a cookie on the
// first webview load, and validated on every proxied request.
//
// Plugins write NO auth code: by the time a request reaches a plugin it
// has already been authenticated here.
type Auth struct {
	token string
}

// NewAuth mints a fresh 32-byte session token and writes it to
// sessionPath with mode 0600. A new token every startup means a stale
// client cannot keep talking to a restarted core with an old secret.
func NewAuth(sessionPath string) (*Auth, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return nil, fmt.Errorf("mint session token: %w", err)
	}
	token := hex.EncodeToString(raw)

	if err := os.MkdirAll(filepath.Dir(sessionPath), 0o700); err != nil {
		return nil, fmt.Errorf("create session dir: %w", err)
	}
	if err := os.WriteFile(sessionPath, []byte(token+"\n"), 0o600); err != nil {
		return nil, fmt.Errorf("write session file: %w", err)
	}
	// WriteFile respects umask on an existing file; force the mode.
	if err := os.Chmod(sessionPath, 0o600); err != nil {
		return nil, fmt.Errorf("chmod session file: %w", err)
	}
	return &Auth{token: token}, nil
}

func (a *Auth) Token() string { return a.token }

func (a *Auth) valid(candidate string) bool {
	return subtle.ConstantTimeCompare([]byte(candidate), []byte(a.token)) == 1
}

// Middleware authenticates every request reaching core's HTTP surface.
//
// Two ways in: the one-time ?vc=<token> handoff (which is exchanged for a
// cookie and immediately redirected away, so the secret never lingers in
// the webview's URL or Referer), and the cookie itself thereafter.
func (a *Auth) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if tok := r.URL.Query().Get(tokenParam); tok != "" {
			if !a.valid(tok) {
				a.deny(w)
				return
			}
			http.SetCookie(w, &http.Cookie{
				Name:     sessionCookie,
				Value:    a.token,
				// Path=/ rather than /p/ because /_core/* is served from
				// this same origin and needs the same cookie.
				Path:     "/",
				HttpOnly: true,
				SameSite: http.SameSiteLaxMode,
			})
			q := r.URL.Query()
			q.Del(tokenParam)
			redirect := *r.URL
			redirect.RawQuery = q.Encode()
			http.Redirect(w, r, redirect.RequestURI(), http.StatusFound)
			return
		}

		c, err := r.Cookie(sessionCookie)
		if err != nil || !a.valid(c.Value) {
			a.deny(w)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (a *Auth) deny(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusUnauthorized)
	fmt.Fprint(w, `<!doctype html><meta charset="utf-8">
<title>Not authorized</title>
<body style="font:14px/1.5 -apple-system,sans-serif;padding:2rem">
<h1>Not authorized</h1>
<p>This page is served by VibeCare and needs a valid session.
Open it from the VibeCare app.</p>`)
}
