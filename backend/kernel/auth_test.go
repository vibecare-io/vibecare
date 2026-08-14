package kernel

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testAuth(t *testing.T) (*Auth, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "session")
	a, err := NewAuth(path)
	if err != nil {
		t.Fatal(err)
	}
	return a, path
}

var okHandler = http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
	w.Write([]byte("protected"))
})

func TestNewAuthMintsAndPersistsToken(t *testing.T) {
	a, path := testAuth(t)
	if len(a.Token()) != 64 { // 32 random bytes, hex encoded
		t.Fatalf("token %q has length %d, want 64 hex chars", a.Token(), len(a.Token()))
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(b)) != a.Token() {
		t.Fatal("session file does not contain the token")
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("session file mode = %v, want 0600", fi.Mode().Perm())
	}
}

func TestNewAuthMintsAFreshTokenEachTime(t *testing.T) {
	a1, _ := testAuth(t)
	a2, _ := testAuth(t)
	if a1.Token() == a2.Token() {
		t.Fatal("two Auths minted the same token")
	}
}

func TestUnauthenticatedRequestIs401(t *testing.T) {
	a, _ := testAuth(t)
	rec := httptest.NewRecorder()
	a.Middleware(okHandler).ServeHTTP(rec, httptest.NewRequest("GET", "/p/alpha/", nil))

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("code = %d, want 401", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "protected") {
		t.Fatal("handler ran despite failed auth")
	}
}

// The client hands the token over once, on the initial webview load. Core
// converts it into a cookie and redirects so the secret does not linger in
// the URL, history, or Referer headers.
func TestQueryTokenSetsCookieAndRedirects(t *testing.T) {
	a, _ := testAuth(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/p/alpha/index.html?"+tokenParam+"="+a.Token()+"&keep=1", nil)
	a.Middleware(okHandler).ServeHTTP(rec, req)

	if rec.Code != http.StatusFound {
		t.Fatalf("code = %d, want 302", rec.Code)
	}
	loc := rec.Header().Get("Location")
	if strings.Contains(loc, tokenParam+"=") {
		t.Fatalf("Location %q still carries the token", loc)
	}
	if !strings.Contains(loc, "keep=1") {
		t.Fatalf("Location %q dropped unrelated query params", loc)
	}
	if !strings.HasPrefix(loc, "/p/alpha/index.html") {
		t.Fatalf("Location %q changed the path", loc)
	}

	cookies := rec.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("got %d cookies, want 1", len(cookies))
	}
	c := cookies[0]
	if c.Name != sessionCookie || c.Value != a.Token() {
		t.Fatalf("cookie = %+v", c)
	}
	if !c.HttpOnly {
		t.Error("cookie must be HttpOnly")
	}
	if c.SameSite != http.SameSiteLaxMode {
		t.Error("cookie must be SameSite=Lax")
	}
	if c.Path != "/" {
		t.Errorf("cookie path = %q, want / so /_core/* is covered too", c.Path)
	}
}

func TestBadQueryTokenIs401(t *testing.T) {
	a, _ := testAuth(t)
	rec := httptest.NewRecorder()
	a.Middleware(okHandler).ServeHTTP(rec, httptest.NewRequest("GET", "/p/alpha/?"+tokenParam+"=nope", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("code = %d, want 401", rec.Code)
	}
}

func TestValidCookiePasses(t *testing.T) {
	a, _ := testAuth(t)
	req := httptest.NewRequest("GET", "/p/alpha/api/tasks", nil)
	req.AddCookie(&http.Cookie{Name: sessionCookie, Value: a.Token()})

	rec := httptest.NewRecorder()
	a.Middleware(okHandler).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || rec.Body.String() != "protected" {
		t.Fatalf("code = %d body = %q", rec.Code, rec.Body.String())
	}
}

func TestBadCookieIs401(t *testing.T) {
	a, _ := testAuth(t)
	req := httptest.NewRequest("GET", "/p/alpha/", nil)
	req.AddCookie(&http.Cookie{Name: sessionCookie, Value: "wrong"})

	rec := httptest.NewRecorder()
	a.Middleware(okHandler).ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("code = %d, want 401", rec.Code)
	}
}
