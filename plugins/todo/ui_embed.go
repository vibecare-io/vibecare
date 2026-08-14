//go:build !dev

package main

// Shipping build: the UI is baked into the binary, so the plugin directory
// is a binary plus a manifest and nothing else. The dev counterpart lives
// in ui_dev.go behind the `dev` build tag; both must export the same two
// functions so main.go never branches on the mode.

import (
	"embed"
	"io/fs"
	"log"
	"net/http"
)

//go:embed ui
var uiFS embed.FS

// uiHandler serves the embedded ui/ directory.
func uiHandler() http.Handler {
	sub, err := fs.Sub(uiFS, "ui")
	if err != nil {
		log.Fatalf("todo: embedded ui: %v", err)
	}
	return http.FileServer(http.FS(sub))
}

// devReload is a no-op in shipping builds. Nothing is watched, no extra
// route is registered, and the binary carries no reload machinery.
func devReload(*http.ServeMux) {}
