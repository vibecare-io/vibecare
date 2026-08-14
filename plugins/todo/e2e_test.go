package main

import (
    "bytes"
    "context"
    "encoding/json"
    "io"
    "net/http"
    "net/url"
    "os"
    "os/exec"
    "path/filepath"
    "testing"
    "time"

    "github.com/vibecare-io/vibecare/backend/kernel"
    "go.uber.org/zap"
)

// buildTodo compiles this plugin into dir and returns the binary path.
func buildTodo(t *testing.T, dir string) {
    t.Helper()
    cmd := exec.Command("go", "build", "-o", filepath.Join(dir, "todo"), ".")
    out, err := cmd.CombinedOutput()
    if err != nil {
        t.Fatalf("build todo: %v\n%s", err, out)
    }
}

// liveKernel drops the built plugin into a temp plugins dir, starts a
// kernel over it, and returns an authenticated HTTP client, the origin, and
// home — the root liveKernel derived cfg.DataRoot from — so callers can
// assert on-disk state directly (e.g. under home/data/todo/) rather than
// trusting the plugin's own in-memory responses for it.
func liveKernel(t *testing.T) (*http.Client, string, string) {
    t.Helper()
    home := t.TempDir()
    pluginDir := filepath.Join(home, "plugins", "todo")
    if err := os.MkdirAll(pluginDir, 0o755); err != nil {
        t.Fatal(err)
    }
    buildTodo(t, pluginDir)

    manifest, err := os.ReadFile("manifest.yaml")
    if err != nil {
        t.Fatal(err)
    }
    if err := os.WriteFile(filepath.Join(pluginDir, "manifest.yaml"), manifest, 0o644); err != nil {
        t.Fatal(err)
    }

    // The unix socket path has to stay short: macOS caps sockaddr_un.sun_path
    // at 104 bytes, and t.TempDir()'s default location is a long, deeply
    // nested path under $TMPDIR that routinely blows past it. A short, fixed
    // prefix under /tmp sidesteps both the test name length and whatever
    // $TMPDIR happens to be set to (see backend/kernel/kernel_test.go).
    sockDir, err := os.MkdirTemp("/tmp", "vctodo")
    if err != nil {
        t.Fatal(err)
    }
    t.Cleanup(func() { os.RemoveAll(sockDir) })

    cfg := kernel.Config{
        PluginsDir:  filepath.Join(home, "plugins"),
        DataRoot:    filepath.Join(home, "data"),
        SocketPath:  filepath.Join(sockDir, "core.sock"),
        SessionPath: filepath.Join(home, "session"),
    }
    k, err := kernel.New(cfg, zap.NewNop())
    if err != nil {
        t.Fatal(err)
    }
    if err := k.Start(context.Background()); err != nil {
        t.Fatal(err)
    }
    t.Cleanup(func() { k.Stop(context.Background()) })

    jar := &cookieJar{token: k.Token()}
    client := &http.Client{Jar: jar}

    // Wait for the plugin to register and start serving.
    base := k.BaseURL(context.Background())
    deadline := time.Now().Add(20 * time.Second)
    for time.Now().Before(deadline) {
        resp, err := client.Get(base + "/p/todo/api/tasks")
        if err == nil {
            resp.Body.Close()
            if resp.StatusCode == http.StatusOK {
                return client, base, home
            }
        }
        time.Sleep(100 * time.Millisecond)
    }
    t.Fatal("plugin never became reachable through the proxy")
    return nil, "", ""
}

// cookieJar presents the kernel's session cookie on every request, which
// is what the Swift shell's webview does after the ?vc= handoff.
type cookieJar struct{ token string }

func (j *cookieJar) SetCookies(*url.URL, []*http.Cookie) {}
func (j *cookieJar) Cookies(*url.URL) []*http.Cookie {
    return []*http.Cookie{{Name: "vc_session", Value: j.token}}
}

