// Command todo is VibeCare's reference plugin: the smallest complete
// example of the v2 contract. No state proto, no rev counters, no Swift,
// no core change — drop the directory in, restart core, there is a tab.
//
// /api/* is the real interface; the HTML at / is its first consumer. That
// split is what lets a non-webview client render this plugin later without
// core or this plugin changing.
package main

import (
    "embed"
    "encoding/json"
    "io/fs"
    "log"
    "net/http"
    "path/filepath"
    "strings"

    "github.com/vibecare-io/vibecare/backend/pkg/vc"
)

//go:embed ui
var uiFS embed.FS

func main() {
    h, err := vc.Connect()
    if err != nil {
        log.Fatalf("todo: %v", err)
    }

    store, err := OpenStore(filepath.Join(h.DataDir, "todo.json"))
    if err != nil {
        log.Fatalf("todo: open store: %v", err)
    }

    // Core sends Shutdown before SIGTERM precisely so this can happen.
    h.OnShutdown(func() {
        if err := store.Flush(); err != nil {
            log.Printf("todo: flush on shutdown: %v", err)
        }
        h.Listener.Close()
    })

    ui, err := fs.Sub(uiFS, "ui")
    if err != nil {
        log.Fatalf("todo: %v", err)
    }

    mux := http.NewServeMux()
    mux.Handle("/", http.FileServer(http.FS(ui)))
    mux.HandleFunc("/api/tasks", func(w http.ResponseWriter, r *http.Request) {
        switch r.Method {
        case http.MethodGet:
            writeJSON(w, store.List())

        case http.MethodPost:
            var body struct {
                Title string `json:"title"`
            }
            if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
                http.Error(w, "invalid JSON body", http.StatusBadRequest)
                return
            }
            t, err := store.Add(body.Title)
            if err != nil {
                http.Error(w, err.Error(), http.StatusBadRequest)
                return
            }
            // Cross-plugin behavior is always an enhancement gated on
            // presence: if nothing subscribes, this simply goes nowhere.
            if err := h.Publish("todo.created.v1", []byte(t.ID)); err != nil {
                log.Printf("todo: publish: %v", err)
            }
            w.WriteHeader(http.StatusCreated)
            writeJSON(w, t)

        default:
            w.Header().Set("Allow", "GET, POST")
            http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
        }
    })
    mux.HandleFunc("/api/tasks/", func(w http.ResponseWriter, r *http.Request) {
        rest := strings.TrimPrefix(r.URL.Path, "/api/tasks/")
        id, action, _ := strings.Cut(rest, "/")
        if id == "" {
            http.NotFound(w, r)
            return
        }

        switch {
        case action == "toggle" && r.Method == http.MethodPost:
            t, ok, err := store.Toggle(id)
            if err != nil {
                http.Error(w, err.Error(), http.StatusInternalServerError)
                return
            }
            if !ok {
                http.NotFound(w, r)
                return
            }
            writeJSON(w, t)

        case action == "" && r.Method == http.MethodDelete:
            ok, err := store.Delete(id)
            if err != nil {
                http.Error(w, err.Error(), http.StatusInternalServerError)
                return
            }
            if !ok {
                http.NotFound(w, r)
                return
            }
            w.WriteHeader(http.StatusNoContent)

        default:
            http.NotFound(w, r)
        }
    })

    if err := h.Serve(mux); err != nil {
        log.Printf("todo: server stopped: %v", err)
    }
}

func writeJSON(w http.ResponseWriter, v any) {
    w.Header().Set("Content-Type", "application/json")
    _ = json.NewEncoder(w).Encode(v)
}