// The whole loop: drop the directory in, start core, there is a working
// plugin behind the proxy.
func TestPluginServesUIAndAPIThroughTheProxy(t *testing.T) {
    client, base, _ := liveKernel(t)

    resp, err := client.Get(base + "/p/todo/")
    if err != nil {
        t.Fatal(err)
    }
    defer resp.Body.Close()
    body, _ := io.ReadAll(resp.Body)
    if resp.StatusCode != http.StatusOK || !bytes.Contains(body, []byte("<title>Todo</title>")) {
        t.Fatalf("code = %d body = %.200s", resp.StatusCode, body)
    }
}

func TestPluginAPIRoundTrip(t *testing.T) {
    client, base, home := liveKernel(t)

    add, err := client.Post(base+"/p/todo/api/tasks", "application/json",
        bytes.NewReader([]byte(`{"title":"prove the loop"}`)))
    if err != nil {
        t.Fatal(err)
    }
    defer add.Body.Close()
    if add.StatusCode != http.StatusCreated {
        b, _ := io.ReadAll(add.Body)
        t.Fatalf("POST = %d: %s", add.StatusCode, b)
    }

    list, err := client.Get(base + "/p/todo/api/tasks")
    if err != nil {
        t.Fatal(err)
    }
    defer list.Body.Close()
    var tasks []Task
    if err := json.NewDecoder(list.Body).Decode(&tasks); err != nil {
        t.Fatal(err)
    }
    if len(tasks) != 1 || tasks[0].Title != "prove the loop" {
        t.Fatalf("tasks = %+v", tasks)
    }

    // The GET above only proves the plugin's in-memory state, which is true
    // even of a store whose flush is a silent no-op. The claim this whole
    // task exists to prove is the wiring: core's DataRoot ->
    // VIBECARE_DATA_DIR -> OpenStore(h.DataDir) really lands the task on
    // disk, at <DataRoot>/<plugin-id>/todo.json (see
    // backend/kernel/supervisor.go's dataDir = filepath.Join(dataRoot,
    // m.ID)). Assert against that file directly rather than trusting
    // another round trip through the same process that wrote it.
    storePath := filepath.Join(home, "data", "todo", "todo.json")
    onDiskBytes, err := os.ReadFile(storePath)
    if err != nil {
        t.Fatalf("read persisted store %s: %v", storePath, err)
    }
    var onDisk []Task
    if err := json.Unmarshal(onDiskBytes, &onDisk); err != nil {
        t.Fatalf("parse persisted store %s: %v", storePath, err)
    }
    if len(onDisk) != 1 || onDisk[0].ID != tasks[0].ID || onDisk[0].Title != "prove the loop" {
        t.Fatalf("on-disk tasks at %s = %+v", storePath, onDisk)
    }
}

// The dashboard is the debugging surface for everything else, so it has to
// show a real running plugin correctly.
func TestDashboardShowsThePluginUp(t *testing.T) {
    client, base, _ := liveKernel(t)

    resp, err := client.Get(base + "/_core/api/plugins")
    if err != nil {
        t.Fatal(err)
    }
    defer resp.Body.Close()

    var got struct {
        Plugins []struct {
            ID    string `json:"id"`
            State string `json:"state"`
            PID   int    `json:"pid"`
        } `json:"plugins"`
    }
    if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
        t.Fatal(err)
    }
    if len(got.Plugins) != 1 {
        t.Fatalf("dashboard shows %d plugins", len(got.Plugins))
    }
    p := got.Plugins[0]
    if p.ID != "todo" || p.State != "up" || p.PID == 0 {
        t.Fatalf("plugin = %+v", p)
    }
}

// Requests that skip the token must not reach the plugin — plugins write
// no auth code, so this is the only thing standing in front of them.
func TestProxyRejectsUnauthenticatedRequests(t *testing.T) {
    _, base, _ := liveKernel(t)

    resp, err := http.Get(base + "/p/todo/api/tasks")
    if err != nil {
        t.Fatal(err)
    }
    defer resp.Body.Close()
    if resp.StatusCode != http.StatusUnauthorized {
        t.Fatalf("code = %d, want 401", resp.StatusCode)
    }
}
