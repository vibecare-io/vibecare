# Plugin Architecture v2 — Kernel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the v1 plugin system with a v2 kernel where plugins are supervised subprocesses that serve their own HTTP UI behind a core reverse proxy, proven end-to-end by a `todo` reference plugin and a Swift shell that renders plugins as webviews.

**Architecture:** A new `backend/kernel` package is booted from the existing `backend/cmd/server` process. It discovers `plugins/<id>/manifest.yaml`, spawns each plugin as a subprocess, and serves a loopback HTTP origin that reverse-proxies `/p/<id>/*` to the plugin's own kernel-assigned port. Plugins are gRPC *clients* only, dialing a unix socket to call three RPCs (`Register`/`Publish`/`Alert`). The Swift client's roster and alerts arrive over two new streaming RPCs on the existing TCP gRPC server; plugin screens are `WKWebView`s pointed at the proxy.

**Tech Stack:** Go 1.23 · gRPC (unix socket + TCP) · `httputil.ReverseProxy` · zap · protobuf · SwiftUI + WKWebView + grpc-swift-2

**Spec:** [`docs/superpowers/specs/2026-08-13-plugin-architecture-v2-design.md`](../specs/2026-08-13-plugin-architecture-v2-design.md)

## Global Constraints

- **Go module:** `github.com/vibecare-io/vibecare/backend`, Go 1.23.0 / toolchain go1.24.4. All kernel code lives in module `backend`.
- **D2 — plugins are never gRPC servers.** Core must never dial a plugin over gRPC. Plugin→core only.
- **D6 — every listener binds `127.0.0.1:0`.** No configurable ports anywhere in kernel or plugins. The kernel's unix socket is the one fixed path.
- **D10 — zero product semantics in `backend/kernel/`.** No file under `backend/kernel/` may contain the substrings `posture`, `nailbiting`, `nail-biting`, `todo`, `vibecheck`, `detection`, or `behavior` (case-insensitive). This covers **every `.go` file including `_test.go`**: fixture ids and test data are subject to it too, so kernel tests name plugins `alpha`/`beta`/`widget`, never after a real one. Enforced by a test in Task 9.
- **Plugin id regex:** `^[a-z][a-z0-9-]*$` — exact, no exceptions. Rejects leading `_` so `/_core/*` can never collide.
- **Reverse proxy MUST set `FlushInterval = -1`.** Non-negotiable; MJPEG/SSE hang without it.
- **Plugin state has four writers — use `Registry.CompareAndSetState` when the state you are reacting to was read earlier.** `health.go`, `supervisor.go`, `rpc.go`, and `kernel.go` all write plugin state. A writer that decided what to write based on a state it read moments ago must commit with `CompareAndSetState(id, observed, next, detail)` and drop its result if that returns false, rather than blindly calling `SetState` and clobbering a newer transition. Added during Task 6 after review; `SetState` remains correct for unconditional writes like "the process just exited".
- **Socket:** `~/.vibecare/core.sock`, mode `0600`. **Session file:** `~/.vibecare/session`, mode `0600`. **Data root:** `~/.vibecare/data/<plugin-id>/`.
- **Spawn env, exactly these three:** `VIBECARE_SOCKET`, `VIBECARE_PLUGIN_ID`, `VIBECARE_DATA_DIR`.
- **Timings, verbatim from spec:** registration timeout 10s · health probe every 10s with 2s timeout · 3 consecutive bad probes `up`→`degraded`, 3 more →`down` · restart backoff 1,2,4,8,16,32,60s capped · backoff resets after 60s `up` · 5 consecutive failed starts →`failed` (no auto-restart) · shutdown = `CoreMsg.Shutdown`, then SIGTERM, then SIGKILL after 5s.
- **Proto packages (deviation from spec, deliberate):** `vibecare.kernel.plugin.v1` and `vibecare.kernel.client.v1` with `option swift_prefix = "VCK"`. The spec left package names unspecified; these avoid colliding with the still-present `vibecare.plugin.v1` (v1, deleted in Task 13) and `vibecare.v1` (`swift_prefix = "VC"`) during the coexistence window.
- **Client service name (deviation):** the spec calls it `service Vibecare`; this plan names it `service Shell` because `Vibecare` is already the conceptual name of the main app service set in `proto/vibecare.proto`. Two RPCs, unchanged.
- **Build order:** v2 lands additively (Tasks 1–12). v1 is deleted only in Task 14, so every task before it leaves `just test` and `just swift-build` green. The one early deletion is `plugins/vibecheck/` in Task 10, which blocks discovery and touches no build.
- **Out of scope (spec §16 steps 1, 5–8):** the macOS TCC/camera spike, the `vibecheck` plugin rewrite, `vision-macos`, `activitywatch`, `vision-linux`, the conformance suite. This plan is spec steps 2, 3, and 4.

---

## File Structure

**New — protocol:**
- `proto/plugin/v1/plugin.proto` — `PluginHost` service: `Register`/`Publish`/`Alert`, plus `AlertReq`/`AlertAction` (imported by client proto, never duplicated).
- `proto/client/v1/client.proto` — `Shell` service: `Plugins`/`Intents` streams.

**New — kernel (`backend/kernel/`), one responsibility per file:**
- `manifest.go` — parse + validate `manifest.yaml`; `Discover` scans a root dir.
- `registry.go` — in-memory plugin table, state/stat mutation, roster fan-out (`Watch`).
- `bus.go` — topic→subscriber channels, publish authorization, demand refcount.
- `supervisor.go` — spawn/env/registration timeout/backoff restart/SIGTERM+SIGKILL.
- `health.go` — `GET /health` probing and the pure state-machine function.
- `auth.go` — session token minting, `?vc=` handoff, cookie validation middleware.
- `proxy.go` — `/p/<id>/*` reverse proxy, down-plugin error page.
- `status.go` — `/_core/status` HTML, `/_core/api/plugins` JSON, restart endpoint.
- `rpc.go` — the `PluginHost` gRPC implementation (unix socket server).
- `intents.go` — alert fan-out to connected clients.
- `shell.go` — the `Shell` gRPC implementation (registered on the app's TCP server).
- `kernel.go` — `Config`/`Kernel` facade: wires all of the above, owns both listeners.

**New — SDK and reference plugin:**
- `backend/pkg/vc/` (package `vc`) — `connect.go`, `handle.go`. The whole plugin-author surface.
- `plugins/todo/` — own Go module: `manifest.yaml`, `main.go`, `store.go`, `ui/index.html`.

**New — Swift shell:**
- `VibeCare/Services/PluginShellService.swift` — the two client streams.
- `VibeCare/Views/Plugins/PluginWebView.swift` — `NSViewRepresentable` over `WKWebView`.
- `VibeCare/Models/PluginRoster.swift` — plain-value roster model + URL construction (unit-testable, no gRPC).

**Modified:** `scripts/generate_proto.sh` (subdirectory protos) · `backend/cmd/server/main.go` (boot kernel) · `Justfile` (`--plugins-dir`, todo build) · `VibeCare/Views/Plugins/PluginListView.swift` · `VibeCare/Views/Plugins/PluginScreen.swift` · `VibeCare/Services/GRPCClientManager.swift`.

**Deleted:** `plugins/vibecheck/` in Task 10 (v1 shell-native plugin whose manifest id is invalid under v2 and blocks discovery; spec §16 step 5 re-creates it). Everything else in Task 14: `proto/vibecare_plugin.proto` · `PluginHostService` + its messages in `proto/vibecare.proto` · `backend/internal/plugins/` · `backend/pkg/pluginsdk/` · `backend/cmd/plugin-todos/` · `VibeCare/Views/Plugins/PluginRenderer.swift` · `VibeCare/Services/PluginService.swift` · `VCStubs/vibecare_plugin.*.swift`.

`backend/pkg/pluginwire` **survives** — the v2 SDK and `kernel/rpc.go` both use its `PluginIDMetadataKey`.

---

### Task 1: Proto contracts and code generation

**Files:**
- Create: `proto/plugin/v1/plugin.proto`
- Create: `proto/client/v1/client.proto`
- Modify: `scripts/generate_proto.sh:130-145` (Go generation) and `scripts/generate_proto.sh:215-235` (Swift generation)

**Interfaces:**
- Consumes: nothing.
- Produces: Go packages `backend/pkg/proto/plugin/v1` (import alias `pluginv1`) and `backend/pkg/proto/client/v1` (alias `clientv1`). Swift types `VCKRegisterReq`, `VCKCoreMsg`, `VCKEvent`, `VCKAlertReq`, `VCKAlertAction`, `VCKPluginList`, `VCKPluginInfo`, `VCKState`, `VCKUIIntent`, `VCKAlert`, and clients `VCKPluginHost.Client`, `VCKShell.Client`.

- [ ] **Step 1: Write `proto/plugin/v1/plugin.proto`**

```proto
syntax = "proto3";
package vibecare.kernel.plugin.v1;

option go_package = "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1;pluginv1";
option swift_prefix = "VCK";

import "google/protobuf/empty.proto";
import "google/protobuf/timestamp.proto";

// PluginHost is served by core over a unix socket. A plugin is ALWAYS the
// gRPC client and NEVER a gRPC server (design D2) — core has no way to call
// into a plugin over gRPC, by construction.
service PluginHost {
  // Register opens the single long-lived stream that does three jobs:
  // confirms registration (Ready), delivers subscribed bus events (Event),
  // and signals graceful shutdown (Shutdown).
  rpc Register(RegisterReq) returns (stream CoreMsg);
  rpc Publish(Event) returns (google.protobuf.Empty);
  rpc Alert(AlertReq) returns (google.protobuf.Empty);
}

// http_port is the kernel-assigned port the plugin's own HTTP server is
// listening on (127.0.0.1:0 — the kernel picks it, see D6). Core needs it
// to build the reverse-proxy target and to probe /health.
message RegisterReq {
  string id = 1;
  uint32 http_port = 2;
}

message CoreMsg {
  oneof k {
    Ready    ready    = 1;
    Event    event    = 2;
    Shutdown shutdown = 3;
  }
}

message Event {
  string topic = 1;
  bytes  payload = 2;
  google.protobuf.Timestamp ts = 3;
}

message Ready {}

message Shutdown { string reason = 1; }

message AlertReq {
  string title = 1;
  string body  = 2;
  string level = 3;                  // "info" | "warn"
  repeated AlertAction actions = 4;  // rendered as buttons
}

// url is plugin-relative; the client navigates to /p/<plugin>/<url>.
message AlertAction {
  string label = 1;
  string url   = 2;
}
```

- [ ] **Step 2: Write `proto/client/v1/client.proto`**

Note it imports `plugin/v1` for `AlertAction` rather than redefining it — an alert crosses both contracts and two definitions would drift.

```proto
syntax = "proto3";
package vibecare.kernel.client.v1;

option go_package = "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1;clientv1";
option swift_prefix = "VCK";

import "google/protobuf/empty.proto";
import "plugin/v1/plugin.proto";

// Shell is the entire client-facing plugin contract: two RPCs, frozen.
// Clients contain no plugin-specific code — a client knows only "a URL",
// never a schema.
service Shell {
  rpc Plugins(google.protobuf.Empty) returns (stream PluginList);
  rpc Intents(google.protobuf.Empty) returns (stream UIIntent);
}

message PluginList {
  repeated PluginInfo plugins = 1;
  string base_url = 2;  // e.g. "http://127.0.0.1:52341"
  string token    = 3;  // appended to the first webview load as ?vc=<token>
}

message PluginInfo {
  string id     = 1;
  string name   = 2;
  string icon   = 3;
  string path   = 4;   // "/p/todo/" — stable across plugin restarts
  State  state  = 5;
  string detail = 6;   // exit reason when down/failed; /health detail when degraded
}

enum State {
  STARTING = 0;
  UP       = 1;
  DEGRADED = 2;
  DOWN     = 3;
  FAILED   = 4;
}

message UIIntent {
  oneof k { Alert alert = 1; }
}

message Alert {
  string plugin = 1;
  string title  = 2;
  string body   = 3;
  string level  = 4;
  repeated vibecare.kernel.plugin.v1.AlertAction actions = 5;
}
```

- [ ] **Step 3: Teach the generator about subdirectory protos**

`generate_proto.sh` currently globs `"$PROTO_DIR"/*.proto`, which misses the new nested files. In `generate_backend()`, replace the `protoc` invocation with:

```bash
    # Protos now live both at the root and under versioned subdirectories
    # (plugin/v1, client/v1). paths=source_relative mirrors that tree into
    # the output dir, so proto/plugin/v1/plugin.proto lands at
    # backend/pkg/proto/plugin/v1/plugin.pb.go.
    local proto_files
    proto_files=$(cd "$PROTO_DIR" && find . -name '*.proto' | sed 's|^\./||' | sort)

    protoc \
        --proto_path="$PROTO_DIR" \
        --go_out="$output_dir" \
        --go_opt=paths=source_relative \
        --go-grpc_out="$output_dir" \
        --go-grpc_opt=paths=source_relative \
        $proto_files
```

In `generate_macos()`, replace both `protoc` invocations' trailing `"$PROTO_DIR"/*.proto` with the same discovered list, and add `--swift_opt=FileNaming=DropPath` / `--grpc-swift_opt=FileNaming=DropPath` so nested protos still land flat in `VCStubs/` (the SwiftPM target has `path: "VCStubs"` and does not recurse into per-proto subdirectories):

```bash
    local proto_files
    proto_files=$(cd "$PROTO_DIR" && find . -name '*.proto' | sed 's|^\./||' | sort)

    protoc \
        --proto_path="$PROTO_DIR" \
        --swift_opt=Visibility=Public \
        --swift_opt=FileNaming=DropPath \
        --swift_out="$output_dir" \
        $proto_files

    protoc \
        --proto_path="$PROTO_DIR" \
        --plugin=protoc-gen-grpc-swift="$grpc_plugin" \
        --grpc-swift_opt=Visibility=Public \
        --grpc-swift_opt=FileNaming=DropPath \
        --grpc-swift_out="$output_dir" \
        $proto_files
```

- [ ] **Step 4: Generate and verify both sides compile**

Run: `just proto-gen`
Expected: `backend/pkg/proto/plugin/v1/plugin.pb.go`, `plugin_grpc.pb.go`, `backend/pkg/proto/client/v1/client.pb.go`, `client_grpc.pb.go` exist, and `VCStubs/plugin.pb.swift`, `plugin.grpc.swift`, `client.pb.swift`, `client.grpc.swift` exist alongside the untouched `vibecare*.swift`.

Run: `cd backend && go build ./...`
Expected: success.

Run: `just swift-build`
Expected: success — the new stubs coexist with v1's because the `VCK` prefix and `vibecare.kernel.*` packages collide with nothing.

- [ ] **Step 5: Commit**

```bash
git add proto/plugin proto/client scripts/generate_proto.sh backend/pkg/proto clients/macos-swift/VibeCare/VCStubs
git commit -m "feat(proto): add plugin/v1 and client/v1 kernel contracts"
```

---

### Task 2: Manifest parsing and discovery

**Files:**
- Create: `backend/kernel/manifest.go`
- Test: `backend/kernel/manifest_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  ```go
  package kernel

  type Manifest struct {
      ID         string   `yaml:"id"`
      Name       string   `yaml:"name"`
      Icon       string   `yaml:"icon"`
      Exec       string   `yaml:"exec"`
      Subscribes []string `yaml:"subscribes"`
      Publishes  []string `yaml:"publishes"`
      UI         string   `yaml:"ui"` // "webview" | "none"
      Dir        string   `yaml:"-"`  // absolute dir the manifest was loaded from
  }

  func LoadManifest(path string) (Manifest, error)
  func Discover(root string) ([]Manifest, error) // sorted by ID
  ```

- [ ] **Step 1: Write the failing tests**

```go
package kernel

import (
    "os"
    "path/filepath"
    "strings"
    "testing"
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

    got, err := Discover(root)
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
    got, err := Discover(root)
    if err != nil || len(got) != 1 || got[0].ID != "widget" {
        t.Fatalf("got %+v, %v", got, err)
    }
}

// Two plugins claiming the same id would collide on routing, data dir, and
// topic namespace. The error must name BOTH paths so it's actionable.
func TestDiscoverRejectsDuplicateIDs(t *testing.T) {
    root := t.TempDir()
    writePlugin(t, root, "one", "id: dup\nname: One\nexec: ./x\n")
    writePlugin(t, root, "two", "id: dup\nname: Two\nexec: ./x\n")

    _, err := Discover(root)
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
    got, err := Discover(filepath.Join(t.TempDir(), "nope"))
    if err != nil || len(got) != 0 {
        t.Fatalf("got %+v, %v", got, err)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && go test ./kernel/...`
Expected: FAIL — `no required module provides package .../kernel` or undefined `LoadManifest`.

- [ ] **Step 3: Write `backend/kernel/manifest.go`**

```go
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
// directory without a manifest is silently skipped. A duplicate id IS an
// error, naming both offending directories.
func Discover(root string) ([]Manifest, error) {
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
            return nil, err
        }
        if prev, dup := seen[m.ID]; dup {
            return nil, fmt.Errorf("duplicate plugin id %q claimed by %s and %s", m.ID, prev, m.Dir)
        }
        seen[m.ID] = m.Dir
        out = append(out, m)
    }
    sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
    return out, nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && go test ./kernel/... -v`
Expected: PASS, all nine tests.

- [ ] **Step 5: Commit**

```bash
git add backend/kernel/manifest.go backend/kernel/manifest_test.go
git commit -m "feat(kernel): manifest parsing and file-based plugin discovery"
```

---

### Task 3: Registry — plugin table, states, and roster fan-out

**Files:**
- Create: `backend/kernel/registry.go`
- Test: `backend/kernel/registry_test.go`

**Interfaces:**
- Consumes: `Manifest` (Task 2).
- Produces:
  ```go
  type State int
  const (
      StateStarting State = iota
      StateUp
      StateDegraded
      StateDown
      StateFailed
  )
  func (s State) String() string // "starting"|"up"|"degraded"|"down"|"failed"

  type PluginStat struct {
      ID, Name, Icon, Path string
      State                State
      Detail               string
      PID                  int
      UptimeSec            int64
      Restarts             int
      ProbeLatencyMS       int64
      EventsPublished      uint64
      EventsDelivered      uint64
      LastEventUnix        int64
      UI                   string
  }

  type Registry struct{ /* unexported */ }
  func NewRegistry(log *zap.Logger) *Registry
  func (r *Registry) Add(m Manifest)
  func (r *Registry) Manifests() []Manifest
  func (r *Registry) Manifest(id string) (Manifest, bool)
  func (r *Registry) SetState(id string, s State, detail string)
  func (r *Registry) State(id string) (State, bool)
  func (r *Registry) SetPort(id string, port uint32)
  func (r *Registry) Port(id string) (uint32, bool)
  func (r *Registry) SetProcess(id string, pid int)
  func (r *Registry) IncRestarts(id string)
  func (r *Registry) SetProbeLatency(id string, d time.Duration)
  func (r *Registry) CountPublished(id string)
  func (r *Registry) CountDelivered(id string, n int)
  func (r *Registry) Snapshot() []PluginStat
  func (r *Registry) Watch() (<-chan []PluginStat, func())
  ```

Design notes for the implementer:

- **`Watch` semantics.** Returns a buffered channel (cap 1) that receives the current snapshot immediately on subscribe, then a fresh full snapshot on **every state change only** (not on stat-counter changes — those would flood clients). If the channel is full, the pending snapshot is *replaced*, never blocked on: a slow client must not stall a state transition. The returned func unsubscribes and closes the channel; it must be idempotent.
- **`SetState` is the only trigger for fan-out.** Setting the same state again with the same detail is a no-op and does not notify. This keeps the roster quiet during steady-state probing.
- **`Path`** in a stat is always `"/p/" + id + "/"`. It is stable across restarts by construction, which is what lets a client keep a webview pointed at one URL forever.
- `UptimeSec` is `0` unless state is `StateUp` or `StateDegraded` — a down plugin has no uptime.

- [ ] **Step 1: Write the failing tests**

```go
package kernel

import (
    "testing"
    "time"

    "go.uber.org/zap"
)

func testRegistry(t *testing.T, ids ...string) *Registry {
    t.Helper()
    r := NewRegistry(zap.NewNop())
    for _, id := range ids {
        r.Add(Manifest{ID: id, Name: id, Icon: "circle", Exec: "./" + id, UI: "webview", Dir: "/tmp/" + id})
    }
    return r
}

func TestRegistryNewPluginStartsStarting(t *testing.T) {
    r := testRegistry(t, "alpha")
    got, ok := r.State("alpha")
    if !ok || got != StateStarting {
        t.Fatalf("state = %v, %v; want starting", got, ok)
    }
}

func TestStateStrings(t *testing.T) {
    want := map[State]string{
        StateStarting: "starting", StateUp: "up", StateDegraded: "degraded",
        StateDown: "down", StateFailed: "failed",
    }
    for s, w := range want {
        if s.String() != w {
            t.Errorf("State(%d).String() = %q, want %q", s, s.String(), w)
        }
    }
}

func TestSnapshotPathIsStable(t *testing.T) {
    r := testRegistry(t, "alpha")
    s := r.Snapshot()
    if len(s) != 1 || s[0].Path != "/p/alpha/" {
        t.Fatalf("snapshot = %+v, want path /p/alpha/", s)
    }
    // A restart changes port and pid but must never change the path — the
    // client keeps one webview URL for the life of the plugin.
    r.SetPort("alpha", 41000)
    r.SetProcess("alpha", 999)
    r.IncRestarts("alpha")
    if r.Snapshot()[0].Path != "/p/alpha/" {
        t.Fatal("path changed across restart")
    }
}

func TestSnapshotIsSortedByID(t *testing.T) {
    r := testRegistry(t, "zeta", "alpha", "mid")
    got := r.Snapshot()
    if got[0].ID != "alpha" || got[1].ID != "mid" || got[2].ID != "zeta" {
        t.Fatalf("unsorted: %+v", got)
    }
}

func TestWatchReceivesCurrentSnapshotImmediately(t *testing.T) {
    r := testRegistry(t, "alpha")
    ch, cancel := r.Watch()
    defer cancel()

    select {
    case snap := <-ch:
        if len(snap) != 1 || snap[0].State != StateStarting {
            t.Fatalf("first snapshot = %+v", snap)
        }
    case <-time.After(time.Second):
        t.Fatal("no initial snapshot delivered")
    }
}

func TestWatchNotifiesOnStateChange(t *testing.T) {
    r := testRegistry(t, "alpha")
    ch, cancel := r.Watch()
    defer cancel()
    <-ch // drain initial

    r.SetState("alpha", StateUp, "")

    select {
    case snap := <-ch:
        if snap[0].State != StateUp {
            t.Fatalf("state = %v, want up", snap[0].State)
        }
    case <-time.After(time.Second):
        t.Fatal("state change did not notify")
    }
}

// Setting the same state twice must stay quiet, otherwise every 10s health
// probe would re-push the entire roster to every connected client.
func TestWatchIgnoresRedundantSetState(t *testing.T) {
    r := testRegistry(t, "alpha")
    r.SetState("alpha", StateUp, "")
    ch, cancel := r.Watch()
    defer cancel()
    <-ch // drain initial

    r.SetState("alpha", StateUp, "")

    select {
    case snap := <-ch:
        t.Fatalf("redundant SetState notified: %+v", snap)
    case <-time.After(100 * time.Millisecond):
    }
}

// A detail change (e.g. a new /health detail string) IS a change worth
// pushing — it's what the dashboard and the roster row display.
func TestWatchNotifiesOnDetailChange(t *testing.T) {
    r := testRegistry(t, "alpha")
    r.SetState("alpha", StateDegraded, "camera busy")
    ch, cancel := r.Watch()
    defer cancel()
    <-ch

    r.SetState("alpha", StateDegraded, "camera unavailable")
    select {
    case snap := <-ch:
        if snap[0].Detail != "camera unavailable" {
            t.Fatalf("detail = %q", snap[0].Detail)
        }
    case <-time.After(time.Second):
        t.Fatal("detail change did not notify")
    }
}

// A slow watcher must never block a state transition; the pending snapshot
// is replaced with the newest one instead.
func TestWatchDoesNotBlockOnSlowConsumer(t *testing.T) {
    r := testRegistry(t, "alpha")
    ch, cancel := r.Watch()
    defer cancel()
    // Deliberately do NOT drain. Buffer is 1 and already holds the initial.

    done := make(chan struct{})
    go func() {
        r.SetState("alpha", StateUp, "")
        r.SetState("alpha", StateDown, "exit status 1")
        close(done)
    }()
    select {
    case <-done:
    case <-time.After(time.Second):
        t.Fatal("SetState blocked on a slow watcher")
    }

    // Whatever is buffered must be the newest state, not a stale one.
    snap := <-ch
    if snap[0].State != StateDown {
        t.Fatalf("buffered snapshot = %v, want the newest (down)", snap[0].State)
    }
}

func TestCancelWatchStopsDelivery(t *testing.T) {
    r := testRegistry(t, "alpha")
    ch, cancel := r.Watch()
    <-ch
    cancel()
    cancel() // must be idempotent

    r.SetState("alpha", StateUp, "")
    if _, open := <-ch; open {
        t.Fatal("channel should be closed after cancel")
    }
}

func TestStatCounters(t *testing.T) {
    r := testRegistry(t, "alpha")
    r.CountPublished("alpha")
    r.CountPublished("alpha")
    r.CountDelivered("alpha", 3)
    r.SetProbeLatency("alpha", 12*time.Millisecond)
    r.IncRestarts("alpha")

    s := r.Snapshot()[0]
    if s.EventsPublished != 2 || s.EventsDelivered != 3 {
        t.Errorf("counters = %d published, %d delivered", s.EventsPublished, s.EventsDelivered)
    }
    if s.ProbeLatencyMS != 12 {
        t.Errorf("probe latency = %d ms", s.ProbeLatencyMS)
    }
    if s.Restarts != 1 {
        t.Errorf("restarts = %d", s.Restarts)
    }
    if s.LastEventUnix == 0 {
        t.Error("LastEventUnix should be stamped by CountPublished")
    }
}

// A down plugin has no uptime; reporting one would be a lie on the dashboard.
func TestUptimeOnlyWhileRunning(t *testing.T) {
    r := testRegistry(t, "alpha")
    r.SetState("alpha", StateUp, "")
    time.Sleep(1100 * time.Millisecond)
    if got := r.Snapshot()[0].UptimeSec; got < 1 {
        t.Fatalf("uptime = %d, want >= 1 while up", got)
    }
    r.SetState("alpha", StateDown, "killed")
    if got := r.Snapshot()[0].UptimeSec; got != 0 {
        t.Fatalf("uptime = %d, want 0 while down", got)
    }
}

// Mutations against an unknown id are no-ops rather than panics: the health
// prober and supervisor can race with a plugin being removed.
func TestUnknownIDIsSafe(t *testing.T) {
    r := testRegistry(t)
    r.SetState("ghost", StateUp, "")
    r.SetPort("ghost", 1)
    r.CountPublished("ghost")
    if _, ok := r.State("ghost"); ok {
        t.Fatal("ghost should not exist")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && go test ./kernel/ -run 'Registry|State|Snapshot|Watch|Stat|Uptime|Unknown'`
Expected: FAIL — undefined `NewRegistry`, `State`, etc.

- [ ] **Step 3: Write `backend/kernel/registry.go`**

```go
package kernel

import (
    "sort"
    "sync"
    "time"

    "go.uber.org/zap"
)

// State is a plugin's lifecycle state. degraded is deliberately a visible
// state rather than an internal one: it is where the tab still loads but
// misbehaves, and hiding it would make that indistinguishable from slow.
type State int

const (
    StateStarting State = iota
    StateUp
    StateDegraded
    StateDown
    StateFailed
)

func (s State) String() string {
    switch s {
    case StateStarting:
        return "starting"
    case StateUp:
        return "up"
    case StateDegraded:
        return "degraded"
    case StateDown:
        return "down"
    case StateFailed:
        return "failed"
    }
    return "unknown"
}

// PluginStat is a point-in-time, copy-by-value view of one plugin. It is
// what the roster stream and the status dashboard both render, so it holds
// everything either needs and nothing either would have to ask for.
type PluginStat struct {
    ID     string
    Name   string
    Icon   string
    Path   string
    UI     string
    State  State
    Detail string

    PID             int
    UptimeSec       int64
    Restarts        int
    ProbeLatencyMS  int64
    EventsPublished uint64
    EventsDelivered uint64
    LastEventUnix   int64
}

// plugin is the registry's mutable per-plugin record. Every field is
// guarded by Registry.mu.
type plugin struct {
    manifest Manifest
    state    State
    detail   string
    port     uint32
    pid      int
    since    time.Time // when the current state was entered
    restarts int
    probeMS  int64

    published uint64
    delivered uint64
    lastEvent time.Time
}

type watcher struct {
    ch     chan []PluginStat
    closed bool
}

// Registry is the kernel's plugin table and the single source of the
// roster. Core sits on both the plugin stream and the proxy, so every stat
// here is observed by core itself — no plugin cooperation required.
type Registry struct {
    log *zap.Logger

    mu       sync.Mutex
    plugins  map[string]*plugin
    order    []string // sorted ids, maintained on Add
    watchers map[*watcher]struct{}
}

func NewRegistry(log *zap.Logger) *Registry {
    return &Registry{
        log:      log,
        plugins:  map[string]*plugin{},
        watchers: map[*watcher]struct{}{},
    }
}

// Add registers a discovered manifest. New plugins start in StateStarting:
// they have been discovered but have not yet completed the Register
// handshake.
func (r *Registry) Add(m Manifest) {
    r.mu.Lock()
    defer r.mu.Unlock()
    if _, exists := r.plugins[m.ID]; exists {
        return
    }
    r.plugins[m.ID] = &plugin{manifest: m, state: StateStarting, since: time.Now()}
    r.order = append(r.order, m.ID)
    sort.Strings(r.order)
}

func (r *Registry) Manifests() []Manifest {
    r.mu.Lock()
    defer r.mu.Unlock()
    out := make([]Manifest, 0, len(r.order))
    for _, id := range r.order {
        out = append(out, r.plugins[id].manifest)
    }
    return out
}

func (r *Registry) Manifest(id string) (Manifest, bool) {
    r.mu.Lock()
    defer r.mu.Unlock()
    p, ok := r.plugins[id]
    if !ok {
        return Manifest{}, false
    }
    return p.manifest, true
}

// SetState transitions a plugin and fans the whole roster out to watchers.
// A no-op transition (same state, same detail) stays quiet — otherwise
// every successful 10s health probe would re-push the roster to every
// connected client.
func (r *Registry) SetState(id string, s State, detail string) {
    r.mu.Lock()
    p, ok := r.plugins[id]
    if !ok {
        r.mu.Unlock()
        return
    }
    if p.state == s && p.detail == detail {
        r.mu.Unlock()
        return
    }
    if p.state != s {
        p.since = time.Now()
    }
    p.state, p.detail = s, detail
    snap := r.snapshotLocked()
    r.notifyLocked(snap)
    r.mu.Unlock()

    r.log.Info("plugin state", zap.String("plugin", id), zap.String("state", s.String()), zap.String("detail", detail))
}

func (r *Registry) State(id string) (State, bool) {
    r.mu.Lock()
    defer r.mu.Unlock()
    p, ok := r.plugins[id]
    if !ok {
        return StateStarting, false
    }
    return p.state, true
}

func (r *Registry) SetPort(id string, port uint32) { r.mutate(id, func(p *plugin) { p.port = port }) }

func (r *Registry) Port(id string) (uint32, bool) {
    r.mu.Lock()
    defer r.mu.Unlock()
    p, ok := r.plugins[id]
    if !ok || p.port == 0 {
        return 0, false
    }
    return p.port, true
}

func (r *Registry) SetProcess(id string, pid int) { r.mutate(id, func(p *plugin) { p.pid = pid }) }
func (r *Registry) IncRestarts(id string)         { r.mutate(id, func(p *plugin) { p.restarts++ }) }

func (r *Registry) SetProbeLatency(id string, d time.Duration) {
    r.mutate(id, func(p *plugin) { p.probeMS = d.Milliseconds() })
}

func (r *Registry) CountPublished(id string) {
    r.mutate(id, func(p *plugin) { p.published++; p.lastEvent = time.Now() })
}

func (r *Registry) CountDelivered(id string, n int) {
    r.mutate(id, func(p *plugin) { p.delivered += uint64(n) })
}

// mutate applies fn under the lock. Stat mutations deliberately do NOT
// notify watchers: counters change constantly and the roster is a
// state-change stream, not a metrics feed. The dashboard polls Snapshot
// instead.
func (r *Registry) mutate(id string, fn func(*plugin)) {
    r.mu.Lock()
    defer r.mu.Unlock()
    if p, ok := r.plugins[id]; ok {
        fn(p)
    }
}

func (r *Registry) Snapshot() []PluginStat {
    r.mu.Lock()
    defer r.mu.Unlock()
    return r.snapshotLocked()
}

func (r *Registry) snapshotLocked() []PluginStat {
    out := make([]PluginStat, 0, len(r.order))
    for _, id := range r.order {
        p := r.plugins[id]
        st := PluginStat{
            ID:              p.manifest.ID,
            Name:            p.manifest.Name,
            Icon:            p.manifest.Icon,
            UI:              p.manifest.UI,
            Path:            "/p/" + p.manifest.ID + "/",
            State:           p.state,
            Detail:          p.detail,
            PID:             p.pid,
            Restarts:        p.restarts,
            ProbeLatencyMS:  p.probeMS,
            EventsPublished: p.published,
            EventsDelivered: p.delivered,
        }
        if p.state == StateUp || p.state == StateDegraded {
            st.UptimeSec = int64(time.Since(p.since).Seconds())
        }
        if !p.lastEvent.IsZero() {
            st.LastEventUnix = p.lastEvent.Unix()
        }
        out = append(out, st)
    }
    return out
}

// Watch returns a channel that receives the current roster immediately and
// a fresh full roster on every state change. The roster is small and
// changes rarely, so there is no need for deltas.
func (r *Registry) Watch() (<-chan []PluginStat, func()) {
    w := &watcher{ch: make(chan []PluginStat, 1)}

    r.mu.Lock()
    r.watchers[w] = struct{}{}
    w.ch <- r.snapshotLocked()
    r.mu.Unlock()

    var once sync.Once
    cancel := func() {
        once.Do(func() {
            r.mu.Lock()
            defer r.mu.Unlock()
            delete(r.watchers, w)
            w.closed = true
            close(w.ch)
        })
    }
    return w.ch, cancel
}

// notifyLocked pushes snap to every watcher without ever blocking. A full
// buffer means the watcher hasn't drained the previous roster yet; that
// stale roster is discarded in favour of this newer one, because a client
// only ever cares about the current state of the world.
func (r *Registry) notifyLocked(snap []PluginStat) {
    for w := range r.watchers {
        if w.closed {
            continue
        }
        select {
        case w.ch <- snap:
        default:
            select {
            case <-w.ch:
            default:
            }
            select {
            case w.ch <- snap:
            default:
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && go test ./kernel/ -race -v`
Expected: PASS. `-race` matters here — `Watch`/`SetState`/`Snapshot` are the kernel's most concurrent surface.

- [ ] **Step 5: Commit**

```bash
git add backend/kernel/registry.go backend/kernel/registry_test.go
git commit -m "feat(kernel): plugin registry with state machine and roster fan-out"
```

---

### Task 4: Bus — topic fan-out, publish authorization, demand refcount

**Files:**
- Create: `backend/kernel/bus.go`
- Test: `backend/kernel/bus_test.go`

**Interfaces:**
- Consumes: nothing from other tasks (takes plain strings).
- Produces:
  ```go
  // TopicDemand is the reserved core-originated topic carrying subscriber
  // counts back to a publisher. Payload is JSON: DemandPayload.
  const TopicDemand = "_core.demand.v1"
  const reservedPrefix = "_core."

  type BusEvent struct {
      Topic   string
      Payload []byte
      TS      time.Time
  }

  type DemandPayload struct {
      Topic       string `json:"topic"`
      Subscribers int    `json:"subscribers"`
  }

  type Bus struct{ /* unexported */ }
  func NewBus(log *zap.Logger) *Bus
  func (b *Bus) Declare(pluginID string, subscribes, publishes []string)
  func (b *Bus) Subscribe(pluginID string) (<-chan BusEvent, func())
  func (b *Bus) Publish(pluginID, topic string, payload []byte, ts time.Time) (delivered int, err error)
  func (b *Bus) Demand(topic string) int
  func (b *Bus) OnDelivered(fn func(pluginID string, n int))
  ```

Design notes for the implementer:

- **Declare comes from the manifest, before any plugin connects.** `Declare` records both sides for a plugin id. It does *not* create channels. `Subscribe` (called when the plugin's Register stream opens) creates the channel and wires it to every topic that plugin declared in `subscribes`.
- **Publishing an undeclared topic is an error and a dropped message** — manifests stay honest. Return the error so `rpc.Publish` can log it; do not deliver.
- **`_core.` is reserved.** A plugin publishing any `_core.*` topic gets an error. Core delivers `_core.demand.v1` to a plugin *without* it being declared in that plugin's `subscribes`.
- **Slow subscribers are dropped, not buffered.** Channels are buffered (cap 64); a full channel means the event is discarded with a warn log. Fire-and-forget, no persistence, no replay, no delivery guarantee.
- **Demand refcounting is the privacy mechanism.** When a subscriber for topic T appears or disappears, the bus computes the new count and delivers a `_core.demand.v1` event to whichever plugin *declares T in its `publishes`*. Zero subscribers is how a provider knows to close its capture session. This lives in core rather than each provider precisely so it is a mechanism, not a policy.
- **`OnDelivered`** is the hook the registry uses to count `EventsDelivered` without the bus importing the registry (keeps bus.go dependency-free and D10-clean).

- [ ] **Step 1: Write the failing tests**

```go
package kernel

import (
    "encoding/json"
    "testing"
    "time"

    "go.uber.org/zap"
)

func recvEvent(t *testing.T, ch <-chan BusEvent) BusEvent {
    t.Helper()
    select {
    case e := <-ch:
        return e
    case <-time.After(time.Second):
        t.Fatal("timed out waiting for bus event")
        return BusEvent{}
    }
}

func expectNoEvent(t *testing.T, ch <-chan BusEvent) {
    t.Helper()
    select {
    case e := <-ch:
        t.Fatalf("unexpected event %q", e.Topic)
    case <-time.After(100 * time.Millisecond):
    }
}

func TestPublishDeliversToSubscriber(t *testing.T) {
    b := NewBus(zap.NewNop())
    b.Declare("sensor", nil, []string{"sensor.landmarks.v1"})
    b.Declare("consumer", []string{"sensor.landmarks.v1"}, nil)

    ch, cancel := b.Subscribe("consumer")
    defer cancel()

    ts := time.Unix(1700000000, 0)
    n, err := b.Publish("sensor", "sensor.landmarks.v1", []byte("frame"), ts)
    if err != nil || n != 1 {
        t.Fatalf("Publish = %d, %v; want 1, nil", n, err)
    }

    e := recvEvent(t, ch)
    if e.Topic != "sensor.landmarks.v1" || string(e.Payload) != "frame" || !e.TS.Equal(ts) {
        t.Fatalf("event = %+v", e)
    }
}

func TestPublishFansOutToAllSubscribers(t *testing.T) {
    b := NewBus(zap.NewNop())
    b.Declare("sensor", nil, []string{"t.v1"})
    b.Declare("a", []string{"t.v1"}, nil)
    b.Declare("bee", []string{"t.v1"}, nil)

    chA, cancelA := b.Subscribe("a")
    defer cancelA()
    chB, cancelB := b.Subscribe("bee")
    defer cancelB()

    n, _ := b.Publish("sensor", "t.v1", []byte("x"), time.Now())
    if n != 2 {
        t.Fatalf("delivered to %d, want 2", n)
    }
    recvEvent(t, chA)
    recvEvent(t, chB)
}

// Manifests stay honest: publishing a topic you didn't declare is an error
// and the message is dropped, not delivered.
func TestPublishUndeclaredTopicIsRejected(t *testing.T) {
    b := NewBus(zap.NewNop())
    b.Declare("sensor", nil, []string{"declared.v1"})
    b.Declare("consumer", []string{"sneaky.v1"}, nil)
    ch, cancel := b.Subscribe("consumer")
    defer cancel()

    n, err := b.Publish("sensor", "sneaky.v1", []byte("x"), time.Now())
    if err == nil {
        t.Fatal("expected error publishing an undeclared topic")
    }
    if n != 0 {
        t.Fatalf("delivered %d, want 0", n)
    }
    expectNoEvent(t, ch)
}

func TestPluginCannotPublishReservedTopics(t *testing.T) {
    b := NewBus(zap.NewNop())
    b.Declare("evil", nil, []string{TopicDemand})
    if _, err := b.Publish("evil", TopicDemand, []byte("{}"), time.Now()); err == nil {
        t.Fatal("plugins must not be able to publish _core.* topics")
    }
}

// A plugin that subscribes to a topic nobody publishes simply receives
// nothing — cross-plugin coupling is always an enhancement gated on
// presence, never a requirement.
func TestSubscribeToUnpublishedTopicIsSilent(t *testing.T) {
    b := NewBus(zap.NewNop())
    b.Declare("lonely", []string{"nobody.publishes.v1"}, nil)
    ch, cancel := b.Subscribe("lonely")
    defer cancel()
    expectNoEvent(t, ch)
}

func TestUnsubscribeStopsDelivery(t *testing.T) {
    b := NewBus(zap.NewNop())
    b.Declare("pub", nil, []string{"t.v1"})
    b.Declare("sub", []string{"t.v1"}, nil)
    ch, cancel := b.Subscribe("sub")
    cancel()
    cancel() // idempotent

    n, _ := b.Publish("pub", "t.v1", []byte("x"), time.Now())
    if n != 0 {
        t.Fatalf("delivered %d after unsubscribe", n)
    }
    if _, open := <-ch; open {
        t.Fatal("channel should be closed after cancel")
    }
}

// The provider must idle — camera closed, LED off — when nothing
// subscribes. It learns that from _core.demand.v1, which core delivers
// without the provider declaring it.
func TestDemandDeliveredToPublisherOnSubscribeAndUnsubscribe(t *testing.T) {
    b := NewBus(zap.NewNop())
    b.Declare("sensor", nil, []string{"sensor.landmarks.v1"})
    b.Declare("consumer", []string{"sensor.landmarks.v1"}, nil)

    sensorCh, cancelSensor := b.Subscribe("sensor")
    defer cancelSensor()

    // Demand starts at zero and is announced when the provider connects, so
    // a provider that starts before any consumer knows to stay idle.
    e := recvEvent(t, sensorCh)
    var d DemandPayload
    if e.Topic != TopicDemand {
        t.Fatalf("first event = %q, want %q", e.Topic, TopicDemand)
    }
    if err := json.Unmarshal(e.Payload, &d); err != nil {
        t.Fatal(err)
    }
    if d.Topic != "sensor.landmarks.v1" || d.Subscribers != 0 {
        t.Fatalf("initial demand = %+v, want 0 subscribers", d)
    }

    _, cancelConsumer := b.Subscribe("consumer")

    e = recvEvent(t, sensorCh)
    json.Unmarshal(e.Payload, &d)
    if d.Subscribers != 1 {
        t.Fatalf("demand after subscribe = %d, want 1", d.Subscribers)
    }

    cancelConsumer()

    e = recvEvent(t, sensorCh)
    json.Unmarshal(e.Payload, &d)
    if d.Subscribers != 0 {
        t.Fatalf("demand after unsubscribe = %d, want 0", d.Subscribers)
    }
}

func TestDemandCount(t *testing.T) {
    b := NewBus(zap.NewNop())
    b.Declare("pub", nil, []string{"t.v1"})
    b.Declare("a", []string{"t.v1"}, nil)
    b.Declare("bee", []string{"t.v1"}, nil)

    if got := b.Demand("t.v1"); got != 0 {
        t.Fatalf("demand = %d, want 0", got)
    }
    _, ca := b.Subscribe("a")
    _, cb := b.Subscribe("bee")
    if got := b.Demand("t.v1"); got != 2 {
        t.Fatalf("demand = %d, want 2", got)
    }
    ca()
    cb()
    if got := b.Demand("t.v1"); got != 0 {
        t.Fatalf("demand = %d, want 0", got)
    }
}

// Fire-and-forget: a subscriber that stops reading is dropped rather than
// buffered without bound, and must not stall the publisher.
func TestSlowSubscriberIsDroppedNotBuffered(t *testing.T) {
    b := NewBus(zap.NewNop())
    b.Declare("pub", nil, []string{"t.v1"})
    b.Declare("slow", []string{"t.v1"}, nil)
    _, cancel := b.Subscribe("slow")
    defer cancel()

    done := make(chan struct{})
    go func() {
        for i := 0; i < 5000; i++ {
            b.Publish("pub", "t.v1", []byte("x"), time.Now())
        }
        close(done)
    }()
    select {
    case <-done:
    case <-time.After(5 * time.Second):
        t.Fatal("publisher blocked on a subscriber that never reads")
    }
}

func TestOnDeliveredHook(t *testing.T) {
    b := NewBus(zap.NewNop())
    got := map[string]int{}
    b.OnDelivered(func(id string, n int) { got[id] += n })

    b.Declare("pub", nil, []string{"t.v1"})
    b.Declare("sub", []string{"t.v1"}, nil)
    _, cancel := b.Subscribe("sub")
    defer cancel()

    b.Publish("pub", "t.v1", []byte("x"), time.Now())
    time.Sleep(50 * time.Millisecond)
    if got["sub"] != 1 {
        t.Fatalf("OnDelivered saw %v, want sub=1", got)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && go test ./kernel/ -run 'Bus|Publish|Subscribe|Demand|Slow|OnDelivered|Unsubscribe|Plugin'`
Expected: FAIL — undefined `NewBus`.

- [ ] **Step 3: Write `backend/kernel/bus.go`**

```go
package kernel

import (
    "encoding/json"
    "fmt"
    "strings"
    "sync"
    "time"

    "go.uber.org/zap"
)

// reservedPrefix marks topics core itself originates. Plugins may not
// publish them, and core delivers them to the relevant plugin without the
// plugin declaring them in its manifest.
const reservedPrefix = "_core."

// TopicDemand carries the current subscriber count for one of a plugin's
// published topics back to that plugin. A provider that sees zero
// subscribers must close its capture session — this is a privacy property
// enforced by mechanism, which is exactly why the refcount lives in core
// rather than in each provider.
const TopicDemand = reservedPrefix + "demand.v1"

// DemandPayload is the JSON body of a TopicDemand event.
type DemandPayload struct {
    Topic       string `json:"topic"`
    Subscribers int    `json:"subscribers"`
}

// BusEvent is one delivery. Events are ephemeral: no persistence, no
// replay, no delivery guarantee.
type BusEvent struct {
    Topic   string
    Payload []byte
    TS      time.Time
}

// subChanCap bounds a subscriber's queue. Beyond it, events are dropped
// rather than buffered without bound — a slow subscriber must never become
// the publisher's problem.
const subChanCap = 64

type subscriber struct {
    id     string
    topics []string
    ch     chan BusEvent
    closed bool
}

// Bus is topic -> subscriber channels, in memory, fire-and-forget. It is
// the one mechanism with no alternative: cross-plugin communication is bus
// topics only, never the filesystem.
type Bus struct {
    log *zap.Logger

    mu         sync.Mutex
    subscribes map[string][]string // plugin id -> topics it subscribes to
    publishes  map[string][]string // plugin id -> topics it may publish
    subs       map[string]*subscriber
    byTopic    map[string]map[string]*subscriber // topic -> id -> subscriber

    onDelivered func(pluginID string, n int)
}

func NewBus(log *zap.Logger) *Bus {
    return &Bus{
        log:        log,
        subscribes: map[string][]string{},
        publishes:  map[string][]string{},
        subs:       map[string]*subscriber{},
        byTopic:    map[string]map[string]*subscriber{},
    }
}

// Declare records a plugin's manifest-declared topics. Subscriptions come
// from the manifest, not an RPC, so core knows what to deliver before the
// plugin ever connects.
func (b *Bus) Declare(pluginID string, subscribes, publishes []string) {
    b.mu.Lock()
    defer b.mu.Unlock()
    b.subscribes[pluginID] = append([]string(nil), subscribes...)
    b.publishes[pluginID] = append([]string(nil), publishes...)
}

// OnDelivered installs a counter hook. It exists so the registry can count
// deliveries without the bus needing to know the registry exists.
func (b *Bus) OnDelivered(fn func(pluginID string, n int)) {
    b.mu.Lock()
    defer b.mu.Unlock()
    b.onDelivered = fn
}

// Subscribe attaches a plugin's Register stream to the bus. It returns the
// event channel and an idempotent unsubscribe func.
//
// Every subscriber also receives TopicDemand events for the topics IT
// publishes — including one immediately, so a provider that starts before
// any consumer learns to stay idle rather than assuming demand.
func (b *Bus) Subscribe(pluginID string) (<-chan BusEvent, func()) {
    b.mu.Lock()
    s := &subscriber{
        id:     pluginID,
        topics: append([]string(nil), b.subscribes[pluginID]...),
        ch:     make(chan BusEvent, subChanCap),
    }
    b.subs[pluginID] = s
    for _, t := range s.topics {
        if b.byTopic[t] == nil {
            b.byTopic[t] = map[string]*subscriber{}
        }
        b.byTopic[t][pluginID] = s
    }
    affected := append([]string(nil), s.topics...)
    own := append([]string(nil), b.publishes[pluginID]...)
    b.mu.Unlock()

    // Announce this plugin's own publish demand first (so a just-connected
    // provider immediately knows the count), then the change its arrival
    // caused for whoever publishes the topics it subscribes to.
    b.announceDemand(own)
    b.announceDemand(affected)

    var once sync.Once
    cancel := func() {
        once.Do(func() {
            b.mu.Lock()
            if cur, ok := b.subs[pluginID]; ok && cur == s {
                delete(b.subs, pluginID)
            }
            for _, t := range s.topics {
                delete(b.byTopic[t], pluginID)
                if len(b.byTopic[t]) == 0 {
                    delete(b.byTopic, t)
                }
            }
            s.closed = true
            close(s.ch)
            b.mu.Unlock()
            b.announceDemand(affected)
        })
    }
    return s.ch, cancel
}

// Publish delivers to every subscriber of topic and returns how many got
// it. An undeclared or reserved topic is refused and nothing is delivered.
func (b *Bus) Publish(pluginID, topic string, payload []byte, ts time.Time) (int, error) {
    if strings.HasPrefix(topic, reservedPrefix) {
        return 0, fmt.Errorf("plugin %q may not publish reserved topic %q", pluginID, topic)
    }
    b.mu.Lock()
    declared := false
    for _, t := range b.publishes[pluginID] {
        if t == topic {
            declared = true
            break
        }
    }
    b.mu.Unlock()
    if !declared {
        return 0, fmt.Errorf("plugin %q publishes undeclared topic %q", pluginID, topic)
    }
    return b.deliver(topic, BusEvent{Topic: topic, Payload: payload, TS: ts}), nil
}

// deliver is the non-blocking fan-out. It snapshots the subscriber set
// under the lock and sends outside it, so a send can never be holding the
// bus lock.
func (b *Bus) deliver(topic string, e BusEvent) int {
    b.mu.Lock()
    targets := make([]*subscriber, 0, len(b.byTopic[topic]))
    for _, s := range b.byTopic[topic] {
        targets = append(targets, s)
    }
    hook := b.onDelivered
    b.mu.Unlock()

    n := 0
    for _, s := range targets {
        select {
        case s.ch <- e:
            n++
            if hook != nil {
                hook(s.id, 1)
            }
        default:
            b.log.Warn("dropping event for slow subscriber",
                zap.String("plugin", s.id), zap.String("topic", topic))
        }
    }
    return n
}

// announceDemand sends the current subscriber count for each topic to
// whichever plugin declares that topic in its publishes.
func (b *Bus) announceDemand(topics []string) {
    for _, topic := range topics {
        b.mu.Lock()
        count := len(b.byTopic[topic])
        var publisher *subscriber
        for id, pubTopics := range b.publishes {
            for _, t := range pubTopics {
                if t == topic {
                    publisher = b.subs[id]
                    break
                }
            }
            if publisher != nil {
                break
            }
        }
        b.mu.Unlock()

        if publisher == nil {
            continue // provider not connected; it gets the count on Subscribe
        }
        payload, err := json.Marshal(DemandPayload{Topic: topic, Subscribers: count})
        if err != nil {
            continue
        }
        e := BusEvent{Topic: TopicDemand, Payload: payload, TS: time.Now()}
        select {
        case publisher.ch <- e:
        default:
            b.log.Warn("dropping demand event for slow publisher",
                zap.String("plugin", publisher.id), zap.String("topic", topic))
        }
    }
}

// Demand reports the current subscriber count for a topic.
func (b *Bus) Demand(topic string) int {
    b.mu.Lock()
    defer b.mu.Unlock()
    return len(b.byTopic[topic])
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && go test ./kernel/ -race -v`
Expected: PASS, all eleven tests.

- [ ] **Step 5: Commit**

```bash
git add backend/kernel/bus.go backend/kernel/bus_test.go
git commit -m "feat(kernel): event bus with publish authorization and demand refcount"
```

---

### Task 5: Supervisor — spawn, registration timeout, backoff restart, shutdown

**Files:**
- Create: `backend/kernel/supervisor.go`
- Test: `backend/kernel/supervisor_test.go`

**Interfaces:**
- Consumes: `Registry` (Task 3), `Manifest` (Task 2).
- Produces:
  ```go
  const (
      registrationTimeout = 10 * time.Second
      shutdownGrace       = 5 * time.Second
      stableUptime        = 60 * time.Second
      maxFailedStarts     = 5
  )

  type Supervisor struct{ /* unexported */ }
  func NewSupervisor(reg *Registry, socketPath, dataRoot string, log *zap.Logger) *Supervisor
  func (s *Supervisor) Start(ctx context.Context)      // one supervision goroutine per plugin
  func (s *Supervisor) NotifyRegistered(id string)     // called by rpc.Register
  func (s *Supervisor) Restart(id string) error        // manual, recovers from failed
  func (s *Supervisor) Stop(ctx context.Context)       // SIGTERM then SIGKILL after shutdownGrace
  func backoffDelay(consecutiveFailures int) time.Duration
  ```

Design notes for the implementer:

- **One goroutine per plugin.** It owns that plugin's whole lifecycle: spawn → wait for registration → wait for exit → decide → sleep backoff → repeat. All the state machine's ordering lives in that single loop, so nothing needs cross-goroutine coordination beyond the registry.
- **`stopping` vs. a crash.** `Stop` and `Restart` both kill the process; the loop must distinguish an intentional kill (do not count as a failed start) from a crash (do).
- **The failure counter resets after `stableUptime`.** A plugin that ran for 60s and then died is not "failing to start" — it is crashing in service, and it gets the full backoff ladder again from 1s.
- **Manual restart resets the counter to zero and works from `failed`.** That is the entire point of the dashboard's restart button.
- **`degraded` is never auto-restarted.** The supervisor only reacts to process exit; the health prober never asks it to kill anything. A degraded plugin's process is alive and may hold unflushed state, so killing it is the user's call.
- Timeout constants are package-level `var` (not `const`) so tests can shrink them — declare them as `var` with the spec values as defaults.

> **Corrections applied while executing this task — the code below is the starting point, not the shipped shape.** Review found four defects in it; the committed `supervisor.go` fixes all four and is authoritative.
>
> 1. **Never signal a reaped pid.** `ps.pid` below is written once and never cleared when `cmd.Wait()` reaps the child, while `ps` stays in `s.procs` forever — so `Restart` on a parked plugin, or `Stop` on one mid-backoff, issues `syscall.Kill(-reusedPid, …)` against whatever process now owns that pid, fanned out to its whole group. Guard every signal on a non-closed `ps.exited` and zero `ps.pid` under the mutex after `Wait` returns. `-race` cannot catch this: signaling a dead pid returns `ESRCH`, which `_ =` discards.
> 2. **`NotifyRegistered` must close under the lock.** The check-then-close below runs unsynchronized; two `Register` calls for one id — routine, since the SDK reconnects — double-close and panic core.
> 3. **`runOnce` must honour `ctx`.** As written it ignores cancellation entirely, so cancelling `Start`'s context terminates nothing and leaks every child. `Stop` remains the graceful path; cancellation is the abrupt one, and both share the reaped-pid guard.
> 4. **`Stop`'s data race on `cmd.Process`.** `Stop` reads it while `runOnce`'s `cmd.Start()` writes it. Publish a lock-guarded pid instead, and have `runOnce` re-check `stopped` after a successful `Start` so a process spawned during shutdown self-terminates.
>
> `TestStopKillsUnresponsivePlugin` below is also vacuous: `trap '' TERM` protects only the shell, so the group-directed SIGTERM kills the untrapped `sleep` and the script exits inside the grace window without ever exercising SIGKILL. The shipped test uses a busy loop with no signal-killable child and asserts `Stop` returned only after the grace period elapsed.

- [ ] **Step 1: Write the failing tests**

```go
package kernel

import (
    "context"
    "os"
    "path/filepath"
    "strings"
    "testing"
    "time"

    "go.uber.org/zap"
)

// writeScript creates an executable shell script inside dir and returns the
// relative exec path a manifest would use.
func writeScript(t *testing.T, dir, body string) string {
    t.Helper()
    p := filepath.Join(dir, "plugin.sh")
    if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
        t.Fatal(err)
    }
    return "./plugin.sh"
}

// newSup builds a supervisor over a single script-backed plugin and returns
// it along with the registry and the plugin's directory.
func newSup(t *testing.T, id, body string) (*Supervisor, *Registry, string) {
    t.Helper()
    root := t.TempDir()
    dir := filepath.Join(root, id)
    if err := os.MkdirAll(dir, 0o755); err != nil {
        t.Fatal(err)
    }
    exec := writeScript(t, dir, body)

    reg := NewRegistry(zap.NewNop())
    reg.Add(Manifest{ID: id, Name: id, Exec: exec, UI: "webview", Dir: dir})

    s := NewSupervisor(reg, filepath.Join(root, "core.sock"), filepath.Join(root, "data"), zap.NewNop())
    return s, reg, dir
}

// waitState polls until the plugin reaches want, or fails the test.
func waitState(t *testing.T, reg *Registry, id string, want State, within time.Duration) {
    t.Helper()
    deadline := time.Now().Add(within)
    for time.Now().Before(deadline) {
        if got, _ := reg.State(id); got == want {
            return
        }
        time.Sleep(10 * time.Millisecond)
    }
    got, _ := reg.State(id)
    t.Fatalf("state = %v after %v, want %v", got, within, want)
}

func TestBackoffDelay(t *testing.T) {
    want := []time.Duration{
        time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second,
        16 * time.Second, 32 * time.Second, 60 * time.Second, 60 * time.Second,
    }
    for i, w := range want {
        if got := backoffDelay(i + 1); got != w {
            t.Errorf("backoffDelay(%d) = %v, want %v", i+1, got, w)
        }
    }
    if got := backoffDelay(0); got != time.Second {
        t.Errorf("backoffDelay(0) = %v, want 1s (defensive floor)", got)
    }
}

// The three spawn env vars and the working directory are the entire
// contract between core and a plugin process.
func TestSpawnEnvironmentAndWorkingDir(t *testing.T) {
    s, _, dir := newSup(t, "alpha", `
env | grep '^VIBECARE_' | sort > "$PWD/env.txt"
pwd > "$PWD/cwd.txt"
sleep 30
`)
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    s.Start(ctx)
    defer s.Stop(context.Background())

    envPath := filepath.Join(dir, "env.txt")
    deadline := time.Now().Add(3 * time.Second)
    for time.Now().Before(deadline) {
        if _, err := os.Stat(envPath); err == nil {
            break
        }
        time.Sleep(10 * time.Millisecond)
    }
    b, err := os.ReadFile(envPath)
    if err != nil {
        t.Fatalf("plugin never ran: %v", err)
    }
    got := string(b)
    for _, want := range []string{"VIBECARE_PLUGIN_ID=alpha", "VIBECARE_SOCKET=", "VIBECARE_DATA_DIR="} {
        if !strings.Contains(got, want) {
            t.Errorf("env missing %q; got:\n%s", want, got)
        }
    }
    if strings.Count(got, "VIBECARE_") != 3 {
        t.Errorf("expected exactly 3 VIBECARE_ vars, got:\n%s", got)
    }

    cwd, err := os.ReadFile(filepath.Join(dir, "cwd.txt"))
    if err != nil {
        t.Fatal(err)
    }
    // macOS resolves TempDir through /private; compare resolved paths.
    wantDir, _ := filepath.EvalSymlinks(dir)
    gotDir, _ := filepath.EvalSymlinks(strings.TrimSpace(string(cwd)))
    if gotDir != wantDir {
        t.Errorf("cwd = %q, want the plugin's own directory %q", gotDir, wantDir)
    }
}

// Core creates the data dir BEFORE spawning, so a plugin can open its store
// on the first line of main without checking.
func TestDataDirCreatedBeforeSpawn(t *testing.T) {
    s, _, dir := newSup(t, "alpha", `
[ -d "$VIBECARE_DATA_DIR" ] && echo yes > "$PWD/ok.txt"
sleep 30
`)
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    s.Start(ctx)
    defer s.Stop(context.Background())

    deadline := time.Now().Add(3 * time.Second)
    for time.Now().Before(deadline) {
        if b, err := os.ReadFile(filepath.Join(dir, "ok.txt")); err == nil && strings.TrimSpace(string(b)) == "yes" {
            return
        }
        time.Sleep(10 * time.Millisecond)
    }
    t.Fatal("VIBECARE_DATA_DIR did not exist when the plugin started")
}

// A plugin that never calls Register is wedged, not merely slow. It is
// killed and the attempt counts as a failed start.
func TestRegistrationTimeoutKillsPlugin(t *testing.T) {
    s, reg, _ := newSup(t, "alpha", "sleep 60")
    registrationTimeout = 200 * time.Millisecond
    // The backoff ladder must be shrunk too: at the 1s default, five failed
    // starts cost 1+2+4+8 = 15s of sleeps on top of the five timeouts, which
    // alone exceeds this test's deadline.
    backoffScale = time.Millisecond
    t.Cleanup(func() {
        registrationTimeout = 10 * time.Second
        backoffScale = time.Second
    })

    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    s.Start(ctx)
    defer s.Stop(context.Background())

    // Never registers -> killed -> restarted -> killed ... -> failed.
    waitState(t, reg, "alpha", StateFailed, 15*time.Second)
    if got := reg.Snapshot()[0].Restarts; got < maxFailedStarts-1 {
        t.Errorf("restarts = %d, want at least %d before failing", got, maxFailedStarts-1)
    }
}

// NotifyRegistered is what cancels the timeout; a registered plugin is left
// alone even though the script does nothing but sleep.
func TestRegisteredPluginIsNotKilled(t *testing.T) {
    s, reg, _ := newSup(t, "alpha", "sleep 30")
    registrationTimeout = 200 * time.Millisecond
    t.Cleanup(func() { registrationTimeout = 10 * time.Second })

    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    s.Start(ctx)
    defer s.Stop(context.Background())

    time.Sleep(50 * time.Millisecond)
    s.NotifyRegistered("alpha")
    reg.SetState("alpha", StateUp, "")

    time.Sleep(600 * time.Millisecond)
    if got, _ := reg.State("alpha"); got != StateUp {
        t.Fatalf("state = %v, want the registered plugin left running", got)
    }
}

// Five consecutive bad starts stop the ladder: the plugin is marked failed,
// stays visible in the roster with its exit reason, and is not restarted
// automatically.
func TestFailedAfterMaxBadStarts(t *testing.T) {
    s, reg, _ := newSup(t, "alpha", "exit 3")
    backoffScale = time.Millisecond // 1ms,2ms,4ms... instead of 1s,2s,4s
    t.Cleanup(func() { backoffScale = time.Second })

    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    s.Start(ctx)
    defer s.Stop(context.Background())

    waitState(t, reg, "alpha", StateFailed, 10*time.Second)
    if d := reg.Snapshot()[0].Detail; !strings.Contains(d, "3") {
        t.Errorf("detail = %q, want it to carry the exit reason", d)
    }
}

// The dashboard's restart button must work from failed — that is how a
// failed plugin becomes recoverable without restarting core.
func TestManualRestartRecoversFromFailed(t *testing.T) {
    s, reg, dir := newSup(t, "alpha", "exit 3")
    backoffScale = time.Millisecond
    t.Cleanup(func() { backoffScale = time.Second })

    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    s.Start(ctx)
    defer s.Stop(context.Background())
    waitState(t, reg, "alpha", StateFailed, 10*time.Second)

    // Fix the plugin, then restart it by hand.
    writeScript(t, dir, "sleep 30")
    if err := s.Restart("alpha"); err != nil {
        t.Fatalf("Restart: %v", err)
    }
    waitState(t, reg, "alpha", StateStarting, 3*time.Second)
}

func TestRestartUnknownPluginErrors(t *testing.T) {
    s, _, _ := newSup(t, "alpha", "sleep 30")
    if err := s.Restart("ghost"); err == nil {
        t.Fatal("expected an error restarting an unknown plugin")
    }
}

// Stop must terminate a plugin that ignores SIGTERM, within the grace
// period, rather than hanging core's shutdown.
func TestStopKillsUnresponsivePlugin(t *testing.T) {
    s, reg, _ := newSup(t, "alpha", `
trap '' TERM
sleep 60
`)
    shutdownGrace = 300 * time.Millisecond
    t.Cleanup(func() { shutdownGrace = 5 * time.Second })

    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    s.Start(ctx)
    time.Sleep(200 * time.Millisecond)

    done := make(chan struct{})
    go func() { s.Stop(context.Background()); close(done) }()
    select {
    case <-done:
    case <-time.After(5 * time.Second):
        t.Fatal("Stop hung on a plugin that ignores SIGTERM")
    }
    if got, _ := reg.State("alpha"); got == StateUp {
        t.Errorf("state = %v after Stop", got)
    }
}

// After Stop, a plugin exit must NOT trigger the restart ladder.
func TestStopPreventsRestart(t *testing.T) {
    s, reg, _ := newSup(t, "alpha", "sleep 30")
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    s.Start(ctx)
    time.Sleep(200 * time.Millisecond)
    s.Stop(context.Background())

    before := reg.Snapshot()[0].Restarts
    time.Sleep(500 * time.Millisecond)
    if after := reg.Snapshot()[0].Restarts; after != before {
        t.Fatalf("restarts went %d -> %d after Stop", before, after)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && go test ./kernel/ -run 'Backoff|Spawn|DataDir|Registration|Registered|Failed|Restart|Stop'`
Expected: FAIL — undefined `NewSupervisor`, `backoffDelay`, `backoffScale`.

- [ ] **Step 3: Write `backend/kernel/supervisor.go`**

```go
package kernel

import (
    "context"
    "fmt"
    "os"
    "os/exec"
    "path/filepath"
    "sync"
    "syscall"
    "time"

    "go.uber.org/zap"
)

// Lifecycle timings. These are vars rather than consts purely so tests can
// shrink them; the values here are the contract.
var (
    // registrationTimeout is how long a plugin has to call Register after
    // being spawned before core concludes it is wedged and kills it.
    registrationTimeout = 10 * time.Second
    // shutdownGrace is how long a plugin has between SIGTERM and SIGKILL.
    shutdownGrace = 5 * time.Second
    // stableUptime is how long a plugin must stay up before its failed-start
    // counter resets. Past this, a death is a crash in service, not a
    // failure to start, and it earns the full backoff ladder again.
    stableUptime = 60 * time.Second
    // backoffScale is the base unit of the restart ladder.
    backoffScale = time.Second
)

// maxFailedStarts is how many consecutive bad starts before core stops
// trying. The plugin stays in the roster and the dashboard, marked failed,
// recoverable by the restart button.
const maxFailedStarts = 5

// backoffDelay returns the restart delay after n consecutive failed starts:
// 1s, 2s, 4s, 8s, 16s, 32s, then capped at 60s.
func backoffDelay(n int) time.Duration {
    if n < 1 {
        n = 1
    }
    if n > 7 {
        return 60 * backoffScale
    }
    d := backoffScale << (n - 1)
    if d > 60*backoffScale {
        d = 60 * backoffScale
    }
    return d
}

type procState struct {
    cmd *exec.Cmd
    // registered is closed by NotifyRegistered. A fresh channel is made for
    // every spawn attempt.
    registered chan struct{}
    // exited is closed by runOnce once cmd.Wait has returned. Stop waits on
    // this rather than polling cmd.ProcessState: Wait is concurrently in
    // flight inside runOnce, and reading ProcessState from another goroutine
    // is a data race that -race will flag.
    exited chan struct{}
    // intentional marks a kill this supervisor asked for (Stop or Restart),
    // so the loop can tell it apart from a crash.
    intentional bool
}

// Supervisor owns every plugin process: it spawns them, gives each one its
// data dir and socket path, enforces the registration timeout, restarts
// them with backoff, and tears them down on shutdown.
type Supervisor struct {
    reg        *Registry
    socketPath string
    dataRoot   string
    log        *zap.Logger

    mu       sync.Mutex
    procs    map[string]*procState
    restartC map[string]chan struct{} // manual restart signal per plugin
    stopped  bool

    wg     sync.WaitGroup
    cancel context.CancelFunc
}

func NewSupervisor(reg *Registry, socketPath, dataRoot string, log *zap.Logger) *Supervisor {
    return &Supervisor{
        reg:        reg,
        socketPath: socketPath,
        dataRoot:   dataRoot,
        log:        log,
        procs:      map[string]*procState{},
        restartC:   map[string]chan struct{}{},
    }
}

// Start launches one supervision goroutine per discovered plugin.
func (s *Supervisor) Start(ctx context.Context) {
    ctx, cancel := context.WithCancel(ctx)
    s.mu.Lock()
    s.cancel = cancel
    for _, m := range s.reg.Manifests() {
        s.restartC[m.ID] = make(chan struct{}, 1)
    }
    s.mu.Unlock()

    for _, m := range s.reg.Manifests() {
        s.wg.Add(1)
        go func(m Manifest) {
            defer s.wg.Done()
            s.supervise(ctx, m)
        }(m)
    }
}

// supervise is one plugin's entire lifecycle, start to finish. Keeping the
// whole state machine in a single goroutine is what keeps the ordering
// (spawn -> register -> up -> exit -> classify -> backoff) obvious.
func (s *Supervisor) supervise(ctx context.Context, m Manifest) {
    failures := 0

    for {
        if ctx.Err() != nil {
            return
        }

        startedAt := time.Now()
        exitErr := s.runOnce(ctx, m)
        if ctx.Err() != nil {
            return
        }

        s.mu.Lock()
        intentional := s.procs[m.ID] != nil && s.procs[m.ID].intentional
        stopped := s.stopped
        s.mu.Unlock()
        if stopped {
            return
        }

        reason := "exited"
        if exitErr != nil {
            reason = exitErr.Error()
        }

        if intentional {
            // A restart we asked for: don't punish the plugin for it.
            failures = 0
        } else {
            if time.Since(startedAt) >= stableUptime {
                // It ran fine for a while; this is a crash in service, so the
                // ladder starts over rather than continuing toward failed.
                failures = 0
            }
            failures++
            s.reg.SetState(m.ID, StateDown, reason)
        }

        if failures >= maxFailedStarts {
            s.reg.SetState(m.ID, StateFailed,
                fmt.Sprintf("%d consecutive failed starts; last: %s", failures, reason))
            // Park until a manual restart arrives (or core shuts down).
            select {
            case <-ctx.Done():
                return
            case <-s.restartChan(m.ID):
                failures = 0
                continue
            }
        }

        delay := backoffDelay(failures)
        if intentional {
            delay = 0
        }
        s.reg.IncRestarts(m.ID)
        select {
        case <-ctx.Done():
            return
        case <-s.restartChan(m.ID):
            failures = 0
        case <-time.After(delay):
        }
    }
}

// runOnce spawns the plugin, enforces the registration timeout, and blocks
// until the process exits. It returns the process's exit error, if any.
func (s *Supervisor) runOnce(ctx context.Context, m Manifest) error {
    dataDir := filepath.Join(s.dataRoot, m.ID)
    if err := os.MkdirAll(dataDir, 0o700); err != nil {
        s.reg.SetState(m.ID, StateDown, "create data dir: "+err.Error())
        return err
    }

    cmd := exec.Command(m.Exec)
    cmd.Dir = m.Dir
    // Exactly three variables, plus PATH/HOME so the process can find a
    // shell and its own home. Everything else a plugin needs comes from its
    // own directory or its data dir.
    cmd.Env = append(os.Environ(),
        "VIBECARE_SOCKET="+s.socketPath,
        "VIBECARE_PLUGIN_ID="+m.ID,
        "VIBECARE_DATA_DIR="+dataDir,
    )
    cmd.Stdout = os.Stderr // plugin stdout is diagnostic only; never parsed
    cmd.Stderr = os.Stderr
    // Own process group, so SIGKILL reaches children the plugin spawned.
    cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

    ps := &procState{cmd: cmd, registered: make(chan struct{}), exited: make(chan struct{})}
    s.mu.Lock()
    s.procs[m.ID] = ps
    s.mu.Unlock()

    s.reg.SetState(m.ID, StateStarting, "")
    if err := cmd.Start(); err != nil {
        s.reg.SetState(m.ID, StateDown, "spawn: "+err.Error())
        return err
    }
    s.reg.SetProcess(m.ID, cmd.Process.Pid)
    s.log.Info("plugin spawned", zap.String("plugin", m.ID), zap.Int("pid", cmd.Process.Pid))

    // Registration watchdog. A plugin that hasn't handshaken in time is
    // wedged; kill it and let the loop treat it as a failed start.
    watchdog := time.AfterFunc(registrationTimeout, func() {
        select {
        case <-ps.registered:
            return
        default:
        }
        s.log.Warn("plugin did not register in time; killing",
            zap.String("plugin", m.ID), zap.Duration("timeout", registrationTimeout))
        s.kill(ps)
    })
    defer watchdog.Stop()

    err := cmd.Wait()
    // Publish the exit exactly once, so Stop can observe it without racing
    // on cmd.ProcessState.
    close(ps.exited)
    return err
}

func (s *Supervisor) restartChan(id string) chan struct{} {
    s.mu.Lock()
    defer s.mu.Unlock()
    return s.restartC[id]
}

// NotifyRegistered is called by the Register RPC when a plugin completes
// the handshake. It disarms that spawn's registration watchdog.
func (s *Supervisor) NotifyRegistered(id string) {
    s.mu.Lock()
    ps := s.procs[id]
    s.mu.Unlock()
    if ps == nil {
        return
    }
    select {
    case <-ps.registered:
    default:
        close(ps.registered)
    }
}

// Restart terminates the plugin and asks its supervision loop to respawn
// immediately with a clean failure count. It works from any state,
// including failed — that is what makes the dashboard button useful.
func (s *Supervisor) Restart(id string) error {
    s.mu.Lock()
    ch, known := s.restartC[id]
    ps := s.procs[id]
    if ps != nil {
        ps.intentional = true
    }
    s.mu.Unlock()

    if !known {
        return fmt.Errorf("unknown plugin %q", id)
    }
    if ps != nil {
        s.kill(ps)
    }
    select {
    case ch <- struct{}{}:
    default: // a restart is already pending; one is enough
    }
    return nil
}

// Stop tears every plugin down: SIGTERM, then SIGKILL after shutdownGrace.
// Callers should have already sent CoreMsg.Shutdown on the plugin streams
// (rpc.go owns those) so plugins get a chance to flush first.
func (s *Supervisor) Stop(ctx context.Context) {
    s.mu.Lock()
    if s.stopped {
        s.mu.Unlock()
        return
    }
    s.stopped = true
    procs := make([]*procState, 0, len(s.procs))
    for _, ps := range s.procs {
        ps.intentional = true
        procs = append(procs, ps)
    }
    cancel := s.cancel
    s.mu.Unlock()

    var wg sync.WaitGroup
    for _, ps := range procs {
        if ps.cmd.Process == nil {
            continue
        }
        wg.Add(1)
        go func(ps *procState) {
            defer wg.Done()
            _ = syscall.Kill(-ps.cmd.Process.Pid, syscall.SIGTERM)
            // runOnce closes ps.exited after cmd.Wait returns. Waiting on
            // that channel is the only race-free way to observe the exit —
            // cmd.Wait is already in flight there, so neither a second Wait
            // nor a read of cmd.ProcessState is safe from here.
            select {
            case <-ps.exited:
            case <-time.After(shutdownGrace):
                s.log.Warn("plugin ignored SIGTERM; killing", zap.Int("pid", ps.cmd.Process.Pid))
                s.kill(ps)
            }
        }(ps)
    }
    wg.Wait()

    if cancel != nil {
        cancel()
    }
    s.wg.Wait()

    for _, m := range s.reg.Manifests() {
        s.reg.SetState(m.ID, StateDown, "core shutting down")
    }
}

// kill SIGKILLs the process group, so anything the plugin spawned dies too.
func (s *Supervisor) kill(ps *procState) {
    if ps == nil || ps.cmd == nil || ps.cmd.Process == nil {
        return
    }
    _ = syscall.Kill(-ps.cmd.Process.Pid, syscall.SIGKILL)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && go test ./kernel/ -race -v -timeout 120s`
Expected: PASS. The supervisor tests spawn real processes, so this is the slowest file in the package.

- [ ] **Step 5: Commit**

```bash
git add backend/kernel/supervisor.go backend/kernel/supervisor_test.go
git commit -m "feat(kernel): plugin supervisor with registration timeout and backoff restart"
```

---

### Task 6: Health — the `/health` probe and the state machine

**Files:**
- Create: `backend/kernel/health.go`
- Test: `backend/kernel/health_test.go`

**Interfaces:**
- Consumes: `Registry`, `State` (Task 3).
- Produces:
  ```go
  var (
      probeInterval = 10 * time.Second
      probeTimeout  = 2 * time.Second
  )
  const probeFailThreshold = 3

  type probeResult struct {
      ok               bool
      reportedDegraded bool
      detail           string
      latency          time.Duration
  }

  // healthBody is the optional JSON a plugin may return from /health.
  type healthBody struct {
      Status string `json:"status"` // "ok" | "degraded"
      Detail string `json:"detail"`
      Since  string `json:"since"`
  }

  func advance(cur State, r probeResult, fails int) (State, int)
  func probeHealth(ctx context.Context, c *http.Client, port uint32) probeResult

  type Health struct{ /* unexported */ }
  func NewHealth(reg *Registry, log *zap.Logger) *Health
  func (h *Health) Start(ctx context.Context)
  func (h *Health) ProbeOnce(ctx context.Context) // exported for tests and for the dashboard's refresh
  ```

Design notes for the implementer:

- **Two independent signals, and health owns only one.** The Register stream (control plane) tells core the process is alive; `GET /health` (data plane) tells core the HTTP server is responsive. They fail independently — a plugin can hold its stream open while its HTTP handler deadlocks. `rpc.go` owns the stream signal; this file owns the probe.
- **`advance` is pure and is where the whole state machine lives.** Test it exhaustively as a table; the loop around it is trivial.
- **Three consecutive failures before any transition.** One slow probe must never flap the roster. The counter resets to 0 on every transition so the next stage gets its own three.
- **Self-reported `degraded` is immediate.** A plugin that knows it is degraded should not have to wait 30s for core to guess.
- **Health never restarts anything.** A degraded plugin's process is alive and may hold unflushed state; killing it is the user's call via the dashboard.
- Only plugins in `StateUp` or `StateDegraded` **with a known port** are probed. Everything else is the supervisor's business.

- [ ] **Step 1: Write the failing tests**

```go
package kernel

import (
    "context"
    "net/http"
    "net/http/httptest"
    "net/url"
    "strconv"
    "testing"
    "time"

    "go.uber.org/zap"
)

// serverPort starts s and returns the loopback port it bound.
func serverPort(t *testing.T, s *httptest.Server) uint32 {
    t.Helper()
    u, err := url.Parse(s.URL)
    if err != nil {
        t.Fatal(err)
    }
    p, err := strconv.Atoi(u.Port())
    if err != nil {
        t.Fatal(err)
    }
    return uint32(p)
}

func TestAdvanceStateMachine(t *testing.T) {
    ok := probeResult{ok: true}
    bad := probeResult{ok: false}
    selfDegraded := probeResult{ok: true, reportedDegraded: true, detail: "camera busy"}

    cases := []struct {
        name      string
        cur       State
        r         probeResult
        fails     int
        wantState State
        wantFails int
    }{
        {"healthy stays up", StateUp, ok, 0, StateUp, 0},
        {"one bad probe does not move", StateUp, bad, 0, StateUp, 1},
        {"two bad probes do not move", StateUp, bad, 1, StateUp, 2},
        {"three bad probes degrade", StateUp, bad, 2, StateDegraded, 0},
        {"degraded plus three more goes down", StateDegraded, bad, 2, StateDown, 0},
        {"degraded plus one bad stays degraded", StateDegraded, bad, 0, StateDegraded, 1},
        {"probe recovery clears degraded", StateDegraded, ok, 2, StateUp, 0},
        {"recovery resets the counter", StateUp, ok, 2, StateUp, 0},
        {"self-reported degraded is immediate", StateUp, selfDegraded, 0, StateDegraded, 0},
        {"self-reported degraded from degraded stays", StateDegraded, selfDegraded, 1, StateDegraded, 0},
        {"down is not the prober's to change", StateDown, bad, 0, StateDown, 1},
    }
    for _, c := range cases {
        t.Run(c.name, func(t *testing.T) {
            gotState, gotFails := advance(c.cur, c.r, c.fails)
            if gotState != c.wantState || gotFails != c.wantFails {
                t.Fatalf("advance(%v, ok=%v deg=%v, %d) = (%v, %d); want (%v, %d)",
                    c.cur, c.r.ok, c.r.reportedDegraded, c.fails,
                    gotState, gotFails, c.wantState, c.wantFails)
            }
        })
    }
}

func TestProbeHealthPlainOK(t *testing.T) {
    srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.URL.Path != "/health" {
            t.Errorf("probed %q, want /health", r.URL.Path)
        }
        w.WriteHeader(http.StatusOK)
    }))
    defer srv.Close()

    got := probeHealth(context.Background(), srv.Client(), serverPort(t, srv))
    if !got.ok || got.reportedDegraded {
        t.Fatalf("result = %+v, want plain ok", got)
    }
    if got.latency <= 0 {
        t.Error("latency should be measured")
    }
}

// A plugin may enrich the probe with JSON; detail is free text the
// dashboard shows verbatim.
func TestProbeHealthParsesDetailJSON(t *testing.T) {
    srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        w.Write([]byte(`{"status":"degraded","detail":"camera: FaceTime HD","since":"2026-08-13T09:12:00Z"}`))
    }))
    defer srv.Close()

    got := probeHealth(context.Background(), srv.Client(), serverPort(t, srv))
    if !got.ok || !got.reportedDegraded || got.detail != "camera: FaceTime HD" {
        t.Fatalf("result = %+v", got)
    }
}

// Most plugins return an empty 200 from the SDK's default handler; that
// must not be misread as degraded.
func TestProbeHealthEmptyBodyIsOK(t *testing.T) {
    srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
    defer srv.Close()
    if got := probeHealth(context.Background(), srv.Client(), serverPort(t, srv)); !got.ok || got.reportedDegraded {
        t.Fatalf("result = %+v, want ok", got)
    }
}

func TestProbeHealthNon200IsFailure(t *testing.T) {
    srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
        w.WriteHeader(http.StatusServiceUnavailable)
    }))
    defer srv.Close()
    if got := probeHealth(context.Background(), srv.Client(), serverPort(t, srv)); got.ok {
        t.Fatalf("503 reported ok: %+v", got)
    }
}

func TestProbeHealthUnreachablePortIsFailure(t *testing.T) {
    srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
    port := serverPort(t, srv)
    client := srv.Client()
    srv.Close() // nothing listening now

    if got := probeHealth(context.Background(), client, port); got.ok {
        t.Fatalf("closed port reported ok: %+v", got)
    }
}

// A hung handler is exactly the failure the stream signal cannot see: the
// process is alive, the data plane is not.
func TestProbeHealthTimesOut(t *testing.T) {
    block := make(chan struct{})
    srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { <-block }))
    defer func() { close(block); srv.Close() }()

    probeTimeout = 100 * time.Millisecond
    t.Cleanup(func() { probeTimeout = 2 * time.Second })

    start := time.Now()
    got := probeHealth(context.Background(), srv.Client(), serverPort(t, srv))
    if got.ok {
        t.Fatal("hung handler reported ok")
    }
    if elapsed := time.Since(start); elapsed > time.Second {
        t.Fatalf("probe took %v; the timeout is not being applied", elapsed)
    }
}

// End to end through the registry: three bad probes move an up plugin to
// degraded and record the probe latency for the dashboard.
func TestHealthDegradesAfterThreeBadProbes(t *testing.T) {
    fail := make(chan struct{})
    srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
        select {
        case <-fail:
            w.WriteHeader(http.StatusInternalServerError)
        default:
            w.WriteHeader(http.StatusOK)
        }
    }))
    defer srv.Close()

    reg := NewRegistry(zap.NewNop())
    reg.Add(Manifest{ID: "alpha", Name: "alpha", Exec: "./a", UI: "webview"})
    reg.SetPort("alpha", serverPort(t, srv))
    reg.SetState("alpha", StateUp, "")

    h := NewHealth(reg, zap.NewNop())
    ctx := context.Background()

    h.ProbeOnce(ctx)
    if got, _ := reg.State("alpha"); got != StateUp {
        t.Fatalf("healthy probe moved state to %v", got)
    }
    if reg.Snapshot()[0].ProbeLatencyMS < 0 {
        t.Error("probe latency not recorded")
    }

    close(fail)
    h.ProbeOnce(ctx)
    h.ProbeOnce(ctx)
    if got, _ := reg.State("alpha"); got != StateUp {
        t.Fatalf("state = %v after 2 bad probes, want still up (no flapping)", got)
    }
    h.ProbeOnce(ctx)
    if got, _ := reg.State("alpha"); got != StateDegraded {
        t.Fatalf("state = %v after 3 bad probes, want degraded", got)
    }
}

// Plugins that aren't running have nothing to probe; probing them would
// fight the supervisor over who owns the state.
func TestHealthSkipsPluginsWithoutPortOrNotRunning(t *testing.T) {
    reg := NewRegistry(zap.NewNop())
    reg.Add(Manifest{ID: "noport", Name: "noport", Exec: "./a", UI: "webview"})
    reg.Add(Manifest{ID: "down", Name: "down", Exec: "./b", UI: "webview"})
    reg.SetPort("down", 1) // port 1: nothing listens there
    reg.SetState("down", StateDown, "exit status 1")

    h := NewHealth(reg, zap.NewNop())
    h.ProbeOnce(context.Background())

    if got, _ := reg.State("noport"); got != StateStarting {
        t.Errorf("unregistered plugin moved to %v", got)
    }
    if got, _ := reg.State("down"); got != StateDown {
        t.Errorf("down plugin moved to %v", got)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && go test ./kernel/ -run 'Advance|Probe|Health'`
Expected: FAIL — undefined `advance`, `probeHealth`, `NewHealth`.

- [ ] **Step 3: Write `backend/kernel/health.go`**

```go
package kernel

import (
    "context"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "sync"
    "time"

    "go.uber.org/zap"
)

var (
    // probeInterval is how often core asks each running plugin whether its
    // HTTP surface is still answering.
    probeInterval = 10 * time.Second
    // probeTimeout bounds a single probe. A plugin slower than this is, for
    // the purposes of "is the data plane responsive", not responsive.
    probeTimeout = 2 * time.Second
)

// probeFailThreshold is how many CONSECUTIVE failures a transition needs.
// Requiring three is what stops one slow probe from flapping the roster.
const probeFailThreshold = 3

type probeResult struct {
    ok               bool
    reportedDegraded bool
    detail           string
    latency          time.Duration
}

// healthBody is the optional JSON enrichment a plugin may return. The SDK
// registers a default handler that returns an empty 200, so most plugin
// authors never write any of this.
type healthBody struct {
    Status string `json:"status"` // "ok" | "degraded"
    Detail string `json:"detail"`
    Since  string `json:"since"`
}

// advance is the plugin health state machine, kept pure so it can be
// tested as a table without any I/O.
//
//	starting/up --3 failed probes--> degraded --3 more--> down
//	                  ^                  |
//	                  +-- probe recovers +
//
// A plugin that reports "degraded" from its own /health moves there
// immediately rather than waiting for probes to fail — it knows something
// core cannot observe.
func advance(cur State, r probeResult, fails int) (State, int) {
    if r.ok {
        if r.reportedDegraded {
            return StateDegraded, 0
        }
        return StateUp, 0
    }

    fails++
    switch cur {
    case StateStarting, StateUp:
        if fails >= probeFailThreshold {
            return StateDegraded, 0
        }
        return cur, fails
    case StateDegraded:
        if fails >= probeFailThreshold {
            return StateDown, 0
        }
        return StateDegraded, fails
    default:
        // down/failed belong to the supervisor; the prober only counts.
        return cur, fails
    }
}

// probeHealth performs one GET /health against a plugin's loopback port.
func probeHealth(ctx context.Context, c *http.Client, port uint32) probeResult {
    ctx, cancel := context.WithTimeout(ctx, probeTimeout)
    defer cancel()

    url := fmt.Sprintf("http://127.0.0.1:%d/health", port)
    req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
    if err != nil {
        return probeResult{}
    }

    start := time.Now()
    resp, err := c.Do(req)
    latency := time.Since(start)
    if err != nil {
        return probeResult{latency: latency}
    }
    defer resp.Body.Close()

    if resp.StatusCode != http.StatusOK {
        return probeResult{latency: latency, detail: resp.Status}
    }

    out := probeResult{ok: true, latency: latency}
    // Body is optional. Cap the read: a plugin returning megabytes from
    // /health is misbehaving and must not be able to stall the prober.
    b, err := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
    if err != nil || len(b) == 0 {
        return out
    }
    var body healthBody
    if err := json.Unmarshal(b, &body); err != nil {
        return out // free-form body is fine; 200 already answered the question
    }
    out.detail = body.Detail
    out.reportedDegraded = body.Status == "degraded"
    return out
}

// Health probes every running plugin's data plane on a timer. It never
// restarts anything: a degraded process is alive and may hold unflushed
// state, so terminating it is a user decision, not a timer's.
type Health struct {
    reg    *Registry
    log    *zap.Logger
    client *http.Client

    mu    sync.Mutex
    fails map[string]int
}

func NewHealth(reg *Registry, log *zap.Logger) *Health {
    return &Health{
        reg:    reg,
        log:    log,
        client: &http.Client{},
        fails:  map[string]int{},
    }
}

// Start runs ProbeOnce on a ticker until ctx is cancelled.
func (h *Health) Start(ctx context.Context) {
    go func() {
        t := time.NewTicker(probeInterval)
        defer t.Stop()
        for {
            select {
            case <-ctx.Done():
                return
            case <-t.C:
                h.ProbeOnce(ctx)
            }
        }
    }()
}

// ProbeOnce probes every plugin that is running and has a known port, in
// parallel, and applies the state machine to each result.
func (h *Health) ProbeOnce(ctx context.Context) {
    var wg sync.WaitGroup
    for _, stat := range h.reg.Snapshot() {
        if stat.State != StateUp && stat.State != StateDegraded {
            continue
        }
        port, ok := h.reg.Port(stat.ID)
        if !ok {
            continue
        }
        wg.Add(1)
        go func(id string, cur State, port uint32) {
            defer wg.Done()
            r := probeHealth(ctx, h.client, port)
            h.reg.SetProbeLatency(id, r.latency)

            h.mu.Lock()
            next, fails := advance(cur, r, h.fails[id])
            h.fails[id] = fails
            h.mu.Unlock()

            detail := r.detail
            if next == StateUp {
                detail = ""
            }
            if next != cur || detail != "" {
                h.reg.SetState(id, next, detail)
            }
        }(stat.ID, stat.State, port)
    }
    wg.Wait()
}

// Reset clears a plugin's failure count. The RPC layer calls this when a
// plugin (re)registers, so a fresh process starts with a clean slate.
func (h *Health) Reset(id string) {
    h.mu.Lock()
    defer h.mu.Unlock()
    delete(h.fails, id)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && go test ./kernel/ -race -v -timeout 120s`
Expected: PASS — the eleven `advance` table cases plus the seven probe/Health tests, and everything from Tasks 2–5 still green.

- [ ] **Step 5: Commit**

```bash
git add backend/kernel/health.go backend/kernel/health_test.go
git commit -m "feat(kernel): health probing and plugin state machine"
```

---

### Task 7: Auth and the reverse proxy

**Files:**
- Create: `backend/kernel/auth.go`
- Create: `backend/kernel/proxy.go`
- Test: `backend/kernel/auth_test.go`
- Test: `backend/kernel/proxy_test.go`

**Interfaces:**
- Consumes: `Registry`, `State` (Task 3).
- Produces:
  ```go
  const (
      sessionCookie = "vc_session"
      tokenParam    = "vc"
  )

  type Auth struct{ /* unexported */ }
  func NewAuth(sessionPath string) (*Auth, error) // mints a 32-byte token, writes 0600
  func (a *Auth) Token() string
  func (a *Auth) Middleware(next http.Handler) http.Handler

  func NewProxy(reg *Registry, log *zap.Logger) http.Handler // serves /p/<id>/*
  ```

Design notes for the implementer:

- **Plugins write no auth code at all.** Authentication happens once, in one place, in core. This is the whole reason the proxy exists.
- **Cookie `Path=/` (deviation from spec §7.3, which says `/p/`).** `/_core/*` is served by the same origin and needs the same cookie; scoping to `/p/` would lock the dashboard out of its own auth. Everything is one origin either way, so this changes nothing security-wise.
- **Token comparison must be `subtle.ConstantTimeCompare`.** It is a bearer secret arriving on a loopback socket that any local process can reach.
- **The `?vc=` handoff redirects.** After validating the query param and setting the cookie, redirect to the same URL with `vc` stripped, so the token does not linger in the webview's URL bar, history, or `Referer` headers.
- **`FlushInterval = -1` is mandatory.** Without it `httputil.ReverseProxy` buffers responses and MJPEG previews / SSE hang forever. There is a test for it below; do not delete it.
- **A down plugin gets a generic error page, not a proxy attempt.** Same for a plugin with no port yet.

- [ ] **Step 1: Write the failing auth tests**

```go
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
```

- [ ] **Step 2: Write the failing proxy tests**

```go
package kernel

import (
    "bufio"
    "fmt"
    "net/http"
    "net/http/httptest"
    "net/url"
    "strconv"
    "strings"
    "testing"
    "time"

    "go.uber.org/zap"
)

// upPlugin registers a plugin in the registry backed by a live test server
// and marks it up.
func upPlugin(t *testing.T, reg *Registry, id string, h http.Handler) *httptest.Server {
    t.Helper()
    srv := httptest.NewServer(h)
    t.Cleanup(srv.Close)

    u, _ := url.Parse(srv.URL)
    p, _ := strconv.Atoi(u.Port())

    reg.Add(Manifest{ID: id, Name: id, Exec: "./" + id, UI: "webview"})
    reg.SetPort(id, uint32(p))
    reg.SetState(id, StateUp, "")
    return srv
}

func TestProxyForwardsAndStripsPrefix(t *testing.T) {
    reg := NewRegistry(zap.NewNop())
    upPlugin(t, reg, "alpha", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprintf(w, "path=%s query=%s", r.URL.Path, r.URL.RawQuery)
    }))

    rec := httptest.NewRecorder()
    NewProxy(reg, zap.NewNop()).ServeHTTP(rec, httptest.NewRequest("GET", "/p/alpha/api/tasks?done=1", nil))

    if rec.Code != http.StatusOK {
        t.Fatalf("code = %d", rec.Code)
    }
    if got := rec.Body.String(); got != "path=/api/tasks query=done=1" {
        t.Fatalf("plugin saw %q; the /p/<id> prefix must be stripped and the query preserved", got)
    }
}

// The root of a plugin is where its HTML lives; a bare /p/<id> must reach
// it rather than 404.
func TestProxyRootPath(t *testing.T) {
    reg := NewRegistry(zap.NewNop())
    upPlugin(t, reg, "alpha", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprintf(w, "path=%s", r.URL.Path)
    }))
    p := NewProxy(reg, zap.NewNop())

    rec := httptest.NewRecorder()
    p.ServeHTTP(rec, httptest.NewRequest("GET", "/p/alpha/", nil))
    if got := rec.Body.String(); got != "path=/" {
        t.Fatalf("/p/alpha/ -> %q, want path=/", got)
    }

    // Without the trailing slash, redirect rather than guess — relative
    // asset URLs in the plugin's HTML depend on the trailing slash.
    rec = httptest.NewRecorder()
    p.ServeHTTP(rec, httptest.NewRequest("GET", "/p/alpha", nil))
    if rec.Code != http.StatusMovedPermanently || rec.Header().Get("Location") != "/p/alpha/" {
        t.Fatalf("code = %d location = %q, want 301 -> /p/alpha/", rec.Code, rec.Header().Get("Location"))
    }
}

func TestProxyPreservesMethodAndBody(t *testing.T) {
    reg := NewRegistry(zap.NewNop())
    upPlugin(t, reg, "alpha", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        b := make([]byte, r.ContentLength)
        r.Body.Read(b)
        fmt.Fprintf(w, "%s:%s", r.Method, b)
    }))

    rec := httptest.NewRecorder()
    req := httptest.NewRequest("POST", "/p/alpha/api/tasks", strings.NewReader("hello"))
    NewProxy(reg, zap.NewNop()).ServeHTTP(rec, req)

    if got := rec.Body.String(); got != "POST:hello" {
        t.Fatalf("plugin saw %q", got)
    }
}

// Plugin down -> a generic error page at its path, not a proxy attempt and
// not a raw connection error.
func TestProxyDownPluginServesErrorPage(t *testing.T) {
    reg := NewRegistry(zap.NewNop())
    upPlugin(t, reg, "alpha", okHandler)
    reg.SetState("alpha", StateDown, "exit status 1")

    rec := httptest.NewRecorder()
    NewProxy(reg, zap.NewNop()).ServeHTTP(rec, httptest.NewRequest("GET", "/p/alpha/", nil))

    if rec.Code != http.StatusServiceUnavailable {
        t.Fatalf("code = %d, want 503", rec.Code)
    }
    body := rec.Body.String()
    if !strings.Contains(body, "alpha") || !strings.Contains(body, "exit status 1") {
        t.Fatalf("error page should name the plugin and its exit reason; got:\n%s", body)
    }
}

func TestProxyUnknownPluginIs404(t *testing.T) {
    reg := NewRegistry(zap.NewNop())
    rec := httptest.NewRecorder()
    NewProxy(reg, zap.NewNop()).ServeHTTP(rec, httptest.NewRequest("GET", "/p/ghost/", nil))
    if rec.Code != http.StatusNotFound {
        t.Fatalf("code = %d, want 404", rec.Code)
    }
}

// A degraded plugin still serves — that is the whole distinction between
// degraded and down.
func TestProxyDegradedPluginStillProxies(t *testing.T) {
    reg := NewRegistry(zap.NewNop())
    upPlugin(t, reg, "alpha", okHandler)
    reg.SetState("alpha", StateDegraded, "slow")

    rec := httptest.NewRecorder()
    NewProxy(reg, zap.NewNop()).ServeHTTP(rec, httptest.NewRequest("GET", "/p/alpha/", nil))
    if rec.Code != http.StatusOK {
        t.Fatalf("code = %d, want the degraded plugin to still serve", rec.Code)
    }
}

// THE test that justifies FlushInterval = -1. Without it, ReverseProxy
// buffers the response and an MJPEG preview or SSE stream never arrives
// until the handler returns — i.e. never. This runs against a real
// listener because httptest.Recorder cannot observe flushing.
func TestProxyStreamsWithoutBuffering(t *testing.T) {
    reg := NewRegistry(zap.NewNop())
    release := make(chan struct{})
    upPlugin(t, reg, "alpha", http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
        w.Header().Set("Content-Type", "text/event-stream")
        w.WriteHeader(http.StatusOK)
        fmt.Fprint(w, "data: first\n\n")
        w.(http.Flusher).Flush()
        <-release // hold the handler open; the first chunk must already be out
        fmt.Fprint(w, "data: second\n\n")
    }))

    front := httptest.NewServer(NewProxy(reg, zap.NewNop()))
    defer front.Close()
    defer close(release)

    resp, err := http.Get(front.URL + "/p/alpha/events")
    if err != nil {
        t.Fatal(err)
    }
    defer resp.Body.Close()

    type read struct{ line string; err error }
    got := make(chan read, 1)
    go func() {
        line, err := bufio.NewReader(resp.Body).ReadString('\n')
        got <- read{line, err}
    }()

    select {
    case r := <-got:
        if r.err != nil || !strings.Contains(r.line, "first") {
            t.Fatalf("read %q, %v", r.line, r.err)
        }
    case <-time.After(2 * time.Second):
        t.Fatal("first chunk never arrived — the proxy is buffering; FlushInterval must be -1")
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd backend && go test ./kernel/ -run 'Auth|Token|Cookie|Unauthenticated|Proxy'`
Expected: FAIL — undefined `NewAuth`, `NewProxy`, `sessionCookie`, `tokenParam`.

- [ ] **Step 4: Write `backend/kernel/auth.go`**

```go
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
```

- [ ] **Step 5: Write `backend/kernel/proxy.go`**

```go
package kernel

import (
    "fmt"
    "html"
    "net/http"
    "net/http/httputil"
    "net/url"
    "strings"

    "go.uber.org/zap"
)

// proxyPrefix is the mount point for every plugin's HTTP surface.
const proxyPrefix = "/p/"

// NewProxy returns the handler for /p/<plugin-id>/*. It rewrites
//
//	http://127.0.0.1:<core>/p/<id>/<path>  ->  http://127.0.0.1:<plugin>/<path>
//
// and is the reason plugins write no authentication code: by the time a
// request gets here it has already passed Auth.Middleware.
func NewProxy(reg *Registry, log *zap.Logger) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        rest := strings.TrimPrefix(r.URL.Path, proxyPrefix)
        id, path, hasSlash := strings.Cut(rest, "/")

        if id == "" {
            http.NotFound(w, r)
            return
        }
        if !hasSlash {
            // Relative asset URLs inside the plugin's HTML resolve against
            // the trailing slash, so normalize rather than guess.
            http.Redirect(w, r, proxyPrefix+id+"/", http.StatusMovedPermanently)
            return
        }

        stat, ok := lookupStat(reg, id)
        if !ok {
            http.NotFound(w, r)
            return
        }
        port, hasPort := reg.Port(id)
        if !hasPort || (stat.State != StateUp && stat.State != StateDegraded) {
            servePluginDown(w, stat)
            return
        }

        target, err := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
        if err != nil {
            servePluginDown(w, stat)
            return
        }

        rp := &httputil.ReverseProxy{
            Rewrite: func(pr *httputil.ProxyRequest) {
                pr.SetURL(target)
                pr.Out.URL.Path = "/" + path
                pr.Out.Host = target.Host
            },
            // MANDATORY. Without this, ReverseProxy buffers responses and
            // MJPEG previews and SSE streams never reach the client. There
            // is a test for this; do not remove it.
            FlushInterval: -1,
            ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
                log.Warn("proxy error", zap.String("plugin", id), zap.Error(err))
                servePluginDown(w, stat)
            },
        }
        rp.ServeHTTP(w, r)
    })
}

func lookupStat(reg *Registry, id string) (PluginStat, bool) {
    for _, s := range reg.Snapshot() {
        if s.ID == id {
            return s, true
        }
    }
    return PluginStat{}, false
}

// servePluginDown is the generic error page shown in place of a plugin
// that isn't serving. v1 has no render-while-down: the client retries the
// view when the roster reports the plugin back up.
func servePluginDown(w http.ResponseWriter, stat PluginStat) {
    w.Header().Set("Content-Type", "text/html; charset=utf-8")
    w.WriteHeader(http.StatusServiceUnavailable)
    detail := stat.Detail
    if detail == "" {
        detail = "no further detail"
    }
    fmt.Fprintf(w, `<!doctype html><meta charset="utf-8">
<title>%s is not running</title>
<body style="font:14px/1.5 -apple-system,sans-serif;padding:2rem">
<h1>%s is not running</h1>
<p>State: <code>%s</code></p>
<p>%s</p>
<p>This page reloads automatically when the plugin comes back.</p>`,
        html.EscapeString(stat.Name),
        html.EscapeString(stat.Name),
        html.EscapeString(stat.State.String()),
        html.EscapeString(detail))
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd backend && go test ./kernel/ -race -v -timeout 120s`
Expected: PASS, including `TestProxyStreamsWithoutBuffering`.

- [ ] **Step 7: Verify the streaming test actually catches a regression**

Temporarily change `FlushInterval: -1` to `FlushInterval: 0` in `proxy.go`, then run:

Run: `cd backend && go test ./kernel/ -run TestProxyStreamsWithoutBuffering`
Expected: FAIL with "first chunk never arrived". Restore `-1` and re-run to confirm PASS. This proves the guard is real rather than decorative.

- [ ] **Step 8: Commit**

```bash
git add backend/kernel/auth.go backend/kernel/auth_test.go backend/kernel/proxy.go backend/kernel/proxy_test.go
git commit -m "feat(kernel): session auth and streaming-safe plugin reverse proxy"
```

---

### Task 8: Status dashboard at `/_core/*`

**Files:**
- Create: `backend/kernel/status.go`
- Test: `backend/kernel/status_test.go`

**Interfaces:**
- Consumes: `Registry`, `PluginStat` (Task 3); `Supervisor.Restart` (Task 5) via an interface.
- Produces:
  ```go
  const corePrefix = "/_core/"

  type Restarter interface{ Restart(id string) error }

  // statusJSON is the shape of GET /_core/api/plugins.
  type statusJSON struct {
      Plugins []statusPluginJSON `json:"plugins"`
  }
  type statusPluginJSON struct {
      ID              string `json:"id"`
      Name            string `json:"name"`
      Path            string `json:"path"`
      State           string `json:"state"`
      Detail          string `json:"detail"`
      PID             int    `json:"pid"`
      UptimeSec       int64  `json:"uptime_sec"`
      Restarts        int    `json:"restarts"`
      ProbeLatencyMS  int64  `json:"probe_latency_ms"`
      EventsPublished uint64 `json:"events_published"`
      EventsDelivered uint64 `json:"events_delivered"`
      LastEventUnix   int64  `json:"last_event_unix"`
  }

  func NewStatusHandler(reg *Registry, r Restarter) http.Handler // serves /_core/*
  ```

Design notes for the implementer:

- **This lives in core, not in a `status` plugin.** A dashboard that goes dark whenever the plugin system is unhealthy is worthless precisely when it is needed.
- **It follows the same HTML/JSON split core asks of plugins:** `/_core/status` is HTML, `/_core/api/plugins` is the identical data as JSON. Practise what §7.2 preaches.
- **D10 still holds.** The dashboard reports on plugins generically and names none of them. No product noun appears in this file.
- The HTML is a single self-contained page with a `<meta http-equiv="refresh" content="5">` — no JS build step, no assets, nothing to break when everything else is broken. The restart button is a plain `<form method="post">`.
- **`/_core/*` is never proxied.** Routing enforces that in `kernel.go` (Task 10); §4's id regex is what makes the collision impossible in the first place.

- [ ] **Step 1: Write the failing tests**

```go
package kernel

import (
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "strings"
    "testing"

    "go.uber.org/zap"
)

type fakeRestarter struct {
    called []string
    err    error
}

func (f *fakeRestarter) Restart(id string) error {
    f.called = append(f.called, id)
    return f.err
}

func statusFixture(t *testing.T) (*Registry, *fakeRestarter, http.Handler) {
    t.Helper()
    reg := NewRegistry(zap.NewNop())
    reg.Add(Manifest{ID: "alpha", Name: "Alpha", Icon: "circle", Exec: "./a", UI: "webview"})
    reg.Add(Manifest{ID: "beta", Name: "Beta", Icon: "square", Exec: "./b", UI: "none"})
    reg.SetPort("alpha", 41000)
    reg.SetProcess("alpha", 4242)
    reg.SetState("alpha", StateUp, "")
    reg.CountPublished("alpha")
    reg.CountDelivered("alpha", 7)
    reg.SetState("beta", StateFailed, "5 consecutive failed starts; last: exit status 3")

    fr := &fakeRestarter{}
    return reg, fr, NewStatusHandler(reg, fr)
}

func TestStatusJSONShape(t *testing.T) {
    _, _, h := statusFixture(t)

    rec := httptest.NewRecorder()
    h.ServeHTTP(rec, httptest.NewRequest("GET", "/_core/api/plugins", nil))
    if rec.Code != http.StatusOK {
        t.Fatalf("code = %d", rec.Code)
    }
    if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "application/json") {
        t.Fatalf("content-type = %q", ct)
    }

    var got statusJSON
    if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
        t.Fatalf("unmarshal: %v\nbody: %s", err, rec.Body.String())
    }
    if len(got.Plugins) != 2 {
        t.Fatalf("got %d plugins, want 2", len(got.Plugins))
    }

    a := got.Plugins[0]
    if a.ID != "alpha" || a.Name != "Alpha" || a.Path != "/p/alpha/" || a.State != "up" {
        t.Errorf("alpha = %+v", a)
    }
    if a.PID != 4242 || a.EventsPublished != 1 || a.EventsDelivered != 7 {
        t.Errorf("alpha stats = %+v", a)
    }

    b := got.Plugins[1]
    if b.State != "failed" || !strings.Contains(b.Detail, "exit status 3") {
        t.Errorf("beta = %+v; detail must carry the exit reason", b)
    }
}

// The dashboard is how a failed plugin becomes visible and recoverable
// without reading logs or restarting core.
func TestStatusHTMLListsEveryPluginWithItsState(t *testing.T) {
    _, _, h := statusFixture(t)

    rec := httptest.NewRecorder()
    h.ServeHTTP(rec, httptest.NewRequest("GET", "/_core/status", nil))
    if rec.Code != http.StatusOK {
        t.Fatalf("code = %d", rec.Code)
    }
    if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/html") {
        t.Fatalf("content-type = %q", ct)
    }

    body := rec.Body.String()
    for _, want := range []string{"Alpha", "Beta", "up", "failed", "exit status 3", "4242", "/_core/api/plugins/alpha/restart"} {
        if !strings.Contains(body, want) {
            t.Errorf("dashboard missing %q", want)
        }
    }
}

func TestRestartEndpointCallsSupervisor(t *testing.T) {
    _, fr, h := statusFixture(t)

    rec := httptest.NewRecorder()
    h.ServeHTTP(rec, httptest.NewRequest("POST", "/_core/api/plugins/beta/restart", nil))

    if rec.Code != http.StatusSeeOther {
        t.Fatalf("code = %d, want 303 back to the dashboard", rec.Code)
    }
    if loc := rec.Header().Get("Location"); loc != "/_core/status" {
        t.Errorf("Location = %q", loc)
    }
    if len(fr.called) != 1 || fr.called[0] != "beta" {
        t.Fatalf("Restart called with %v, want [beta]", fr.called)
    }
}

func TestRestartUnknownPluginIs404(t *testing.T) {
    _, _, h := statusFixture(t)
    rec := httptest.NewRecorder()
    h.ServeHTTP(rec, httptest.NewRequest("POST", "/_core/api/plugins/ghost/restart", nil))
    if rec.Code != http.StatusNotFound {
        t.Fatalf("code = %d, want 404", rec.Code)
    }
}

// Restart mutates state; a GET must not be able to trigger it (a prefetch
// or an <img> tag would be enough).
func TestRestartRejectsGET(t *testing.T) {
    _, fr, h := statusFixture(t)
    rec := httptest.NewRecorder()
    h.ServeHTTP(rec, httptest.NewRequest("GET", "/_core/api/plugins/beta/restart", nil))
    if rec.Code != http.StatusMethodNotAllowed {
        t.Fatalf("code = %d, want 405", rec.Code)
    }
    if len(fr.called) != 0 {
        t.Fatal("GET triggered a restart")
    }
}

func TestUnknownCorePathIs404(t *testing.T) {
    _, _, h := statusFixture(t)
    rec := httptest.NewRecorder()
    h.ServeHTTP(rec, httptest.NewRequest("GET", "/_core/nope", nil))
    if rec.Code != http.StatusNotFound {
        t.Fatalf("code = %d, want 404", rec.Code)
    }
}
```

**Do not add a test here that asserts the dashboard names no specific plugin.** Such a test would have to spell the forbidden words out, which violates D10 in `status_test.go` itself. Task 9's `TestKernelContainsNoProductNouns` is the spec-mandated form of that check and covers this file along with every other.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && go test ./kernel/ -run 'Status|Restart|UnknownCore|Dashboard'`
Expected: FAIL — undefined `NewStatusHandler`, `statusJSON`.

- [ ] **Step 3: Write `backend/kernel/status.go`**

```go
package kernel

import (
    "encoding/json"
    "html/template"
    "net/http"
    "strings"
)

// corePrefix is reserved for core itself and is NEVER proxied. Plugin ids
// cannot collide with it: the id regex rejects a leading underscore.
const corePrefix = "/_core/"

// Restarter is the slice of the supervisor the dashboard needs. Depending
// on the interface rather than the concrete type keeps status.go testable
// without spawning processes.
type Restarter interface {
    Restart(id string) error
}

type statusPluginJSON struct {
    ID              string `json:"id"`
    Name            string `json:"name"`
    Path            string `json:"path"`
    State           string `json:"state"`
    Detail          string `json:"detail"`
    PID             int    `json:"pid"`
    UptimeSec       int64  `json:"uptime_sec"`
    Restarts        int    `json:"restarts"`
    ProbeLatencyMS  int64  `json:"probe_latency_ms"`
    EventsPublished uint64 `json:"events_published"`
    EventsDelivered uint64 `json:"events_delivered"`
    LastEventUnix   int64  `json:"last_event_unix"`
}

type statusJSON struct {
    Plugins []statusPluginJSON `json:"plugins"`
}

func toStatusJSON(stats []PluginStat) statusJSON {
    out := statusJSON{Plugins: make([]statusPluginJSON, 0, len(stats))}
    for _, s := range stats {
        out.Plugins = append(out.Plugins, statusPluginJSON{
            ID:              s.ID,
            Name:            s.Name,
            Path:            s.Path,
            State:           s.State.String(),
            Detail:          s.Detail,
            PID:             s.PID,
            UptimeSec:       s.UptimeSec,
            Restarts:        s.Restarts,
            ProbeLatencyMS:  s.ProbeLatencyMS,
            EventsPublished: s.EventsPublished,
            EventsDelivered: s.EventsDelivered,
            LastEventUnix:   s.LastEventUnix,
        })
    }
    return out
}

// dashboardTmpl is deliberately one self-contained page with no assets and
// no JavaScript: it must render when everything else is broken, which is
// the only time anyone looks at it.
var dashboardTmpl = template.Must(template.New("status").Parse(`<!doctype html>
<meta charset="utf-8">
<meta http-equiv="refresh" content="5">
<title>VibeCare — plugin status</title>
<style>
 body{font:13px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;padding:2rem;max-width:64rem;margin:auto}
 table{border-collapse:collapse;width:100%}
 th,td{text-align:left;padding:.4rem .6rem;border-bottom:1px solid #ddd;vertical-align:top}
 th{font-weight:600;color:#666;font-size:11px;text-transform:uppercase;letter-spacing:.04em}
 code{font:12px ui-monospace,Menlo,monospace}
 .s-up{color:#118a3d}.s-degraded{color:#b26a00}.s-down,.s-failed{color:#b3261e}.s-starting{color:#666}
 button{font:inherit;padding:.2rem .6rem}
 @media (prefers-color-scheme:dark){
   body{background:#1b1b1b;color:#eee}th,td{border-color:#333}th{color:#999}
 }
</style>
<h1>Plugin status</h1>
<table>
<tr><th>Plugin</th><th>State</th><th>PID</th><th>Uptime</th><th>Restarts</th>
    <th>Probe</th><th>Events pub/del</th><th>Detail</th><th></th></tr>
{{range .Plugins}}
<tr>
  <td><a href="/p/{{.ID}}/">{{.Name}}</a><br><code>{{.ID}}</code></td>
  <td class="s-{{.State}}">{{.State}}</td>
  <td>{{if .PID}}{{.PID}}{{else}}—{{end}}</td>
  <td>{{if .UptimeSec}}{{.UptimeSec}}s{{else}}—{{end}}</td>
  <td>{{.Restarts}}</td>
  <td>{{if .ProbeLatencyMS}}{{.ProbeLatencyMS}}ms{{else}}—{{end}}</td>
  <td>{{.EventsPublished}} / {{.EventsDelivered}}</td>
  <td>{{.Detail}}</td>
  <td><form method="post" action="/_core/api/plugins/{{.ID}}/restart">
      <button type="submit">Restart</button></form></td>
</tr>
{{else}}
<tr><td colspan="9">No plugins discovered.</td></tr>
{{end}}
</table>
<p><a href="/_core/api/plugins">JSON</a> · refreshes every 5s</p>
`))

// NewStatusHandler serves core's own surface. It follows the same HTML/JSON
// split core asks of plugins (§7.2): /_core/status renders, and
// /_core/api/plugins returns the identical data for anything that isn't a
// browser.
func NewStatusHandler(reg *Registry, r Restarter) http.Handler {
    mux := http.NewServeMux()

    mux.HandleFunc("/_core/status", func(w http.ResponseWriter, _ *http.Request) {
        w.Header().Set("Content-Type", "text/html; charset=utf-8")
        _ = dashboardTmpl.Execute(w, toStatusJSON(reg.Snapshot()))
    })

    mux.HandleFunc("/_core/api/plugins", func(w http.ResponseWriter, _ *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        _ = json.NewEncoder(w).Encode(toStatusJSON(reg.Snapshot()))
    })

    // /_core/api/plugins/<id>/restart
    mux.HandleFunc("/_core/api/plugins/", func(w http.ResponseWriter, req *http.Request) {
        rest := strings.TrimPrefix(req.URL.Path, "/_core/api/plugins/")
        id, action, ok := strings.Cut(rest, "/")
        if !ok || action != "restart" {
            http.NotFound(w, req)
            return
        }
        if _, known := reg.Manifest(id); !known {
            http.NotFound(w, req)
            return
        }
        // Restart mutates state, so it is POST-only: a prefetch or an
        // <img src> must not be able to bounce a plugin.
        if req.Method != http.MethodPost {
            w.Header().Set("Allow", http.MethodPost)
            http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
            return
        }
        if err := r.Restart(id); err != nil {
            http.Error(w, err.Error(), http.StatusInternalServerError)
            return
        }
        http.Redirect(w, req, "/_core/status", http.StatusSeeOther)
    })

    return mux
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && go test ./kernel/ -race -v -timeout 120s`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/kernel/status.go backend/kernel/status_test.go
git commit -m "feat(kernel): core status dashboard with per-plugin stats and restart"
```

---

### Task 9: gRPC surface — `PluginHost`, alert fan-out, `Shell`, and the D10 guard

**Files:**
- Create: `backend/kernel/rpc.go`
- Create: `backend/kernel/intents.go`
- Create: `backend/kernel/shell.go`
- Test: `backend/kernel/rpc_test.go`
- Test: `backend/kernel/shell_test.go`
- Test: `backend/kernel/d10_test.go`

**Interfaces:**
- Consumes: `Registry` (3), `Bus` (4), `Supervisor` (5), `Health` (6); generated `pluginv1`/`clientv1` (1); `pluginwire.PluginIDMetadataKey` (existing).
- Produces:
  ```go
  type Intents struct{ /* unexported */ }
  func NewIntents(log *zap.Logger) *Intents
  func (i *Intents) Subscribe() (<-chan *clientv1.Alert, func())
  func (i *Intents) Broadcast(a *clientv1.Alert)

  type Host struct{ pluginv1.UnimplementedPluginHostServer; /* ... */ }
  func NewHost(reg *Registry, bus *Bus, sup *Supervisor, h *Health, in *Intents, log *zap.Logger) *Host
  func (h *Host) Register(req *pluginv1.RegisterReq, stream pluginv1.PluginHost_RegisterServer) error
  func (h *Host) Publish(ctx context.Context, e *pluginv1.Event) (*emptypb.Empty, error)
  func (h *Host) Alert(ctx context.Context, r *pluginv1.AlertReq) (*emptypb.Empty, error)
  func (h *Host) BroadcastShutdown(reason string)

  type ShellService struct{ clientv1.UnimplementedShellServer; /* ... */ }
  func NewShellService(reg *Registry, in *Intents, baseURL func() string, token string) *ShellService
  func (s *ShellService) Plugins(_ *emptypb.Empty, stream clientv1.Shell_PluginsServer) error
  func (s *ShellService) Intents(_ *emptypb.Empty, stream clientv1.Shell_IntentsServer) error
  ```

Design notes for the implementer:

- **Caller attribution.** `Publish` and `Alert` are unary calls with no plugin field, so the caller's id comes from gRPC metadata under the existing `pluginwire.PluginIDMetadataKey`. The SDK attaches it on every outbound call (Task 11). A call with no id, or an id not in the registry, is rejected.
- **One stream, three jobs.** `Register` confirms registration (`Ready`), delivers subscribed bus events (`Event`), and signals graceful shutdown (`Shutdown`). Nothing else uses the stream.
- **Stream drop ≠ process death.** If the stream drops while the process lives, the plugin reconnects (SDK retry #1) — that is what makes a core restart survivable. On stream loss, move `up`/`degraded` → `starting` with detail `"reconnecting"`, and never clobber `down`/`failed`, which the supervisor owns.
- **Alerts are transient and never retained.** A client that connects after an alert fired does not see it. Do not buffer them anywhere.
- **Headless plugins (`ui: none`) are excluded from the roster** — they get no tab, which is the entire meaning of `ui: none`.
- The roster stream sends the *whole* `PluginList` on every state change, including `base_url` and `token`. The roster is small and changes rarely; there is no need for deltas.

- [ ] **Step 1: Write the failing tests for `Register`/`Publish`/`Alert`**

```go
package kernel

import (
    "context"
    "net"
    "testing"
    "time"

    "github.com/vibecare-io/vibecare/backend/pkg/pluginwire"
    clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
    pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
    "go.uber.org/zap"
    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/insecure"
    "google.golang.org/grpc/metadata"
    "google.golang.org/grpc/test/bufconn"
)

// hostFixture spins the real PluginHost service over an in-memory
// connection, so tests exercise the actual gRPC path rather than calling
// methods directly.
type hostFixture struct {
    reg     *Registry
    bus     *Bus
    intents *Intents
    host    *Host
    client  pluginv1.PluginHostClient
}

func newHostFixture(t *testing.T, manifests ...Manifest) *hostFixture {
    t.Helper()
    reg := NewRegistry(zap.NewNop())
    bus := NewBus(zap.NewNop())
    for _, m := range manifests {
        reg.Add(m)
        bus.Declare(m.ID, m.Subscribes, m.Publishes)
    }
    sup := NewSupervisor(reg, "/tmp/unused.sock", t.TempDir(), zap.NewNop())
    health := NewHealth(reg, zap.NewNop())
    intents := NewIntents(zap.NewNop())

    host := NewHost(reg, bus, sup, health, intents, zap.NewNop())

    lis := bufconn.Listen(1 << 20)
    srv := grpc.NewServer()
    pluginv1.RegisterPluginHostServer(srv, host)
    go srv.Serve(lis)
    t.Cleanup(srv.Stop)

    conn, err := grpc.NewClient("passthrough:///bufnet",
        grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }),
        grpc.WithTransportCredentials(insecure.NewCredentials()))
    if err != nil {
        t.Fatal(err)
    }
    t.Cleanup(func() { conn.Close() })

    return &hostFixture{
        reg: reg, bus: bus, intents: intents, host: host,
        client: pluginv1.NewPluginHostClient(conn),
    }
}

// asPlugin returns a context carrying the caller-attribution metadata the
// SDK attaches to every outbound call.
func asPlugin(id string) context.Context {
    return metadata.AppendToOutgoingContext(context.Background(), pluginwire.PluginIDMetadataKey, id)
}

func TestRegisterReadiesPluginAndRecordsPort(t *testing.T) {
    f := newHostFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})

    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    stream, err := f.client.Register(ctx, &pluginv1.RegisterReq{Id: "alpha", HttpPort: 41234})
    if err != nil {
        t.Fatal(err)
    }

    msg, err := stream.Recv()
    if err != nil {
        t.Fatalf("first message: %v", err)
    }
    if msg.GetReady() == nil {
        t.Fatalf("first message = %+v, want Ready", msg)
    }
    if got, _ := f.reg.Port("alpha"); got != 41234 {
        t.Errorf("port = %d, want 41234", got)
    }
    if got, _ := f.reg.State("alpha"); got != StateUp {
        t.Errorf("state = %v, want up", got)
    }
}

func TestRegisterRejectsUnknownPlugin(t *testing.T) {
    f := newHostFixture(t)
    stream, err := f.client.Register(context.Background(), &pluginv1.RegisterReq{Id: "ghost", HttpPort: 1})
    if err == nil {
        _, err = stream.Recv()
    }
    if err == nil {
        t.Fatal("expected an error registering an undiscovered plugin")
    }
}

// The stream's second job: delivering subscribed bus events.
func TestRegisterStreamDeliversSubscribedEvents(t *testing.T) {
    f := newHostFixture(t,
        Manifest{ID: "sensor", Name: "S", Exec: "./s", UI: "none", Publishes: []string{"t.v1"}},
        Manifest{ID: "sink", Name: "K", Exec: "./k", UI: "none", Subscribes: []string{"t.v1"}},
    )

    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    stream, err := f.client.Register(ctx, &pluginv1.RegisterReq{Id: "sink", HttpPort: 1})
    if err != nil {
        t.Fatal(err)
    }
    if msg, err := stream.Recv(); err != nil || msg.GetReady() == nil {
        t.Fatalf("want Ready first: %+v %v", msg, err)
    }

    ts := time.Unix(1700000000, 0)
    if _, err := f.client.Publish(asPlugin("sensor"), &pluginv1.Event{
        Topic: "t.v1", Payload: []byte("hi"), Ts: timestamppb.New(ts),
    }); err != nil {
        t.Fatalf("Publish: %v", err)
    }

    msg, err := stream.Recv()
    if err != nil {
        t.Fatal(err)
    }
    ev := msg.GetEvent()
    if ev == nil || ev.Topic != "t.v1" || string(ev.Payload) != "hi" {
        t.Fatalf("event = %+v", msg)
    }
    if got := f.reg.Snapshot(); got[0].EventsPublished != 1 && got[1].EventsPublished != 1 {
        t.Error("publish was not counted against the publisher")
    }
}

func TestPublishWithoutAttributionIsRejected(t *testing.T) {
    f := newHostFixture(t, Manifest{ID: "sensor", Name: "S", Exec: "./s", UI: "none", Publishes: []string{"t.v1"}})
    if _, err := f.client.Publish(context.Background(), &pluginv1.Event{Topic: "t.v1"}); err == nil {
        t.Fatal("expected an error for an unattributed Publish")
    }
}

func TestPublishUndeclaredTopicIsRejectedOverRPC(t *testing.T) {
    f := newHostFixture(t, Manifest{ID: "sensor", Name: "S", Exec: "./s", UI: "none", Publishes: []string{"declared.v1"}})
    if _, err := f.client.Publish(asPlugin("sensor"), &pluginv1.Event{Topic: "sneaky.v1"}); err == nil {
        t.Fatal("expected an error publishing an undeclared topic")
    }
}

func TestAlertReachesIntentSubscribers(t *testing.T) {
    f := newHostFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
    ch, cancel := f.intents.Subscribe()
    defer cancel()

    _, err := f.client.Alert(asPlugin("alpha"), &pluginv1.AlertReq{
        Title: "Break time", Body: "Stand up", Level: "info",
        Actions: []*pluginv1.AlertAction{{Label: "Snooze", Url: "snooze"}},
    })
    if err != nil {
        t.Fatal(err)
    }

    select {
    case a := <-ch:
        if a.Plugin != "alpha" || a.Title != "Break time" || a.Level != "info" {
            t.Fatalf("alert = %+v", a)
        }
        if len(a.Actions) != 1 || a.Actions[0].Label != "Snooze" || a.Actions[0].Url != "snooze" {
            t.Fatalf("actions = %+v", a.Actions)
        }
    case <-time.After(time.Second):
        t.Fatal("alert never reached the intents fan-out")
    }
}

// Alerts are transient: a client that connects after one fired does not
// see it.
func TestAlertsAreNotRetained(t *testing.T) {
    f := newHostFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
    f.client.Alert(asPlugin("alpha"), &pluginv1.AlertReq{Title: "early"})
    time.Sleep(50 * time.Millisecond)

    ch, cancel := f.intents.Subscribe()
    defer cancel()
    select {
    case a := <-ch:
        t.Fatalf("late subscriber received a retained alert: %+v", a)
    case <-time.After(200 * time.Millisecond):
    }
}

// A dropped stream means the plugin is reconnecting, not dead — the
// supervisor owns down/failed.
func TestStreamLossMovesPluginToStarting(t *testing.T) {
    f := newHostFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
    ctx, cancel := context.WithCancel(context.Background())
    stream, err := f.client.Register(ctx, &pluginv1.RegisterReq{Id: "alpha", HttpPort: 1})
    if err != nil {
        t.Fatal(err)
    }
    stream.Recv() // Ready
    cancel()

    deadline := time.Now().Add(2 * time.Second)
    for time.Now().Before(deadline) {
        if got, _ := f.reg.State("alpha"); got == StateStarting {
            if d := f.reg.Snapshot()[0].Detail; d != "reconnecting" {
                t.Fatalf("detail = %q, want reconnecting", d)
            }
            return
        }
        time.Sleep(20 * time.Millisecond)
    }
    got, _ := f.reg.State("alpha")
    t.Fatalf("state = %v after stream loss, want starting", got)
}

func TestBroadcastShutdownReachesPlugins(t *testing.T) {
    f := newHostFixture(t, Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    stream, err := f.client.Register(ctx, &pluginv1.RegisterReq{Id: "alpha", HttpPort: 1})
    if err != nil {
        t.Fatal(err)
    }
    stream.Recv() // Ready

    go f.host.BroadcastShutdown("core shutting down")

    msg, err := stream.Recv()
    if err != nil {
        t.Fatal(err)
    }
    sd := msg.GetShutdown()
    if sd == nil || sd.Reason != "core shutting down" {
        t.Fatalf("message = %+v, want Shutdown", msg)
    }
}
```

Add `"google.golang.org/protobuf/types/known/timestamppb"` to the import block above, and add `google.golang.org/grpc/test/bufconn` to the module:

Run: `cd backend && go get google.golang.org/grpc/test/bufconn && go mod tidy`
Expected: `bufconn` is part of the existing `google.golang.org/grpc` module, so this is a no-op that confirms it resolves.

- [ ] **Step 2: Write `backend/kernel/intents.go`**

```go
package kernel

import (
    "sync"

    clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
    "go.uber.org/zap"
)

// intentChanCap bounds one client's pending alerts. Alerts are transient
// and user-facing; a backlog of them is noise, not data worth keeping.
const intentChanCap = 16

type intentSub struct {
    ch     chan *clientv1.Alert
    closed bool
}

// Intents fans alerts out to every connected client. Alerts are the one UI
// path that is not HTML, because they must render with no window open and
// with the plugin's webview never loaded.
//
// Nothing is retained: a client that connects after an alert fired does not
// see it.
type Intents struct {
    log *zap.Logger

    mu   sync.Mutex
    subs map[*intentSub]struct{}
}

func NewIntents(log *zap.Logger) *Intents {
    return &Intents{log: log, subs: map[*intentSub]struct{}{}}
}

func (i *Intents) Subscribe() (<-chan *clientv1.Alert, func()) {
    s := &intentSub{ch: make(chan *clientv1.Alert, intentChanCap)}
    i.mu.Lock()
    i.subs[s] = struct{}{}
    i.mu.Unlock()

    var once sync.Once
    return s.ch, func() {
        once.Do(func() {
            i.mu.Lock()
            defer i.mu.Unlock()
            delete(i.subs, s)
            s.closed = true
            close(s.ch)
        })
    }
}

func (i *Intents) Broadcast(a *clientv1.Alert) {
    i.mu.Lock()
    defer i.mu.Unlock()
    for s := range i.subs {
        if s.closed {
            continue
        }
        select {
        case s.ch <- a:
        default:
            i.log.Warn("dropping alert for a client that is not keeping up",
                zap.String("plugin", a.GetPlugin()))
        }
    }
}
```

- [ ] **Step 3: Write `backend/kernel/rpc.go`**

```go
package kernel

import (
    "context"
    "sync"

    "github.com/vibecare-io/vibecare/backend/pkg/pluginwire"
    clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
    pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
    "go.uber.org/zap"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/metadata"
    "google.golang.org/grpc/status"
    "google.golang.org/protobuf/types/known/emptypb"
    "google.golang.org/protobuf/types/known/timestamppb"
)

// Host implements PluginHost, the only gRPC surface plugins ever touch.
// Three RPCs, one of them a stream. A plugin author writes an HTTP server
// — trivial in every language — plus these three outbound calls, and never
// implements a service.
type Host struct {
    pluginv1.UnimplementedPluginHostServer

    reg     *Registry
    bus     *Bus
    sup     *Supervisor
    health  *Health
    intents *Intents
    log     *zap.Logger

    mu      sync.Mutex
    streams map[string]chan *pluginv1.CoreMsg // plugin id -> its stream's outbox
}

func NewHost(reg *Registry, bus *Bus, sup *Supervisor, h *Health, in *Intents, log *zap.Logger) *Host {
    return &Host{
        reg: reg, bus: bus, sup: sup, health: h, intents: in, log: log,
        streams: map[string]chan *pluginv1.CoreMsg{},
    }
}

// Register is the plugin's whole control plane. One open stream does three
// jobs: confirms registration, delivers subscribed events, and signals
// graceful shutdown.
func (h *Host) Register(req *pluginv1.RegisterReq, stream pluginv1.PluginHost_RegisterServer) error {
    id := req.GetId()
    if _, known := h.reg.Manifest(id); !known {
        return status.Errorf(codes.NotFound, "no discovered plugin with id %q", id)
    }
    if req.GetHttpPort() == 0 {
        return status.Error(codes.InvalidArgument, "http_port is required")
    }

    h.reg.SetPort(id, req.GetHttpPort())
    h.sup.NotifyRegistered(id)
    h.health.Reset(id)

    // Core-originated messages (currently only Shutdown) go through this
    // outbox so BroadcastShutdown never blocks on a wedged plugin.
    out := make(chan *pluginv1.CoreMsg, 4)
    h.mu.Lock()
    h.streams[id] = out
    h.mu.Unlock()

    events, unsubscribe := h.bus.Subscribe(id)

    defer func() {
        unsubscribe()
        h.mu.Lock()
        if cur, ok := h.streams[id]; ok && cur == out {
            delete(h.streams, id)
        }
        h.mu.Unlock()

        // A dropped stream does NOT mean the process died — the SDK
        // reconnects without exiting, which is what makes a core restart
        // survivable. Only reflect it if the supervisor hasn't already
        // decided the plugin is down or failed.
        if cur, ok := h.reg.State(id); ok && (cur == StateUp || cur == StateDegraded) {
            h.reg.SetState(id, StateStarting, "reconnecting")
        }
    }()

    if err := stream.Send(&pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Ready{Ready: &pluginv1.Ready{}}}); err != nil {
        return err
    }
    h.reg.SetState(id, StateUp, "")
    h.log.Info("plugin registered", zap.String("plugin", id), zap.Uint32("http_port", req.GetHttpPort()))

    for {
        select {
        case <-stream.Context().Done():
            return stream.Context().Err()

        case msg := <-out:
            if err := stream.Send(msg); err != nil {
                return err
            }

        case e, ok := <-events:
            if !ok {
                return nil
            }
            err := stream.Send(&pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Event{Event: &pluginv1.Event{
                Topic:   e.Topic,
                Payload: e.Payload,
                Ts:      timestamppb.New(e.TS),
            }}})
            if err != nil {
                return err
            }
        }
    }
}

// Publish moves an event onto the bus. The caller is attributed from call
// metadata: Event carries no plugin field, and trusting a self-declared one
// would make the manifest's publishes list meaningless.
func (h *Host) Publish(ctx context.Context, e *pluginv1.Event) (*emptypb.Empty, error) {
    id, err := callerID(ctx)
    if err != nil {
        return nil, err
    }
    if _, known := h.reg.Manifest(id); !known {
        return nil, status.Errorf(codes.PermissionDenied, "unknown plugin %q", id)
    }

    ts := e.GetTs().AsTime()
    if !e.GetTs().IsValid() {
        ts = timestamppb.Now().AsTime()
    }

    // Delivery counts are attributed to each SUBSCRIBER by the bus's
    // OnDelivered hook (wired in kernel.go), so nothing is counted here
    // beyond the publish itself.
    if _, err := h.bus.Publish(id, e.GetTopic(), e.GetPayload(), ts); err != nil {
        // Manifests stay honest: the message is dropped and the author is
        // told why, rather than silently vanishing.
        h.log.Error("rejected publish", zap.String("plugin", id), zap.String("topic", e.GetTopic()), zap.Error(err))
        return nil, status.Error(codes.InvalidArgument, err.Error())
    }
    h.reg.CountPublished(id)
    return &emptypb.Empty{}, nil
}

// Alert hands a user-facing notification to every connected client.
func (h *Host) Alert(ctx context.Context, r *pluginv1.AlertReq) (*emptypb.Empty, error) {
    id, err := callerID(ctx)
    if err != nil {
        return nil, err
    }
    if _, known := h.reg.Manifest(id); !known {
        return nil, status.Errorf(codes.PermissionDenied, "unknown plugin %q", id)
    }

    h.intents.Broadcast(&clientv1.Alert{
        Plugin:  id,
        Title:   r.GetTitle(),
        Body:    r.GetBody(),
        Level:   r.GetLevel(),
        Actions: r.GetActions(),
    })
    return &emptypb.Empty{}, nil
}

// BroadcastShutdown tells every connected plugin to close its listener and
// flush storage. Core follows it with SIGTERM (see Supervisor.Stop).
func (h *Host) BroadcastShutdown(reason string) {
    h.mu.Lock()
    outs := make([]chan *pluginv1.CoreMsg, 0, len(h.streams))
    for _, out := range h.streams {
        outs = append(outs, out)
    }
    h.mu.Unlock()

    msg := &pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Shutdown{Shutdown: &pluginv1.Shutdown{Reason: reason}}}
    for _, out := range outs {
        select {
        case out <- msg:
        default: // wedged plugin; SIGTERM/SIGKILL will handle it
        }
    }
}

// callerID reads the plugin id the SDK attaches to every outbound call.
func callerID(ctx context.Context) (string, error) {
    md, ok := metadata.FromIncomingContext(ctx)
    if !ok {
        return "", status.Error(codes.Unauthenticated, "missing call metadata")
    }
    vals := md.Get(pluginwire.PluginIDMetadataKey)
    if len(vals) == 0 || vals[0] == "" {
        return "", status.Error(codes.Unauthenticated, "missing plugin id in call metadata")
    }
    return vals[0], nil
}
```

- [ ] **Step 4: Write `backend/kernel/shell.go`**

```go
package kernel

import (
    clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
    "google.golang.org/protobuf/types/known/emptypb"
)

// ShellService is the entire client-facing plugin contract: a roster
// stream and an alert stream. It is frozen at two RPCs while plugins are
// added indefinitely, because clients contain no plugin-specific code —
// a client knows only "a URL", never a schema.
type ShellService struct {
    clientv1.UnimplementedShellServer

    reg     *Registry
    intents *Intents
    baseURL func() string
    token   string
}

func NewShellService(reg *Registry, in *Intents, baseURL func() string, token string) *ShellService {
    return &ShellService{reg: reg, intents: in, baseURL: baseURL, token: token}
}

// Plugins streams the roster: the current one immediately, then the whole
// list again on any state change. The roster is small and changes rarely,
// so there is no need for deltas.
func (s *ShellService) Plugins(_ *emptypb.Empty, stream clientv1.Shell_PluginsServer) error {
    updates, cancel := s.reg.Watch()
    defer cancel()

    for {
        select {
        case <-stream.Context().Done():
            return stream.Context().Err()
        case snap, ok := <-updates:
            if !ok {
                return nil
            }
            if err := stream.Send(s.toPluginList(snap)); err != nil {
                return err
            }
        }
    }
}

func (s *ShellService) toPluginList(snap []PluginStat) *clientv1.PluginList {
    out := &clientv1.PluginList{BaseUrl: s.baseURL(), Token: s.token}
    for _, p := range snap {
        // A headless plugin gets no tab — that is what ui: none means.
        if p.UI == "none" {
            continue
        }
        out.Plugins = append(out.Plugins, &clientv1.PluginInfo{
            Id:     p.ID,
            Name:   p.Name,
            Icon:   p.Icon,
            Path:   p.Path,
            State:  toProtoState(p.State),
            Detail: p.Detail,
        })
    }
    return out
}

func toProtoState(s State) clientv1.State {
    switch s {
    case StateUp:
        return clientv1.State_UP
    case StateDegraded:
        return clientv1.State_DEGRADED
    case StateDown:
        return clientv1.State_DOWN
    case StateFailed:
        return clientv1.State_FAILED
    default:
        return clientv1.State_STARTING
    }
}

// Intents streams alerts. They are transient and never retained.
func (s *ShellService) Intents(_ *emptypb.Empty, stream clientv1.Shell_IntentsServer) error {
    alerts, cancel := s.intents.Subscribe()
    defer cancel()

    for {
        select {
        case <-stream.Context().Done():
            return stream.Context().Err()
        case a, ok := <-alerts:
            if !ok {
                return nil
            }
            err := stream.Send(&clientv1.UIIntent{K: &clientv1.UIIntent_Alert{Alert: a}})
            if err != nil {
                return err
            }
        }
    }
}
```

- [ ] **Step 5: Write the `ShellService` tests**

`backend/kernel/shell_test.go`:

```go
package kernel

import (
    "testing"

    "go.uber.org/zap"
    clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
)

func TestToPluginListCarriesOriginAndToken(t *testing.T) {
    reg := NewRegistry(zap.NewNop())
    reg.Add(Manifest{ID: "alpha", Name: "Alpha", Icon: "circle", Exec: "./a", UI: "webview"})
    s := NewShellService(reg, NewIntents(zap.NewNop()), func() string { return "http://127.0.0.1:52341" }, "tok123")

    got := s.toPluginList(reg.Snapshot())
    if got.BaseUrl != "http://127.0.0.1:52341" || got.Token != "tok123" {
        t.Fatalf("list = %+v", got)
    }
    if len(got.Plugins) != 1 {
        t.Fatalf("got %d plugins", len(got.Plugins))
    }
    p := got.Plugins[0]
    if p.Id != "alpha" || p.Name != "Alpha" || p.Icon != "circle" || p.Path != "/p/alpha/" {
        t.Fatalf("plugin = %+v", p)
    }
    if p.State != clientv1.State_STARTING {
        t.Fatalf("state = %v, want STARTING", p.State)
    }
}

// ui: none means "no tab in the client" — the plugin still runs, it just
// never appears in the roster.
func TestHeadlessPluginsAreNotInTheRoster(t *testing.T) {
    reg := NewRegistry(zap.NewNop())
    reg.Add(Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
    reg.Add(Manifest{ID: "sensor", Name: "Sensor", Exec: "./s", UI: "none"})
    s := NewShellService(reg, NewIntents(zap.NewNop()), func() string { return "" }, "")

    got := s.toPluginList(reg.Snapshot())
    if len(got.Plugins) != 1 || got.Plugins[0].Id != "alpha" {
        t.Fatalf("roster = %+v, want only the webview plugin", got.Plugins)
    }
}

func TestStateMapping(t *testing.T) {
    want := map[State]clientv1.State{
        StateStarting: clientv1.State_STARTING,
        StateUp:       clientv1.State_UP,
        StateDegraded: clientv1.State_DEGRADED,
        StateDown:     clientv1.State_DOWN,
        StateFailed:   clientv1.State_FAILED,
    }
    for in, out := range want {
        if got := toProtoState(in); got != out {
            t.Errorf("toProtoState(%v) = %v, want %v", in, got, out)
        }
    }
}

// The exit reason must survive into the roster, or a client showing an
// error page has nothing to say.
func TestDetailSurvivesIntoTheRoster(t *testing.T) {
    reg := NewRegistry(zap.NewNop())
    reg.Add(Manifest{ID: "alpha", Name: "Alpha", Exec: "./a", UI: "webview"})
    reg.SetState("alpha", StateFailed, "5 consecutive failed starts")
    s := NewShellService(reg, NewIntents(zap.NewNop()), func() string { return "" }, "")

    got := s.toPluginList(reg.Snapshot())
    if got.Plugins[0].Detail != "5 consecutive failed starts" {
        t.Fatalf("detail = %q", got.Plugins[0].Detail)
    }
}
```

- [ ] **Step 6: Write the D10 guard test**

`backend/kernel/d10_test.go`:

```go
package kernel

import (
    "os"
    "path/filepath"
    "strings"
    "testing"
)

// D10: core contains zero product semantics. No file in kernel/ may name a
// specific plugin or the domain it models — the kernel is a supervisor, a
// bus, a proxy, and a dashboard, all of which are generic infrastructure.
//
// The spec says this is "checkable by grep". This is that grep, run in CI.
func TestKernelContainsNoProductNouns(t *testing.T) {
    forbidden := []string{
        "posture", "nailbiting", "nail-biting", "todo",
        "vibecheck", "detection", "behavior", "behaviour",
    }

    entries, err := os.ReadDir(".")
    if err != nil {
        t.Fatal(err)
    }
    for _, e := range entries {
        if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") {
            continue
        }
        // This file necessarily contains the words it forbids.
        if e.Name() == "d10_test.go" {
            continue
        }
        b, err := os.ReadFile(filepath.Join(".", e.Name()))
        if err != nil {
            t.Fatal(err)
        }
        lower := strings.ToLower(string(b))
        for _, word := range forbidden {
            if strings.Contains(lower, word) {
                t.Errorf("%s contains product noun %q — the kernel must stay generic (D10)", e.Name(), word)
            }
        }
    }
}
```

- [ ] **Step 7: Run the whole package**

Run: `cd backend && go test ./kernel/ -race -v -timeout 180s`
Expected: PASS, including `TestKernelContainsNoProductNouns`. If the D10 test flags a real file, rename the offending identifier or comment rather than weakening the word list.

- [ ] **Step 8: Commit**

```bash
git add backend/kernel/rpc.go backend/kernel/intents.go backend/kernel/shell.go \
        backend/kernel/rpc_test.go backend/kernel/shell_test.go backend/kernel/d10_test.go
git commit -m "feat(kernel): PluginHost and Shell gRPC services with alert fan-out"
```

---

### Task 10: Kernel facade and wiring into `cmd/server`

**Files:**
- Create: `backend/kernel/kernel.go`
- Test: `backend/kernel/kernel_test.go`
- Modify: `backend/cmd/server/main.go`
- Modify: `Justfile` (the `run` recipe)

**Interfaces:**
- Consumes: everything from Tasks 2–9.
- Produces:
  ```go
  type Config struct {
      PluginsDir  string // scanned for <id>/manifest.yaml
      DataRoot    string // ~/.vibecare/data
      SocketPath  string // ~/.vibecare/core.sock
      SessionPath string // ~/.vibecare/session
  }
  func DefaultConfig(home, pluginsDir string) Config

  type Kernel struct{ /* unexported */ }
  func New(cfg Config, log *zap.Logger) (*Kernel, error)
  func (k *Kernel) Start(ctx context.Context) error
  func (k *Kernel) BaseURL() string
  func (k *Kernel) Token() string
  func (k *Kernel) RegisterShell(s *grpc.Server)
  func (k *Kernel) Stop(ctx context.Context)
  ```

Design notes for the implementer:

- **Two listeners, two roles.** The unix socket carries `PluginHost` (plugins only). The loopback HTTP origin carries the proxy and the dashboard (clients only). `ShellService` rides on the *app's existing TCP gRPC server* via `RegisterShell`, because that is the connection the Swift client already has.
- **`RegisterShell` must be callable before `Start`.** `main.go` registers services on the gRPC server before it begins serving, but the kernel's HTTP port isn't known until `Start`. That is why `NewShellService` takes `baseURL func() string` rather than a string — it is resolved per-send, not at construction.
- **Stale socket files.** A previous core that was SIGKILLed leaves `core.sock` behind and `net.Listen("unix", …)` will refuse to bind. Remove the path before listening. Chmod it `0600` after binding.
- **Shutdown order matters:** `BroadcastShutdown` → `Supervisor.Stop` (SIGTERM/SIGKILL) → stop the gRPC socket server → shut down HTTP → remove the socket file. Plugins get a chance to flush before anything is killed.
- **Kernel failure must not take down the server.** `main.go` logs a kernel start error and continues, exactly as it does today for the v1 registry.

- [ ] **Step 1: Write the failing tests**

```go
package kernel

import (
    "context"
    "net/http"
    "os"
    "path/filepath"
    "strings"
    "testing"

    "go.uber.org/zap"
)

func testConfig(t *testing.T) Config {
    t.Helper()
    home := t.TempDir()
    return Config{
        PluginsDir:  filepath.Join(home, "plugins"),
        DataRoot:    filepath.Join(home, "data"),
        SocketPath:  filepath.Join(home, "core.sock"),
        SessionPath: filepath.Join(home, "session"),
    }
}

func startKernel(t *testing.T, cfg Config) *Kernel {
    t.Helper()
    k, err := New(cfg, zap.NewNop())
    if err != nil {
        t.Fatal(err)
    }
    if err := k.Start(context.Background()); err != nil {
        t.Fatalf("Start: %v", err)
    }
    t.Cleanup(func() { k.Stop(context.Background()) })
    return k
}

func TestKernelBindsLoopbackAndUnixSocket(t *testing.T) {
    cfg := testConfig(t)
    k := startKernel(t, cfg)

    if !strings.HasPrefix(k.BaseURL(), "http://127.0.0.1:") {
        t.Fatalf("BaseURL = %q, want a loopback origin with a kernel-assigned port", k.BaseURL())
    }
    if strings.HasSuffix(k.BaseURL(), ":0") {
        t.Fatal("BaseURL still has the placeholder port; report the ACTUAL bound port")
    }

    fi, err := os.Stat(cfg.SocketPath)
    if err != nil {
        t.Fatalf("socket not created: %v", err)
    }
    if fi.Mode().Perm() != 0o600 {
        t.Fatalf("socket mode = %v, want 0600", fi.Mode().Perm())
    }
}

// A SIGKILLed core leaves the socket file behind; the next start must not
// be blocked by it.
func TestKernelRemovesStaleSocket(t *testing.T) {
    cfg := testConfig(t)
    if err := os.MkdirAll(filepath.Dir(cfg.SocketPath), 0o700); err != nil {
        t.Fatal(err)
    }
    if err := os.WriteFile(cfg.SocketPath, []byte("stale"), 0o600); err != nil {
        t.Fatal(err)
    }
    startKernel(t, cfg) // must not error
}

func TestKernelHTTPRequiresAuth(t *testing.T) {
    k := startKernel(t, testConfig(t))

    resp, err := http.Get(k.BaseURL() + "/_core/status")
    if err != nil {
        t.Fatal(err)
    }
    defer resp.Body.Close()
    if resp.StatusCode != http.StatusUnauthorized {
        t.Fatalf("unauthenticated dashboard = %d, want 401", resp.StatusCode)
    }
}

func TestKernelDashboardReachableWithToken(t *testing.T) {
    k := startKernel(t, testConfig(t))

    // Don't follow the post-handoff redirect; assert on the handoff itself.
    c := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
    resp, err := c.Get(k.BaseURL() + "/_core/status?" + tokenParam + "=" + k.Token())
    if err != nil {
        t.Fatal(err)
    }
    defer resp.Body.Close()
    if resp.StatusCode != http.StatusFound {
        t.Fatalf("code = %d, want 302 after the token handoff", resp.StatusCode)
    }

    req, _ := http.NewRequest("GET", k.BaseURL()+"/_core/status", nil)
    req.AddCookie(&http.Cookie{Name: sessionCookie, Value: k.Token()})
    resp2, err := c.Do(req)
    if err != nil {
        t.Fatal(err)
    }
    defer resp2.Body.Close()
    if resp2.StatusCode != http.StatusOK {
        t.Fatalf("code = %d with a valid cookie, want 200", resp2.StatusCode)
    }
}

// /_core/* is reserved and must never be routed to a plugin, even if one
// somehow claimed a colliding path.
func TestCorePathsAreNotProxied(t *testing.T) {
    k := startKernel(t, testConfig(t))
    c := &http.Client{}

    req, _ := http.NewRequest("GET", k.BaseURL()+"/_core/api/plugins", nil)
    req.AddCookie(&http.Cookie{Name: sessionCookie, Value: k.Token()})
    resp, err := c.Do(req)
    if err != nil {
        t.Fatal(err)
    }
    defer resp.Body.Close()
    if ct := resp.Header.Get("Content-Type"); !strings.Contains(ct, "application/json") {
        t.Fatalf("content-type = %q; /_core/* was routed somewhere other than the dashboard", ct)
    }
}

// Discovery happens in Start, so a manifest dropped in before boot appears
// in the roster with no registration step anywhere in core.
func TestKernelDiscoversPluginsAtStart(t *testing.T) {
    cfg := testConfig(t)
    dir := filepath.Join(cfg.PluginsDir, "alpha")
    if err := os.MkdirAll(dir, 0o755); err != nil {
        t.Fatal(err)
    }
    manifest := "id: alpha\nname: Alpha\nexec: ./missing-binary\nui: webview\n"
    if err := os.WriteFile(filepath.Join(dir, "manifest.yaml"), []byte(manifest), 0o644); err != nil {
        t.Fatal(err)
    }

    k := startKernel(t, cfg)
    got := k.Registry().Snapshot()
    if len(got) != 1 || got[0].ID != "alpha" {
        t.Fatalf("roster = %+v, want the dropped-in plugin", got)
    }
}

func TestStopIsIdempotent(t *testing.T) {
    cfg := testConfig(t)
    k := startKernel(t, cfg)
    k.Stop(context.Background())
    k.Stop(context.Background()) // must not panic or hang

    if _, err := os.Stat(cfg.SocketPath); !os.IsNotExist(err) {
        t.Fatal("socket file should be removed on Stop")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && go test ./kernel/ -run 'Kernel|CorePaths|StopIs'`
Expected: FAIL — undefined `New`, `Config`.

- [ ] **Step 3: Write `backend/kernel/kernel.go`**

```go
package kernel

import (
    "context"
    "fmt"
    "net"
    "net/http"
    "os"
    "path/filepath"
    "sync"
    "time"

    pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
    clientv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/client/v1"
    "go.uber.org/zap"
    "google.golang.org/grpc"
)

// Config is everything the kernel needs from its environment. Note what is
// absent: no ports. Every listener binds 127.0.0.1:0 and the kernel reports
// what it got, so there is nothing to configure and nothing to collide with.
type Config struct {
    PluginsDir  string
    DataRoot    string
    SocketPath  string
    SessionPath string
}

// DefaultConfig places the kernel's runtime state under the user's
// ~/.vibecare directory, alongside the database and logs.
func DefaultConfig(home, pluginsDir string) Config {
    base := filepath.Join(home, ".vibecare")
    return Config{
        PluginsDir:  pluginsDir,
        DataRoot:    filepath.Join(base, "data"),
        SocketPath:  filepath.Join(base, "core.sock"),
        SessionPath: filepath.Join(base, "session"),
    }
}

// Kernel wires the registry, bus, supervisor, health prober, proxy,
// dashboard, and both gRPC surfaces into one startable unit.
type Kernel struct {
    cfg Config
    log *zap.Logger

    reg     *Registry
    bus     *Bus
    sup     *Supervisor
    health  *Health
    intents *Intents
    auth    *Auth
    host    *Host
    shell   *ShellService

    httpSrv  *http.Server
    httpAddr string
    grpcSrv  *grpc.Server

    mu      sync.Mutex
    started bool
    stopped bool
    cancel  context.CancelFunc
}

func New(cfg Config, log *zap.Logger) (*Kernel, error) {
    auth, err := NewAuth(cfg.SessionPath)
    if err != nil {
        return nil, err
    }

    reg := NewRegistry(log)
    bus := NewBus(log)
    // Attribute deliveries to the receiving plugin without the bus needing
    // to know the registry exists.
    bus.OnDelivered(func(id string, n int) { reg.CountDelivered(id, n) })

    sup := NewSupervisor(reg, cfg.SocketPath, cfg.DataRoot, log)
    health := NewHealth(reg, log)
    intents := NewIntents(log)

    k := &Kernel{
        cfg: cfg, log: log,
        reg: reg, bus: bus, sup: sup, health: health, intents: intents, auth: auth,
    }
    k.host = NewHost(reg, bus, sup, health, intents, log)
    // BaseURL is resolved per-send rather than captured, because
    // RegisterShell runs before Start knows the HTTP port.
    k.shell = NewShellService(reg, intents, k.BaseURL, auth.Token())
    return k, nil
}

func (k *Kernel) Registry() *Registry { return k.reg }
func (k *Kernel) Token() string       { return k.auth.Token() }

func (k *Kernel) BaseURL() string {
    k.mu.Lock()
    defer k.mu.Unlock()
    if k.httpAddr == "" {
        return ""
    }
    return "http://" + k.httpAddr
}

// RegisterShell installs the client-facing service on the app's existing
// TCP gRPC server — the connection clients already have. Safe to call
// before Start.
func (k *Kernel) RegisterShell(s *grpc.Server) {
    clientv1.RegisterShellServer(s, k.shell)
}

// Start discovers plugins, binds both listeners, and spawns everything.
func (k *Kernel) Start(ctx context.Context) error {
    k.mu.Lock()
    if k.started {
        k.mu.Unlock()
        return nil
    }
    k.started = true
    k.mu.Unlock()

    manifests, err := Discover(k.cfg.PluginsDir)
    if err != nil {
        return err
    }
    for _, m := range manifests {
        k.reg.Add(m)
        k.bus.Declare(m.ID, m.Subscribes, m.Publishes)
    }
    k.log.Info("discovered plugins",
        zap.String("dir", k.cfg.PluginsDir), zap.Int("count", len(manifests)))

    // Loopback HTTP: the proxy and the dashboard, both behind one auth
    // check. /_core/* is matched first and is never proxied.
    mux := http.NewServeMux()
    mux.Handle(corePrefix, NewStatusHandler(k.reg, k.sup))
    mux.Handle(proxyPrefix, NewProxy(k.reg, k.log))

    lis, err := net.Listen("tcp", "127.0.0.1:0")
    if err != nil {
        return fmt.Errorf("bind kernel http: %w", err)
    }
    k.mu.Lock()
    k.httpAddr = lis.Addr().String()
    k.httpSrv = &http.Server{Handler: k.auth.Middleware(mux)}
    k.mu.Unlock()
    go func() {
        if err := k.httpSrv.Serve(lis); err != nil && err != http.ErrServerClosed {
            k.log.Error("kernel http server stopped", zap.Error(err))
        }
    }()
    k.log.Info("kernel http listening", zap.String("origin", k.BaseURL()))

    // Unix socket: PluginHost, and nothing else. A previous core that was
    // SIGKILLed leaves the path behind, which would block the bind.
    if err := os.MkdirAll(filepath.Dir(k.cfg.SocketPath), 0o700); err != nil {
        return fmt.Errorf("create socket dir: %w", err)
    }
    if err := os.Remove(k.cfg.SocketPath); err != nil && !os.IsNotExist(err) {
        return fmt.Errorf("remove stale socket: %w", err)
    }
    sock, err := net.Listen("unix", k.cfg.SocketPath)
    if err != nil {
        return fmt.Errorf("bind plugin socket: %w", err)
    }
    if err := os.Chmod(k.cfg.SocketPath, 0o600); err != nil {
        return fmt.Errorf("chmod plugin socket: %w", err)
    }
    k.mu.Lock()
    k.grpcSrv = grpc.NewServer()
    k.mu.Unlock()
    pluginv1.RegisterPluginHostServer(k.grpcSrv, k.host)
    go func() {
        if err := k.grpcSrv.Serve(sock); err != nil {
            k.log.Error("plugin socket server stopped", zap.Error(err))
        }
    }()

    runCtx, cancel := context.WithCancel(ctx)
    k.mu.Lock()
    k.cancel = cancel
    k.mu.Unlock()

    k.health.Start(runCtx)
    k.sup.Start(runCtx)
    return nil
}

// Stop tears the kernel down in the order that gives plugins the best
// chance to flush: tell them, then terminate them, then close core's own
// listeners.
func (k *Kernel) Stop(ctx context.Context) {
    k.mu.Lock()
    if k.stopped || !k.started {
        k.stopped = true
        k.mu.Unlock()
        return
    }
    k.stopped = true
    httpSrv, grpcSrv, cancel := k.httpSrv, k.grpcSrv, k.cancel
    k.mu.Unlock()

    k.host.BroadcastShutdown("core shutting down")
    k.sup.Stop(ctx)

    if cancel != nil {
        cancel()
    }
    if grpcSrv != nil {
        stopped := make(chan struct{})
        go func() { grpcSrv.GracefulStop(); close(stopped) }()
        select {
        case <-stopped:
        case <-time.After(3 * time.Second):
            grpcSrv.Stop()
        }
    }
    if httpSrv != nil {
        _ = httpSrv.Shutdown(ctx)
    }
    _ = os.Remove(k.cfg.SocketPath)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && go test ./kernel/ -race -v -timeout 180s`
Expected: PASS.

- [ ] **Step 5: Wire the kernel into `backend/cmd/server/main.go`**

Add the flag next to the others in the `flag` block:

```go
		pluginsDir    = flag.String("plugins-dir", "", "Directory scanned for <id>/manifest.yaml plugins (default ~/.vibecare/plugins)")
```

Add the import:

```go
	"github.com/vibecare-io/vibecare/backend/kernel"
```

Immediately after the existing v1 `pluginRegistry := plugins.NewRegistry(...)` line, construct the kernel. Both systems coexist until Task 13 removes v1:

```go
	// v2 plugin kernel. It runs alongside the v1 registry above until the
	// Swift client migrates to the webview shell (see
	// docs/superpowers/plans/2026-08-13-plugin-architecture-v2-kernel.md).
	// Its HTTP origin and unix socket are independent of Core's gRPC and
	// web ports — the kernel binds 127.0.0.1:0 for both.
	kernelPluginsDir := *pluginsDir
	if kernelPluginsDir == "" {
		kernelPluginsDir = filepath.Join(homeDir, ".vibecare", "plugins")
	}
	kernelCfg := kernel.DefaultConfig(homeDir, kernelPluginsDir)
	k, err := kernel.New(kernelCfg, logger)
	if err != nil {
		logger.Warn("Failed to create plugin kernel; continuing without it", zap.Error(err))
		k = nil
	}
```

Register the Shell service alongside the others, right after `api.RegisterServices(...)`:

```go
	// The client-facing plugin contract (roster + alerts) rides on the same
	// TCP gRPC server the client already connects to.
	if k != nil {
		k.RegisterShell(grpcServer)
	}
```

Start the kernel where the v1 registry starts, after `grpcServer.Serve` is running:

```go
	// A kernel failure must not take down the server, exactly as a v1
	// registry failure doesn't.
	if k != nil {
		logger.Info("Starting plugin kernel", zap.String("dir", kernelCfg.PluginsDir))
		if err := k.Start(context.Background()); err != nil {
			logger.Warn("Failed to start plugin kernel; continuing without it", zap.Error(err))
		} else {
			logger.Info("Plugin kernel ready", zap.String("origin", k.BaseURL()))
		}
	}
```

And in the shutdown goroutine, before `pluginRegistry.Stop()`:

```go
		if k != nil {
			logger.Info("Stopping plugin kernel...")
			k.Stop(ctx)
		}
```

- [ ] **Step 6: Point the dev server at the repo's `plugins/` and clear the stale v1 plugin**

In `Justfile`, change the `run` recipe so a plugin dropped into the repo's `plugins/` directory is picked up without installing anything:

```just
run: proto-gen
    @echo "{{GREEN}}Starting VibeCare server...{{NC}}"
    cd {{backend_dir}} && go run cmd/server/main.go --enable-tracing --log-level debug --plugins-dir ../plugins
```

`plugins/vibecheck/` is a **v1** shell-native plugin: its manifest declares `id: com.vibecare.vibecheck`, which the v2 id regex rejects, and one invalid manifest fails the whole discovery scan. It must go before the kernel can scan `plugins/`. Its functionality is re-created against v2 in spec §16 step 5, which is out of scope here; the code stays in git history.

```bash
git rm -r plugins/vibecheck
```

- [ ] **Step 7: Verify the server boots with the kernel**

Run: `cd backend && go build ./... && go vet ./kernel/...`
Expected: success.

Run: `just run` in one terminal; look for `Plugin kernel ready` with an `origin` like `http://127.0.0.1:5xxxx`, then stop it with Ctrl-C.
Expected: startup logs `discovered plugins dir=../plugins count=0`, then `Plugin kernel ready`. Shutdown logs `Stopping plugin kernel...` and exits cleanly, leaving no `~/.vibecare/core.sock` behind.

Run: `ls ~/.vibecare/core.sock`
Expected: `No such file or directory` — the socket is removed on clean shutdown.

- [ ] **Step 8: Commit**

```bash
git add backend/kernel/kernel.go backend/kernel/kernel_test.go backend/cmd/server/main.go Justfile
git commit -m "feat(kernel): kernel facade wired into the server process

Removes the v1 shell-native plugins/vibecheck, whose manifest id is
invalid under v2 and blocked discovery. Re-created against v2 later."
```

---

### Task 11: The plugin SDK (`backend/pkg/vc`)

**Files:**
- Create: `backend/pkg/vc/vc.go`
- Test: `backend/pkg/vc/vc_test.go`

**Interfaces:**
- Consumes: `pluginv1` (Task 1), `pluginwire.PluginIDMetadataKey` (existing).
- Produces:
  ```go
  package vc

  type Event struct {
      Topic   string
      Payload []byte
      TS      time.Time
  }

  type Alert struct {
      Title, Body, Level string
      Actions            []AlertAction
  }
  type AlertAction struct{ Label, URL string }

  type Handle struct {
      ID       string
      DataDir  string
      Listener net.Listener
      Events   <-chan Event
  }

  func Connect() (*Handle, error)
  func (h *Handle) Publish(topic string, payload []byte) error
  func (h *Handle) PublishProto(topic string, m proto.Message) error
  func (h *Handle) Alert(a Alert) error
  func (h *Handle) OnShutdown(fn func())
  func (h *Handle) SetHealth(fn func() (status, detail string))
  func (h *Handle) Serve(mux *http.ServeMux) error
  func (h *Handle) Close() error
  ```

Design notes for the implementer:

- **This is the whole plugin-author surface.** A plugin author writes an HTTP server plus these calls. No generated service stubs to implement, no bidi multiplexing, no reflection — which is what makes the "~50 lines for a provider plugin" claim literally true and non-Go plugins genuinely cheap.
- **`Connect` binds `127.0.0.1:0` before registering,** because `RegisterReq.http_port` must carry the port the kernel actually assigned.
- **`Connect` registers `/health` on `http.DefaultServeMux`,** so the worked example's `http.Serve(h.Listener, nil)` works with no health code in the plugin at all. `h.Serve(mux)` does the same for an explicit mux.
- **Reconnection is the SDK's job and the plugin never sees it.** If the Register stream drops, the plugin does **not** exit — it keeps serving HTTP and re-dials with backoff 1s, 2s, 4s, capped at 30s. Without this, restarting core would kill every running plugin, which would make `vibecare dev` unusable.
- **Every outbound call carries the plugin id** as `pluginwire.PluginIDMetadataKey` metadata; core attributes publishes and alerts from it.
- **`Events` is buffered and lossy on the plugin side too.** A plugin that stops reading gets dropped events, matching the bus's fire-and-forget contract rather than silently growing memory.

- [ ] **Step 1: Write the failing tests**

```go
package vc

import (
    "context"
    "net"
    "net/http"
    "os"
    "path/filepath"
    "sync"
    "testing"
    "time"

    "github.com/vibecare-io/vibecare/backend/pkg/pluginwire"
    pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
    "google.golang.org/grpc"
    "google.golang.org/grpc/metadata"
    "google.golang.org/protobuf/types/known/emptypb"
)

// fakeCore is a minimal PluginHost server: enough to exercise the SDK
// without dragging the kernel into the SDK's tests.
type fakeCore struct {
    pluginv1.UnimplementedPluginHostServer

    mu         sync.Mutex
    registered []*pluginv1.RegisterReq
    published  []*pluginv1.Event
    publishIDs []string
    alerts     []*pluginv1.AlertReq
    alertIDs   []string
    streams    []pluginv1.PluginHost_RegisterServer
    connects   int
}

func (f *fakeCore) Register(req *pluginv1.RegisterReq, stream pluginv1.PluginHost_RegisterServer) error {
    f.mu.Lock()
    f.registered = append(f.registered, req)
    f.streams = append(f.streams, stream)
    f.connects++
    f.mu.Unlock()

    if err := stream.Send(&pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Ready{Ready: &pluginv1.Ready{}}}); err != nil {
        return err
    }
    <-stream.Context().Done()
    return stream.Context().Err()
}

func (f *fakeCore) Publish(ctx context.Context, e *pluginv1.Event) (*emptypb.Empty, error) {
    f.mu.Lock()
    defer f.mu.Unlock()
    f.published = append(f.published, e)
    f.publishIDs = append(f.publishIDs, idFrom(ctx))
    return &emptypb.Empty{}, nil
}

func (f *fakeCore) Alert(ctx context.Context, a *pluginv1.AlertReq) (*emptypb.Empty, error) {
    f.mu.Lock()
    defer f.mu.Unlock()
    f.alerts = append(f.alerts, a)
    f.alertIDs = append(f.alertIDs, idFrom(ctx))
    return &emptypb.Empty{}, nil
}

// send pushes a core-originated message down the newest open stream.
func (f *fakeCore) send(msg *pluginv1.CoreMsg) {
    f.mu.Lock()
    defer f.mu.Unlock()
    if len(f.streams) == 0 {
        return
    }
    f.streams[len(f.streams)-1].Send(msg)
}

func idFrom(ctx context.Context) string {
    md, ok := metadata.FromIncomingContext(ctx)
    if !ok {
        return ""
    }
    v := md.Get(pluginwire.PluginIDMetadataKey)
    if len(v) == 0 {
        return ""
    }
    return v[0]
}

// coreFixture starts a fakeCore on a unix socket and sets the three spawn
// env vars, exactly as the supervisor would.
func coreFixture(t *testing.T, id string) (*fakeCore, *grpc.Server) {
    t.Helper()
    dir := t.TempDir()
    sock := filepath.Join(dir, "core.sock")
    dataDir := filepath.Join(dir, "data", id)
    if err := os.MkdirAll(dataDir, 0o700); err != nil {
        t.Fatal(err)
    }

    lis, err := net.Listen("unix", sock)
    if err != nil {
        t.Fatal(err)
    }
    core := &fakeCore{}
    srv := grpc.NewServer()
    pluginv1.RegisterPluginHostServer(srv, core)
    go srv.Serve(lis)
    t.Cleanup(srv.Stop)

    t.Setenv("VIBECARE_SOCKET", sock)
    t.Setenv("VIBECARE_PLUGIN_ID", id)
    t.Setenv("VIBECARE_DATA_DIR", dataDir)
    return core, srv
}

func TestConnectRequiresSpawnEnvironment(t *testing.T) {
    t.Setenv("VIBECARE_SOCKET", "")
    t.Setenv("VIBECARE_PLUGIN_ID", "")
    t.Setenv("VIBECARE_DATA_DIR", "")
    if _, err := Connect(); err == nil {
        t.Fatal("expected an error when the spawn env is missing")
    }
}

func TestConnectRegistersWithTheListenerPort(t *testing.T) {
    core, _ := coreFixture(t, "alpha")

    h, err := Connect()
    if err != nil {
        t.Fatal(err)
    }
    defer h.Close()

    if h.ID != "alpha" {
        t.Errorf("ID = %q", h.ID)
    }
    if h.DataDir == "" {
        t.Error("DataDir must come from VIBECARE_DATA_DIR")
    }
    if h.Listener == nil {
        t.Fatal("Connect must bind the plugin's HTTP listener")
    }

    _, portStr, _ := net.SplitHostPort(h.Listener.Addr().String())
    core.mu.Lock()
    defer core.mu.Unlock()
    if len(core.registered) != 1 {
        t.Fatalf("registered %d times, want 1", len(core.registered))
    }
    got := core.registered[0]
    if got.Id != "alpha" {
        t.Errorf("registered id = %q", got.Id)
    }
    if portStr != itoa(int(got.HttpPort)) {
        t.Errorf("registered port %d != listener port %s", got.HttpPort, portStr)
    }
}

// Most plugin authors write no health code at all; the SDK's default
// handler is what core probes.
func TestDefaultHealthHandler(t *testing.T) {
    coreFixture(t, "alpha")
    h, err := Connect()
    if err != nil {
        t.Fatal(err)
    }
    defer h.Close()

    mux := http.NewServeMux()
    go h.Serve(mux)

    resp, err := http.Get("http://" + h.Listener.Addr().String() + "/health")
    if err != nil {
        t.Fatal(err)
    }
    defer resp.Body.Close()
    if resp.StatusCode != http.StatusOK {
        t.Fatalf("code = %d, want 200", resp.StatusCode)
    }
}

// A plugin that knows it is degraded says so, and core moves it there
// immediately rather than waiting for probes to fail.
func TestSetHealthReportsDegraded(t *testing.T) {
    coreFixture(t, "alpha")
    h, err := Connect()
    if err != nil {
        t.Fatal(err)
    }
    defer h.Close()
    h.SetHealth(func() (string, string) { return "degraded", "camera busy" })

    mux := http.NewServeMux()
    go h.Serve(mux)

    resp, err := http.Get("http://" + h.Listener.Addr().String() + "/health")
    if err != nil {
        t.Fatal(err)
    }
    defer resp.Body.Close()

    var body struct {
        Status string `json:"status"`
        Detail string `json:"detail"`
    }
    if err := jsonDecode(resp.Body, &body); err != nil {
        t.Fatal(err)
    }
    if body.Status != "degraded" || body.Detail != "camera busy" {
        t.Fatalf("body = %+v", body)
    }
}

func TestPublishAttachesPluginID(t *testing.T) {
    core, _ := coreFixture(t, "alpha")
    h, err := Connect()
    if err != nil {
        t.Fatal(err)
    }
    defer h.Close()

    if err := h.Publish("alpha.thing.v1", []byte("payload")); err != nil {
        t.Fatal(err)
    }

    core.mu.Lock()
    defer core.mu.Unlock()
    if len(core.published) != 1 {
        t.Fatalf("published %d events", len(core.published))
    }
    if core.published[0].Topic != "alpha.thing.v1" || string(core.published[0].Payload) != "payload" {
        t.Fatalf("event = %+v", core.published[0])
    }
    if core.publishIDs[0] != "alpha" {
        t.Fatalf("caller attribution = %q, want alpha", core.publishIDs[0])
    }
    if !core.published[0].GetTs().IsValid() {
        t.Error("the SDK must stamp ts so plugins don't have to")
    }
}

func TestAlertAttachesPluginIDAndActions(t *testing.T) {
    core, _ := coreFixture(t, "alpha")
    h, err := Connect()
    if err != nil {
        t.Fatal(err)
    }
    defer h.Close()

    err = h.Alert(Alert{
        Title: "Break", Body: "Stand", Level: "info",
        Actions: []AlertAction{{Label: "Snooze", URL: "snooze"}},
    })
    if err != nil {
        t.Fatal(err)
    }

    core.mu.Lock()
    defer core.mu.Unlock()
    if len(core.alerts) != 1 || core.alertIDs[0] != "alpha" {
        t.Fatalf("alerts = %+v ids = %v", core.alerts, core.alertIDs)
    }
    a := core.alerts[0]
    if a.Title != "Break" || len(a.Actions) != 1 || a.Actions[0].Url != "snooze" {
        t.Fatalf("alert = %+v", a)
    }
}

func TestEventsArriveOnTheChannel(t *testing.T) {
    core, _ := coreFixture(t, "alpha")
    h, err := Connect()
    if err != nil {
        t.Fatal(err)
    }
    defer h.Close()

    core.send(&pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Event{Event: &pluginv1.Event{
        Topic: "t.v1", Payload: []byte("hi"),
    }}})

    select {
    case e := <-h.Events:
        if e.Topic != "t.v1" || string(e.Payload) != "hi" {
            t.Fatalf("event = %+v", e)
        }
    case <-time.After(2 * time.Second):
        t.Fatal("event never reached the plugin")
    }
}

func TestShutdownCallbackFires(t *testing.T) {
    core, _ := coreFixture(t, "alpha")
    h, err := Connect()
    if err != nil {
        t.Fatal(err)
    }
    defer h.Close()

    fired := make(chan struct{})
    h.OnShutdown(func() { close(fired) })

    core.send(&pluginv1.CoreMsg{K: &pluginv1.CoreMsg_Shutdown{
        Shutdown: &pluginv1.Shutdown{Reason: "core shutting down"},
    }})

    select {
    case <-fired:
    case <-time.After(2 * time.Second):
        t.Fatal("OnShutdown never fired")
    }
}

// The reconnect loop is what makes a core restart survivable: without it,
// restarting core would kill every running plugin.
func TestReconnectsAfterStreamDrop(t *testing.T) {
    core, srv := coreFixture(t, "alpha")
    reconnectBase = 20 * time.Millisecond
    t.Cleanup(func() { reconnectBase = time.Second })

    h, err := Connect()
    if err != nil {
        t.Fatal(err)
    }
    defer h.Close()

    core.mu.Lock()
    first := core.connects
    core.mu.Unlock()

    // Drop every stream, as a core restart would.
    srv.Stop()

    // Bring core back on the same socket path.
    sock := os.Getenv("VIBECARE_SOCKET")
    os.Remove(sock)
    lis, err := net.Listen("unix", sock)
    if err != nil {
        t.Fatal(err)
    }
    srv2 := grpc.NewServer()
    pluginv1.RegisterPluginHostServer(srv2, core)
    go srv2.Serve(lis)
    defer srv2.Stop()

    deadline := time.Now().Add(10 * time.Second)
    for time.Now().Before(deadline) {
        core.mu.Lock()
        n := core.connects
        core.mu.Unlock()
        if n > first {
            return
        }
        time.Sleep(20 * time.Millisecond)
    }
    t.Fatal("plugin never re-registered after the stream dropped")
}
```

Two tiny helpers the tests use — put them at the bottom of the test file:

```go
func itoa(n int) string { return strconv.Itoa(n) }

func jsonDecode(r io.Reader, v any) error { return json.NewDecoder(r).Decode(v) }
```

with `encoding/json`, `io`, and `strconv` added to the test imports.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && go test ./pkg/vc/...`
Expected: FAIL — `no Go files` or undefined `Connect`.

- [ ] **Step 3: Write `backend/pkg/vc/vc.go`**

```go
// Package vc is the Go SDK for authoring VibeCare plugins.
//
// A plugin is a subprocess that core spawns. It is ALWAYS a gRPC client and
// NEVER a gRPC server: it serves HTTP for its UI and makes three outbound
// calls (Register, Publish, Alert). That asymmetry is what keeps plugins
// cheap to write in any language — there are no service stubs to implement.
//
// The whole of a minimal plugin:
//
//	func main() {
//	    h, err := vc.Connect()          // reads env, registers, reconnects on drop,
//	    if err != nil { log.Fatal(err) } // serves /health, returns handle + listener
//	    http.HandleFunc("/", serveUI)
//	    http.Serve(h.Listener, nil)
//	}
package vc

import (
    "context"
    "encoding/json"
    "fmt"
    "net"
    "net/http"
    "os"
    "sync"
    "time"

    "github.com/vibecare-io/vibecare/backend/pkg/pluginwire"
    pluginv1 "github.com/vibecare-io/vibecare/backend/pkg/proto/plugin/v1"
    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/insecure"
    "google.golang.org/grpc/metadata"
    "google.golang.org/protobuf/proto"
    "google.golang.org/protobuf/types/known/timestamppb"
)

var (
    // reconnectBase is the first reconnect delay; it doubles up to
    // reconnectMax. A var so tests can shrink it.
    reconnectBase = time.Second
    reconnectMax  = 30 * time.Second
    // readyTimeout bounds how long Connect waits for core's Ready. Core
    // kills an unregistered plugin after 10s anyway.
    readyTimeout = 10 * time.Second
)

// eventChanCap bounds the plugin's inbound queue. Events are
// fire-and-forget; a plugin that stops reading drops them rather than
// growing without bound.
const eventChanCap = 64

// Event is one delivery from the bus.
type Event struct {
    Topic   string
    Payload []byte
    TS      time.Time
}

// AlertAction is a button. URL is plugin-relative: pressing it navigates
// the client to /p/<plugin>/<url>.
type AlertAction struct {
    Label string
    URL   string
}

// Alert is a native, transient notification. It is the one UI path that is
// not HTML, because it must render with no window open.
type Alert struct {
    Title   string
    Body    string
    Level   string // "info" | "warn"
    Actions []AlertAction
}

// Handle is a connected plugin.
type Handle struct {
    ID       string
    DataDir  string
    Listener net.Listener
    Events   <-chan Event

    conn   *grpc.ClientConn
    client pluginv1.PluginHostClient
    events chan Event

    ctx    context.Context
    cancel context.CancelFunc

    mu         sync.Mutex
    onShutdown func()
    healthFn   func() (status, detail string)
}

// Connect reads the spawn environment, binds the plugin's HTTP listener,
// dials core, registers, and starts the reconnect loop. It returns once
// core has acknowledged with Ready.
func Connect() (*Handle, error) {
    socket := os.Getenv("VIBECARE_SOCKET")
    id := os.Getenv("VIBECARE_PLUGIN_ID")
    dataDir := os.Getenv("VIBECARE_DATA_DIR")
    if socket == "" || id == "" || dataDir == "" {
        return nil, fmt.Errorf("vc: VIBECARE_SOCKET, VIBECARE_PLUGIN_ID and VIBECARE_DATA_DIR must all be set (is this plugin being run outside VibeCare?)")
    }

    // Bind before registering: RegisterReq.http_port must carry the port
    // the kernel actually assigned.
    lis, err := net.Listen("tcp", "127.0.0.1:0")
    if err != nil {
        return nil, fmt.Errorf("vc: bind plugin http listener: %w", err)
    }

    conn, err := grpc.NewClient("unix://"+socket,
        grpc.WithTransportCredentials(insecure.NewCredentials()),
        grpc.WithUnaryInterceptor(attributionInterceptor(id)),
        grpc.WithStreamInterceptor(attributionStreamInterceptor(id)),
    )
    if err != nil {
        lis.Close()
        return nil, fmt.Errorf("vc: dial core: %w", err)
    }

    ctx, cancel := context.WithCancel(context.Background())
    h := &Handle{
        ID: id, DataDir: dataDir, Listener: lis,
        conn: conn, client: pluginv1.NewPluginHostClient(conn),
        events: make(chan Event, eventChanCap),
        ctx:    ctx, cancel: cancel,
    }
    h.Events = h.events

    // The default /health handler, so most plugin authors write none.
    http.DefaultServeMux.HandleFunc("/health", h.handleHealth)

    ready := make(chan struct{})
    var readyOnce sync.Once
    go h.run(func() { readyOnce.Do(func() { close(ready) }) })

    select {
    case <-ready:
        return h, nil
    case <-time.After(readyTimeout):
        h.Close()
        return nil, fmt.Errorf("vc: core did not acknowledge registration within %s", readyTimeout)
    }
}

// run owns the Register stream for the life of the process. A dropped
// stream is NOT fatal: the plugin keeps serving HTTP and re-dials with
// backoff. Without this, restarting core would kill every running plugin.
func (h *Handle) run(onReady func()) {
    delay := reconnectBase
    for {
        if h.ctx.Err() != nil {
            return
        }
        if err := h.session(onReady); err != nil && h.ctx.Err() == nil {
            // stderr only: stdout belongs to the plugin author.
            fmt.Fprintf(os.Stderr, "vc: register stream ended (%v); reconnecting in %s\n", err, delay)
        }
        if h.ctx.Err() != nil {
            return
        }
        select {
        case <-h.ctx.Done():
            return
        case <-time.After(delay):
        }
        if delay < reconnectMax {
            delay *= 2
            if delay > reconnectMax {
                delay = reconnectMax
            }
        }
    }
}

// session runs one Register stream to completion.
func (h *Handle) session(onReady func()) error {
    _, portStr, err := net.SplitHostPort(h.Listener.Addr().String())
    if err != nil {
        return err
    }
    var port int
    if _, err := fmt.Sscanf(portStr, "%d", &port); err != nil {
        return err
    }

    stream, err := h.client.Register(h.ctx, &pluginv1.RegisterReq{
        Id: h.ID, HttpPort: uint32(port),
    })
    if err != nil {
        return err
    }

    for {
        msg, err := stream.Recv()
        if err != nil {
            return err
        }
        switch {
        case msg.GetReady() != nil:
            onReady()

        case msg.GetEvent() != nil:
            e := msg.GetEvent()
            select {
            case h.events <- Event{Topic: e.GetTopic(), Payload: e.GetPayload(), TS: e.GetTs().AsTime()}:
            default: // fire-and-forget: a plugin that isn't reading drops events
            }

        case msg.GetShutdown() != nil:
            h.mu.Lock()
            fn := h.onShutdown
            h.mu.Unlock()
            if fn != nil {
                fn()
            }
        }
    }
}

// Publish puts raw bytes on a topic. The topic must be declared in the
// plugin's manifest under publishes, or core rejects it.
func (h *Handle) Publish(topic string, payload []byte) error {
    _, err := h.client.Publish(h.ctx, &pluginv1.Event{
        Topic:   topic,
        Payload: payload,
        Ts:      timestamppb.Now(),
    })
    return err
}

// PublishProto marshals m and publishes it. Topic payloads evolve by
// bumping the version in the topic name, never by changing a message in
// place.
func (h *Handle) PublishProto(topic string, m proto.Message) error {
    b, err := proto.Marshal(m)
    if err != nil {
        return err
    }
    return h.Publish(topic, b)
}

func (h *Handle) Alert(a Alert) error {
    req := &pluginv1.AlertReq{Title: a.Title, Body: a.Body, Level: a.Level}
    for _, act := range a.Actions {
        req.Actions = append(req.Actions, &pluginv1.AlertAction{Label: act.Label, Url: act.URL})
    }
    _, err := h.client.Alert(h.ctx, req)
    return err
}

// OnShutdown registers a callback run when core sends Shutdown. Plugins
// should close their HTTP listener and flush storage there; SIGTERM
// follows, and SIGKILL 5s after that.
func (h *Handle) OnShutdown(fn func()) {
    h.mu.Lock()
    defer h.mu.Unlock()
    h.onShutdown = fn
}

// SetHealth overrides the default /health body. status is "ok" or
// "degraded"; a plugin reporting degraded moves to that state immediately
// rather than waiting for probes to fail.
func (h *Handle) SetHealth(fn func() (status, detail string)) {
    h.mu.Lock()
    defer h.mu.Unlock()
    h.healthFn = fn
}

func (h *Handle) handleHealth(w http.ResponseWriter, _ *http.Request) {
    h.mu.Lock()
    fn := h.healthFn
    h.mu.Unlock()

    w.Header().Set("Content-Type", "application/json")
    status, detail := "ok", ""
    if fn != nil {
        status, detail = fn()
    }
    _ = json.NewEncoder(w).Encode(map[string]string{"status": status, "detail": detail})
}

// Serve installs the default /health handler on mux and serves the
// plugin's HTTP on the listener core assigned. Passing nil uses
// http.DefaultServeMux, where Connect already installed /health.
func (h *Handle) Serve(mux *http.ServeMux) error {
    if mux == nil {
        return http.Serve(h.Listener, nil)
    }
    mux.HandleFunc("/health", h.handleHealth)
    return http.Serve(h.Listener, mux)
}

func (h *Handle) Close() error {
    h.cancel()
    if h.Listener != nil {
        h.Listener.Close()
    }
    return h.conn.Close()
}

// attributionInterceptor attaches the plugin id to every unary call. Core
// uses it to attribute publishes and alerts; Event carries no plugin field
// precisely so a plugin cannot claim to be another one.
func attributionInterceptor(id string) grpc.UnaryClientInterceptor {
    return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
        ctx = metadata.AppendToOutgoingContext(ctx, pluginwire.PluginIDMetadataKey, id)
        return invoker(ctx, method, req, reply, cc, opts...)
    }
}

func attributionStreamInterceptor(id string) grpc.StreamClientInterceptor {
    return func(ctx context.Context, desc *grpc.StreamDesc, cc *grpc.ClientConn, method string, streamer grpc.Streamer, opts ...grpc.CallOption) (grpc.ClientStream, error) {
        ctx = metadata.AppendToOutgoingContext(ctx, pluginwire.PluginIDMetadataKey, id)
        return streamer(ctx, desc, cc, method, opts...)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && go test ./pkg/vc/... -race -v -timeout 120s`
Expected: PASS, all ten tests.

- [ ] **Step 5: Commit**

```bash
git add backend/pkg/vc
git commit -m "feat(sdk): vc plugin SDK — connect, publish, alert, reconnect, health"
```

---

### Task 12: The `todo` reference plugin, end to end

**Files:**
- Create: `plugins/todo/go.mod`
- Create: `plugins/todo/manifest.yaml`
- Create: `plugins/todo/store.go`
- Create: `plugins/todo/main.go`
- Create: `plugins/todo/ui/index.html`
- Test: `plugins/todo/store_test.go`
- Test: `plugins/todo/e2e_test.go`
- Modify: `Justfile` (build recipe + include the plugin module in `just test`)

**Interfaces:**
- Consumes: `vc.Connect`/`Handle` (Task 11), `kernel.New`/`Config` (Task 10) — the latter only in the e2e test.
- Produces: a working plugin; nothing else depends on it.

Design notes for the implementer:

- **This is the floor.** No state proto, no rev counters, no Swift, no core change. Drop the directory in, restart core, there is a tab. If any of that stops being true, the architecture has regressed.
- **JSON on disk, not SQLite.** Plugins own their storage and pick their own store; the reference plugin picks the smallest thing that works so it demonstrates the contract rather than a database.
- **`/api/*` is the real interface and `/` is its first consumer.** Keep the JSON surface complete — that is what lets a TUI exist later with no core change and no plugin change.
- **The plugin is its own Go module** with a `replace` to `../../backend`, matching how a droppable third-party plugin would consume the SDK.
- The e2e test builds the binary and drives a real kernel: it is the only test in the plan that proves supervisor + registry + bus + proxy + auth + SDK all work together.

- [ ] **Step 1: Create the module and manifest**

```bash
mkdir -p plugins/todo/ui
cd plugins/todo && go mod init github.com/vibecare-io/vibecare/plugins/todo
go mod edit -replace github.com/vibecare-io/vibecare/backend=../../backend
go mod edit -require github.com/vibecare-io/vibecare/backend@v0.0.0-00010101000000-000000000000
```

`plugins/todo/manifest.yaml`:

```yaml
id: todo
name: Todo
icon: checklist
exec: ./todo
publishes: [todo.created.v1]
ui: webview
```

- [ ] **Step 2: Write the failing store tests**

`plugins/todo/store_test.go`:

```go
package main

import (
    "path/filepath"
    "testing"
)

func newStore(t *testing.T) *Store {
    t.Helper()
    s, err := OpenStore(filepath.Join(t.TempDir(), "todo.json"))
    if err != nil {
        t.Fatal(err)
    }
    return s
}

func TestAddAndList(t *testing.T) {
    s := newStore(t)
    if got := s.List(); len(got) != 0 {
        t.Fatalf("new store has %d tasks", len(got))
    }

    task, err := s.Add("write the plan")
    if err != nil {
        t.Fatal(err)
    }
    if task.ID == "" || task.Title != "write the plan" || task.Done {
        t.Fatalf("task = %+v", task)
    }
    if got := s.List(); len(got) != 1 || got[0].ID != task.ID {
        t.Fatalf("list = %+v", got)
    }
}

func TestAddRejectsBlankTitle(t *testing.T) {
    s := newStore(t)
    if _, err := s.Add("   "); err == nil {
        t.Fatal("expected an error for a blank title")
    }
    if len(s.List()) != 0 {
        t.Fatal("blank task was stored anyway")
    }
}

func TestToggle(t *testing.T) {
    s := newStore(t)
    task, _ := s.Add("a")

    got, ok, err := s.Toggle(task.ID)
    if err != nil || !ok || !got.Done {
        t.Fatalf("toggle = %+v %v %v", got, ok, err)
    }
    got, _, _ = s.Toggle(task.ID)
    if got.Done {
        t.Fatal("second toggle should clear Done")
    }
    if _, ok, _ := s.Toggle("nope"); ok {
        t.Fatal("toggling an unknown id should report not-found")
    }
}

func TestDelete(t *testing.T) {
    s := newStore(t)
    task, _ := s.Add("a")
    ok, err := s.Delete(task.ID)
    if err != nil || !ok {
        t.Fatalf("delete = %v %v", ok, err)
    }
    if len(s.List()) != 0 {
        t.Fatal("task survived delete")
    }
    if ok, _ := s.Delete(task.ID); ok {
        t.Fatal("second delete should report not-found")
    }
}

// Uninstall is deleting one directory, and corruption is contained to one
// plugin — both only hold if state really is on disk in the data dir.
func TestStorePersistsAcrossReopen(t *testing.T) {
    path := filepath.Join(t.TempDir(), "todo.json")
    s1, err := OpenStore(path)
    if err != nil {
        t.Fatal(err)
    }
    task, _ := s1.Add("survive me")

    s2, err := OpenStore(path)
    if err != nil {
        t.Fatal(err)
    }
    got := s2.List()
    if len(got) != 1 || got[0].ID != task.ID || got[0].Title != "survive me" {
        t.Fatalf("reopened store = %+v", got)
    }
}

func TestOpenStoreOnMissingFileStartsEmpty(t *testing.T) {
    s := newStore(t)
    if len(s.List()) != 0 {
        t.Fatal("missing file should start empty, not error")
    }
}
```

- [ ] **Step 3: Write `plugins/todo/store.go`**

```go
package main

import (
    "encoding/json"
    "errors"
    "fmt"
    "os"
    "strings"
    "sync"
    "time"
)

// Task is one item. IDs are assigned by the store.
type Task struct {
    ID      string    `json:"id"`
    Title   string    `json:"title"`
    Done    bool      `json:"done"`
    Created time.Time `json:"created"`
}

// Store is a JSON file. Plugins own their storage and pick their own store;
// the reference plugin picks the smallest thing that works, so it
// demonstrates the contract rather than a database.
type Store struct {
    mu    sync.Mutex
    path  string
    next  int
    tasks []Task
}

func OpenStore(path string) (*Store, error) {
    s := &Store{path: path}
    b, err := os.ReadFile(path)
    if errors.Is(err, os.ErrNotExist) {
        return s, nil // fresh install
    }
    if err != nil {
        return nil, fmt.Errorf("read store: %w", err)
    }
    if len(b) == 0 {
        return s, nil
    }
    if err := json.Unmarshal(b, &s.tasks); err != nil {
        return nil, fmt.Errorf("parse store %s: %w", path, err)
    }
    for _, t := range s.tasks {
        var n int
        if _, err := fmt.Sscanf(t.ID, "t%d", &n); err == nil && n >= s.next {
            s.next = n + 1
        }
    }
    return s, nil
}

func (s *Store) List() []Task {
    s.mu.Lock()
    defer s.mu.Unlock()
    out := make([]Task, len(s.tasks))
    copy(out, s.tasks)
    return out
}

func (s *Store) Add(title string) (Task, error) {
    title = strings.TrimSpace(title)
    if title == "" {
        return Task{}, errors.New("title is required")
    }
    s.mu.Lock()
    defer s.mu.Unlock()
    t := Task{ID: fmt.Sprintf("t%d", s.next), Title: title, Created: time.Now().UTC()}
    s.next++
    s.tasks = append(s.tasks, t)
    return t, s.flushLocked()
}

func (s *Store) Toggle(id string) (Task, bool, error) {
    s.mu.Lock()
    defer s.mu.Unlock()
    for i := range s.tasks {
        if s.tasks[i].ID == id {
            s.tasks[i].Done = !s.tasks[i].Done
            return s.tasks[i], true, s.flushLocked()
        }
    }
    return Task{}, false, nil
}

func (s *Store) Delete(id string) (bool, error) {
    s.mu.Lock()
    defer s.mu.Unlock()
    for i := range s.tasks {
        if s.tasks[i].ID == id {
            s.tasks = append(s.tasks[:i], s.tasks[i+1:]...)
            return true, s.flushLocked()
        }
    }
    return false, nil
}

// Flush writes the store to disk. Called on shutdown as well as on every
// mutation, since core follows CoreMsg.Shutdown with SIGTERM.
func (s *Store) Flush() error {
    s.mu.Lock()
    defer s.mu.Unlock()
    return s.flushLocked()
}

func (s *Store) flushLocked() error {
    b, err := json.MarshalIndent(s.tasks, "", "  ")
    if err != nil {
        return err
    }
    // Write-then-rename so a crash mid-write cannot truncate the store.
    tmp := s.path + ".tmp"
    if err := os.WriteFile(tmp, b, 0o600); err != nil {
        return err
    }
    return os.Rename(tmp, s.path)
}
```

- [ ] **Step 4: Run the store tests**

Run: `cd plugins/todo && go test ./... -v`
Expected: PASS, six tests.

- [ ] **Step 5: Write `plugins/todo/ui/index.html`**

Relative URLs are what make the plugin agnostic to being mounted at `/p/todo/`.

```html
<!doctype html>
<meta charset="utf-8">
<title>Todo</title>
<style>
 body{font:14px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;margin:0;padding:1.5rem;max-width:34rem}
 h1{font-size:1.1rem;margin:0 0 1rem}
 form{display:flex;gap:.5rem;margin-bottom:1rem}
 input[type=text]{flex:1;padding:.45rem .6rem;font:inherit;border:1px solid #ccc;border-radius:6px}
 button{font:inherit;padding:.45rem .8rem;border-radius:6px;border:1px solid #ccc;background:#f6f6f6;cursor:pointer}
 ul{list-style:none;padding:0;margin:0}
 li{display:flex;align-items:center;gap:.6rem;padding:.4rem 0;border-bottom:1px solid #eee}
 li.done span{text-decoration:line-through;opacity:.5}
 li span{flex:1}
 .del{border:0;background:none;opacity:.4}
 .empty{opacity:.5;padding:1rem 0}
 @media (prefers-color-scheme:dark){
   body{background:#1b1b1b;color:#eee}
   input[type=text],button{background:#2a2a2a;color:#eee;border-color:#444}
   li{border-color:#333}
 }
</style>
<h1>Todo</h1>
<form id="add"><input type="text" id="title" placeholder="Add a task…" autofocus><button>Add</button></form>
<ul id="list"></ul>
<script>
// Every URL here is relative, so the plugin neither knows nor cares that
// core mounts it at /p/todo/.
async function load() {
  const tasks = await (await fetch('api/tasks')).json();
  const ul = document.getElementById('list');
  ul.innerHTML = '';
  if (!tasks.length) {
    ul.innerHTML = '<li class="empty">Nothing yet.</li>';
    return;
  }
  for (const t of tasks) {
    const li = document.createElement('li');
    if (t.done) li.className = 'done';
    const box = document.createElement('input');
    box.type = 'checkbox'; box.checked = t.done;
    box.onchange = async () => { await fetch('api/tasks/' + t.id + '/toggle', {method:'POST'}); load(); };
    const span = document.createElement('span');
    span.textContent = t.title;
    const del = document.createElement('button');
    del.className = 'del'; del.textContent = '✕';
    del.onclick = async () => { await fetch('api/tasks/' + t.id, {method:'DELETE'}); load(); };
    li.append(box, span, del);
    ul.append(li);
  }
}
document.getElementById('add').onsubmit = async (e) => {
  e.preventDefault();
  const input = document.getElementById('title');
  if (!input.value.trim()) return;
  await fetch('api/tasks', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({title: input.value})
  });
  input.value = '';
  load();
};
load();
</script>
```

- [ ] **Step 6: Write `plugins/todo/main.go`**

```go
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
```

- [ ] **Step 7: Write the end-to-end test**

`plugins/todo/e2e_test.go` — the only test in this plan that proves supervisor + registry + bus + proxy + auth + SDK all work together.

```go
package main

import (
    "bytes"
    "context"
    "encoding/json"
    "io"
    "net/http"
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
// kernel over it, and returns an authenticated HTTP client plus the origin.
func liveKernel(t *testing.T) (*http.Client, string) {
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

    cfg := kernel.Config{
        PluginsDir:  filepath.Join(home, "plugins"),
        DataRoot:    filepath.Join(home, "data"),
        SocketPath:  filepath.Join(home, "core.sock"),
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
    base := k.BaseURL()
    deadline := time.Now().Add(20 * time.Second)
    for time.Now().Before(deadline) {
        resp, err := client.Get(base + "/p/todo/api/tasks")
        if err == nil {
            resp.Body.Close()
            if resp.StatusCode == http.StatusOK {
                return client, base
            }
        }
        time.Sleep(100 * time.Millisecond)
    }
    t.Fatal("plugin never became reachable through the proxy")
    return nil, ""
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
    client, base := liveKernel(t)

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
    client, base := liveKernel(t)

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
}

// The dashboard is the debugging surface for everything else, so it has to
// show a real running plugin correctly.
func TestDashboardShowsThePluginUp(t *testing.T) {
    client, base := liveKernel(t)

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
    _, base := liveKernel(t)

    resp, err := http.Get(base + "/p/todo/api/tasks")
    if err != nil {
        t.Fatal(err)
    }
    defer resp.Body.Close()
    if resp.StatusCode != http.StatusUnauthorized {
        t.Fatalf("code = %d, want 401", resp.StatusCode)
    }
}
```

Add `"net/url"` to the test imports.

- [ ] **Step 8: Run the end-to-end test**

Run: `cd plugins/todo && go mod tidy && go test ./... -v -timeout 180s`
Expected: PASS — six store tests plus four e2e tests.

- [ ] **Step 9: Add build and test recipes**

In `Justfile`, add to the `📦 Build & Run` group:

```just
# Build all plugins into their own directories (core discovers them there)
[group('📦 Build & Run')]
build-plugins:
    @echo "{{GREEN}}Building plugins...{{NC}}"
    cd plugins/todo && go build -o todo .
    @echo "{{GREEN}}✓ Plugins built{{NC}}"
```

Make `run` depend on it so `just run` always has fresh plugin binaries:

```just
run: proto-gen build-plugins
    @echo "{{GREEN}}Starting VibeCare server...{{NC}}"
    cd {{backend_dir}} && go run cmd/server/main.go --enable-tracing --log-level debug --plugins-dir ../plugins
```

And extend `test` to cover the plugin module, which is separate from the backend module:

```just
test:
    @echo "{{GREEN}}Running tests...{{NC}}"
    cd {{backend_dir}} && go test -v ./...
    cd plugins/todo && go test -v ./...
```

Add `plugins/*/[binary]` to `.gitignore` so built plugin binaries aren't committed:

```gitignore
# Built plugin binaries (see just build-plugins)
plugins/todo/todo
```

- [ ] **Step 10: Verify it live**

Run: `just run`, then in another terminal read the kernel origin from the log line `Plugin kernel ready origin=http://127.0.0.1:PORT` and open:

Run: `open "http://127.0.0.1:PORT/_core/status?vc=$(cat ~/.vibecare/session)"`
Expected: the dashboard lists `Todo` as `up` with a PID and an uptime. Clicking its name opens the todo UI at `/p/todo/`; adding a task persists across a page reload, and the task file exists at `~/.vibecare/data/todo/todo.json`.

Run: `just test`
Expected: PASS for both modules.

- [ ] **Step 11: Commit**

```bash
git add plugins/todo Justfile .gitignore
git commit -m "feat(plugins): todo reference plugin proving the v2 loop end to end"
```

---

### Task 13: Swift shell — roster, webviews, native alerts

**Files:**
- Create: `clients/macos-swift/VibeCare/vibecare/Models/PluginRoster.swift`
- Create: `clients/macos-swift/VibeCare/vibecare/Services/PluginShellService.swift`
- Create: `clients/macos-swift/VibeCare/vibecare/Views/Plugins/PluginWebView.swift`
- Test: `clients/macos-swift/VibeCare/vibecareTests/PluginRosterTests.swift`
- Modify: `vibecare/Views/Plugins/PluginListView.swift` (rewrite)
- Modify: `vibecare/Views/Plugins/PluginScreen.swift` (rewrite)
- Modify: `vibecare/Services/GRPCClientManager.swift` (add `withShellClient`)
- Modify: `vibecare/Views/Dashboard/Dashboard.swift` (own the shell service, present alerts)

**Interfaces:**
- Consumes: generated `VCKShell.Client`, `VCKPluginList`, `VCKPluginInfo`, `VCKState`, `VCKUIIntent`, `VCKAlert` (Task 1).
- Produces:
  ```swift
  struct PluginEntry: Identifiable, Equatable, Sendable {
      let id: String
      let name: String
      let icon: String
      let path: String
      let state: PluginState
      let detail: String
  }
  enum PluginState: String, Sendable { case starting, up, degraded, down, failed }

  struct PluginRoster: Equatable, Sendable {
      let plugins: [PluginEntry]
      let baseURL: String
      let token: String
      func handoffURL(for entry: PluginEntry) -> URL?
      func url(for entry: PluginEntry, path: String) -> URL?
  }

  struct PluginAlert: Identifiable, Equatable, Sendable {
      let id: UUID
      let plugin: String
      let title: String
      let body: String
      let level: String
      let actions: [PluginAlertAction]
  }
  struct PluginAlertAction: Equatable, Sendable { let label: String; let url: String }

  @MainActor final class PluginShellService: ObservableObject {
      @Published private(set) var roster: PluginRoster
      @Published private(set) var lastAlert: PluginAlert?
      func start()
      func stop()
  }

  struct PluginWebView: NSViewRepresentable { let url: URL; let reloadToken: String }
  ```

Design notes for the implementer:

- **§6.1, the coupling rule that actually matters:** the client contains no plugin-specific code. A client knows only "a URL", never a schema. Nothing in these files may branch on a plugin id.
- **`PluginRoster` holds no gRPC types on purpose.** URL construction is the only real logic here, and keeping it in a plain value type is what makes it testable without a running backend — `vibecareTests` has no server.
- **The `?vc=` token goes on the *initial* load only.** After core sets the cookie the webview keeps it, so subsequent navigations and `fetch` calls need nothing. Re-appending it on every load would leak the token into history.
- **`reloadToken` drives automatic recovery.** When the roster reports a plugin back `up`, changing `reloadToken` makes SwiftUI rebuild the webview, so the user is not left staring at core's error page. Spec §5.2 retry #3.
- **Instantiate webviews lazily and one at a time.** N plugins means N `WKWebView`s; the shell shows only the selected plugin's, which is the cheapest correct answer to spec risk #6.
- **Alert action buttons are a stated gap.** This task presents `title`/`body`/`level` natively through the existing `NotificationManager`. Rendering `actions` as buttons needs a VibeNotify API this plan does not add, so the actions are carried through the model and left unrendered, with the gap recorded in Task 14's docs. Everything else about alerts works.

- [ ] **Step 1: Write the failing model tests**

`clients/macos-swift/VibeCare/vibecareTests/PluginRosterTests.swift`:

```swift
import XCTest
@testable import VibeCare

final class PluginRosterTests: XCTestCase {
    private func entry(
        id: String = "todo",
        path: String = "/p/todo/",
        state: PluginState = .up,
        detail: String = ""
    ) -> PluginEntry {
        PluginEntry(id: id, name: "Todo", icon: "checklist", path: path, state: state, detail: detail)
    }

    private func roster(
        _ entries: [PluginEntry],
        baseURL: String = "http://127.0.0.1:52341",
        token: String = "abc123"
    ) -> PluginRoster {
        PluginRoster(plugins: entries, baseURL: baseURL, token: token)
    }

    // The token rides on the initial load only; core exchanges it for a
    // cookie and redirects it away.
    func testHandoffURLCarriesTheToken() throws {
        let e = entry()
        let url = try XCTUnwrap(roster([e]).handoffURL(for: e))
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:52341/p/todo/?vc=abc123")
    }

    func testHandoffURLIsNilWithoutABaseURL() {
        let e = entry()
        XCTAssertNil(roster([e], baseURL: "").handoffURL(for: e))
    }

    // Alert actions are plugin-relative and reuse the proxy rather than
    // inventing a callback channel.
    func testActionURLIsPluginRelative() throws {
        let e = entry()
        let url = try XCTUnwrap(roster([e]).url(for: e, path: "snooze"))
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:52341/p/todo/snooze")
    }

    func testActionURLToleratesALeadingSlash() throws {
        let e = entry()
        let url = try XCTUnwrap(roster([e]).url(for: e, path: "/snooze"))
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:52341/p/todo/snooze")
    }

    // The path is stable across restarts by construction, so the shell must
    // use it verbatim rather than rebuilding it from the id.
    func testURLUsesTheServerSuppliedPath() throws {
        let e = entry(id: "todo", path: "/p/todo/")
        let url = try XCTUnwrap(roster([e]).handoffURL(for: e))
        XCTAssertTrue(url.path.hasPrefix("/p/todo/"))
    }

    func testStateParsingCoversEveryCase() {
        XCTAssertEqual(PluginState(protoState: .starting), .starting)
        XCTAssertEqual(PluginState(protoState: .up), .up)
        XCTAssertEqual(PluginState(protoState: .degraded), .degraded)
        XCTAssertEqual(PluginState(protoState: .down), .down)
        XCTAssertEqual(PluginState(protoState: .failed), .failed)
    }

    // A plugin that is up should render; one that isn't should show the
    // shell's own status rather than loading a webview onto an error page.
    func testIsViewableOnlyWhenServing() {
        XCTAssertTrue(entry(state: .up).isViewable)
        XCTAssertTrue(entry(state: .degraded).isViewable)
        XCTAssertFalse(entry(state: .starting).isViewable)
        XCTAssertFalse(entry(state: .down).isViewable)
        XCTAssertFalse(entry(state: .failed).isViewable)
    }

    // The reload token must change when a plugin transitions back to up, or
    // the user is left on a stale error page.
    func testReloadTokenChangesWithState() {
        let down = entry(state: .down)
        let up = entry(state: .up)
        XCTAssertNotEqual(down.reloadToken, up.reloadToken)
        XCTAssertEqual(up.reloadToken, entry(state: .up).reloadToken)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `just swift-test`
Expected: FAIL — `cannot find 'PluginRoster' in scope`.

- [ ] **Step 3: Write `vibecare/Models/PluginRoster.swift`**

```swift
import Foundation
import VCStubs

/// A plugin's lifecycle state, mirrored from the roster stream.
///
/// `degraded` is deliberately distinct from `down`: the tab still loads but
/// the plugin is misbehaving, and collapsing the two would make that
/// indistinguishable from a slow plugin.
enum PluginState: String, Sendable {
    case starting, up, degraded, down, failed

    init(protoState: VCKState) {
        switch protoState {
        case .up: self = .up
        case .degraded: self = .degraded
        case .down: self = .down
        case .failed: self = .failed
        default: self = .starting
        }
    }
}

/// One row in the plugin sidebar.
///
/// The client contains NO plugin-specific code: this is everything the
/// shell knows about any plugin, and `path` is a URL, never a schema.
struct PluginEntry: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let icon: String
    /// "/p/todo/" — supplied by core and stable across plugin restarts, so
    /// it is used verbatim rather than rebuilt from `id`.
    let path: String
    let state: PluginState
    /// Exit reason when down/failed; /health detail when degraded.
    let detail: String

    /// Whether the plugin is actually serving HTTP right now. A degraded
    /// plugin still serves — that is the whole distinction from down.
    var isViewable: Bool { state == .up || state == .degraded }

    /// Changes whenever the plugin's serving status changes, so SwiftUI
    /// rebuilds the webview when a plugin comes back and the user is not
    /// left on a stale error page.
    var reloadToken: String { "\(id):\(state.rawValue)" }
}

/// The whole roster, plus the origin and token needed to reach any of it.
struct PluginRoster: Equatable, Sendable {
    let plugins: [PluginEntry]
    let baseURL: String
    let token: String

    static let empty = PluginRoster(plugins: [], baseURL: "", token: "")

    /// The URL for a plugin's INITIAL load. The token rides along exactly
    /// once: core validates it, sets an HttpOnly cookie, and redirects it
    /// away, so it never lands in history or a Referer header.
    func handoffURL(for entry: PluginEntry) -> URL? {
        guard var comps = URLComponents(string: baseURL), !baseURL.isEmpty else { return nil }
        comps.path = entry.path
        comps.queryItems = [URLQueryItem(name: "vc", value: token)]
        return comps.url
    }

    /// A URL for a plugin-relative path — e.g. an alert action, which
    /// reuses the proxy rather than inventing a callback channel.
    func url(for entry: PluginEntry, path: String) -> URL? {
        guard var comps = URLComponents(string: baseURL), !baseURL.isEmpty else { return nil }
        let suffix = path.hasPrefix("/") ? String(path.dropFirst()) : path
        comps.path = entry.path + suffix
        return comps.url
    }

    func entry(id: String) -> PluginEntry? { plugins.first { $0.id == id } }
}

/// A transient, native notification originating from a plugin.
struct PluginAlertAction: Equatable, Sendable {
    let label: String
    let url: String  // plugin-relative
}

struct PluginAlert: Identifiable, Equatable, Sendable {
    let id: UUID
    let plugin: String
    let title: String
    let body: String
    let level: String  // "info" | "warn"
    let actions: [PluginAlertAction]

    init(proto: VCKAlert) {
        self.id = UUID()
        self.plugin = proto.plugin
        self.title = proto.title
        self.body = proto.body
        self.level = proto.level
        self.actions = proto.actions.map { PluginAlertAction(label: $0.label, url: $0.url) }
    }
}
```

- [ ] **Step 4: Add `withShellClient` to `GRPCClientManager.swift`**

Mirror `withPluginHostServiceClient` exactly, changing only the client type and the log strings. Insert after the "Plugin Host Service Client" section:

```swift
    // MARK: - Plugin Shell Client (v2 kernel)

    nonisolated func withShellClient<T: Sendable>(_ operation: @Sendable (VCKShell.Client<HTTP2ClientTransport.Posix>) async throws -> T) async throws -> T {
        let host = await self.host
        let port = await self.port
        let useTLS = await self.useTLS
        let logger = await self.logger

        logger.info("Creating gRPC connection to \(host):\(port) for Shell")

        do {
            let transport = try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: useTLS ? .tls : .plaintext
            )
            return try await withGRPCClient(transport: transport) { client in
                try await operation(VCKShell.Client(wrapping: client))
            }
        } catch {
            logger.error("gRPC Shell operation failed: \(error)")
            throw error
        }
    }
```

Note this one deliberately does **not** touch `connectionStatus`: the two shell streams are long-lived, and flipping the shared status to `.disconnected` when either ends would misreport the app's connection state.

- [ ] **Step 5: Write `vibecare/Services/PluginShellService.swift`**

```swift
import Foundation
import Logging
import SwiftProtobuf
import VCStubs

/// The client's entire plugin surface: two long-lived streams.
///
/// `Plugins` pushes the whole roster on any state change; `Intents` pushes
/// transient alerts. Nothing else — user input goes straight from the
/// webview to the plugin over HTTP, so there is no third channel.
@MainActor
final class PluginShellService: ObservableObject {
    @Published private(set) var roster: PluginRoster = .empty
    @Published private(set) var lastAlert: PluginAlert?

    private let logger = Logger(label: "com.vibecare.plugin-shell")
    private var rosterTask: Task<Void, Never>?
    private var intentsTask: Task<Void, Never>?

    func start() {
        guard rosterTask == nil else { return }
        rosterTask = Task { [weak self] in await self?.streamRoster() }
        intentsTask = Task { [weak self] in await self?.streamIntents() }
    }

    func stop() {
        rosterTask?.cancel(); rosterTask = nil
        intentsTask?.cancel(); intentsTask = nil
    }

    // MARK: - Streams

    /// Both streams reconnect on their own: core restarting must not leave
    /// the sidebar permanently empty.
    private func streamRoster() async {
        while !Task.isCancelled {
            do {
                let _: Void = try await GRPCClientManager.shared.withShellClient { [weak self] client in
                    try await client.plugins(Google_Protobuf_Empty()) { response in
                        for try await list in response.messages {
                            await self?.apply(list)
                        }
                        return Void()
                    }
                }
            } catch {
                logger.error("Roster stream ended: \(error)")
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func streamIntents() async {
        while !Task.isCancelled {
            do {
                let _: Void = try await GRPCClientManager.shared.withShellClient { [weak self] client in
                    try await client.intents(Google_Protobuf_Empty()) { response in
                        for try await intent in response.messages {
                            guard case .alert(let alert) = intent.k else { continue }
                            await self?.deliver(PluginAlert(proto: alert))
                        }
                        return Void()
                    }
                }
            } catch {
                logger.error("Intents stream ended: \(error)")
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func apply(_ list: VCKPluginList) {
        roster = PluginRoster(
            plugins: list.plugins.map {
                PluginEntry(
                    id: $0.id,
                    name: $0.name,
                    icon: $0.icon,
                    path: $0.path,
                    state: PluginState(protoState: $0.state),
                    detail: $0.detail
                )
            },
            baseURL: list.baseURL,
            token: list.token
        )
        logger.info("Roster updated: \(roster.plugins.count) plugins at \(roster.baseURL)")
    }

    private func deliver(_ alert: PluginAlert) {
        lastAlert = alert
        // Alerts are the one UI path that is not HTML, because they must
        // render with no window open and with the webview never loaded.
        switch alert.level {
        case "warn":
            NotificationManager.shared.showWarning(title: alert.title, message: alert.body)
        default:
            NotificationManager.shared.showInfo(title: alert.title, message: alert.body)
        }
        if !alert.actions.isEmpty {
            // Rendering action buttons needs a notification API this shell
            // does not yet have; the actions are carried on the model so
            // adding it later touches nothing else.
            logger.info("Alert from \(alert.plugin) carried \(alert.actions.count) unrendered action(s)")
        }
    }
}
```

- [ ] **Step 6: Write `vibecare/Views/Plugins/PluginWebView.swift`**

```swift
import SwiftUI
import WebKit

/// A plugin's screen. The shell embeds the plugin's own HTTP surface and
/// knows nothing about what it renders — that is D4, and it is why adding
/// a plugin never requires releasing the client.
struct PluginWebView: NSViewRepresentable {
    let url: URL
    /// Changing this forces a reload — used when a plugin transitions back
    /// to `up` so the user is not left on core's error page.
    let reloadToken: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Plugins are first-party and served from core's loopback origin.
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.loaded = nil
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Reload only when the target actually changed; SwiftUI calls this
        // on every parent redraw and reloading each time would reset the
        // plugin's scroll position and form state.
        let key = url.absoluteString + "|" + reloadToken
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        view.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: String?
    }
}
```

- [ ] **Step 7: Rewrite `PluginListView.swift` and `PluginScreen.swift`**

`PluginListView.swift` — the sidebar, driven entirely by the roster:

```swift
import SwiftUI

/// The plugin sidebar. It renders whatever the roster says and contains no
/// plugin-specific code — adding a plugin never touches this file.
struct PluginListView: View {
    @ObservedObject var shell: PluginShellService
    @Binding var selectedId: String?

    var body: some View {
        Group {
            if shell.roster.plugins.isEmpty {
                EmptyStateView(
                    title: "No Plugins",
                    subtitle: "Drop a plugin into the plugins directory and restart the backend.",
                    systemImage: "puzzlepiece.extension"
                )
            } else {
                List(shell.roster.plugins, selection: $selectedId) { plugin in
                    HStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(plugin.name)
                            if plugin.state != .up {
                                Text(statusLine(for: plugin))
                                    .font(.caption)
                                    .foregroundStyle(color(for: plugin.state))
                            }
                        }
                    }
                    .tag(plugin.id)
                }
            }
        }
        .navigationTitle("Plugins")
    }

    private func statusLine(for plugin: PluginEntry) -> String {
        plugin.detail.isEmpty ? plugin.state.rawValue : "\(plugin.state.rawValue) — \(plugin.detail)"
    }

    private func color(for state: PluginState) -> Color {
        switch state {
        case .up: return .green
        case .degraded: return .orange
        case .down, .failed: return .red
        case .starting: return .secondary
        }
    }
}
```

`PluginScreen.swift` — the detail column:

```swift
import SwiftUI

/// Detail view for the selected plugin: its own HTML, served by the plugin
/// itself and proxied by core. The client knows only a URL.
struct PluginScreen: View {
    @ObservedObject var shell: PluginShellService
    let pluginId: String

    var body: some View {
        Group {
            if let plugin = shell.roster.entry(id: pluginId) {
                if plugin.isViewable, let url = shell.roster.handoffURL(for: plugin) {
                    PluginWebView(url: url, reloadToken: plugin.reloadToken)
                } else {
                    EmptyStateView(
                        title: "\(plugin.name) is \(plugin.state.rawValue)",
                        subtitle: plugin.detail.isEmpty
                            ? "This view reloads automatically when the plugin comes back."
                            : plugin.detail,
                        systemImage: "exclamationmark.triangle"
                    )
                }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(shell.roster.entry(id: pluginId)?.name ?? pluginId)
    }
}
```

- [ ] **Step 8: Own the shell service in `Dashboard.swift`**

Add the state object alongside the existing ones:

```swift
  @StateObject private var pluginShell = PluginShellService()
```

Replace the two call sites (`Dashboard.swift:136` and `Dashboard.swift:279`) with the roster-driven versions:

```swift
  private var pluginContentView: some View {
    PluginListView(shell: pluginShell, selectedId: $dashboardState.selectedPluginId)
  }
```

```swift
  @ViewBuilder
  private var pluginDetailView: some View {
    if let pluginId = dashboardState.selectedPluginId {
      PluginScreen(shell: pluginShell, pluginId: pluginId)
    } else {
      EmptyStateView(
        title: "No Plugin Selected",
        subtitle: "Select a plugin to view it",
        systemImage: "puzzlepiece.extension"
      )
    }
  }
```

And start the streams with the view:

```swift
    .task {
      pluginShell.start()
    }
```

- [ ] **Step 9: Verify build and tests**

Run: `just proto-gen && just swift-build`
Expected: success.

Run: `just swift-test`
Expected: PASS, including the eight `PluginRosterTests`.

- [ ] **Step 10: Verify live against a running backend**

Run: `just run` in one terminal, then `just swift-run` in another.
Expected: the Plugins sidebar lists **Todo**; selecting it renders the plugin's HTML inside the app; adding a task works and survives switching tabs away and back. Killing the todo process (`pkill -f plugins/todo/todo`) turns the sidebar row red within ~10s and swaps the detail view for the status message; core restarts it and the webview reloads by itself.

- [ ] **Step 11: Commit**

```bash
git add clients/macos-swift/VibeCare/vibecare/Models/PluginRoster.swift \
        clients/macos-swift/VibeCare/vibecare/Services/PluginShellService.swift \
        clients/macos-swift/VibeCare/vibecare/Views/Plugins \
        clients/macos-swift/VibeCare/vibecare/Services/GRPCClientManager.swift \
        clients/macos-swift/VibeCare/vibecare/Views/Dashboard/Dashboard.swift \
        clients/macos-swift/VibeCare/vibecareTests/PluginRosterTests.swift
git commit -m "feat(client): plugin shell — roster sidebar, webview screens, native alerts"
```

---

### Task 14: Delete v1 and document v2

**Files:**
- Delete: `proto/vibecare_plugin.proto` · `backend/internal/plugins/` · `backend/pkg/pluginsdk/` · `backend/cmd/plugin-todos/` · `clients/macos-swift/VibeCare/VCStubs/vibecare_plugin.pb.swift` · `.../vibecare_plugin.grpc.swift` · `vibecare/Views/Plugins/PluginRenderer.swift` · `vibecare/Services/PluginService.swift`
- Modify: `proto/vibecare.proto` (drop `PluginHostService` and its messages)
- Modify: `backend/cmd/server/main.go` · `backend/internal/api/` (drop the v1 registry wiring)
- Modify: `docs/architecture.md`, `CLAUDE.md`, `backend/CLAUDE.md`, `clients/macos-swift/VibeCare/CLAUDE.md`

**Interfaces:**
- Consumes: everything from Tasks 1–13.
- Produces: nothing new. This task only removes.

- [ ] **Step 1: Find every v1 reference before deleting anything**

Run:
```bash
rg -n 'PluginHostService|PluginService|ViewDescriptor|RenderView|InvokeAction|pluginsdk|internal/plugins|plugin-todos' \
   --glob '!**/VCStubs/**' --glob '!docs/**' .
```
Expected: a finite list. Every hit must be either deleted or rewritten in the steps below; work through it and keep the output as your checklist.

- [ ] **Step 2: Remove the v1 service from `proto/vibecare.proto`**

Delete the `PluginHostService` service block (`proto/vibecare.proto:735-739`) and the messages only it used: `ListPluginsResponse`, `PluginSummary`, `RenderPluginViewRequest`, `InvokePluginActionRequest`. Also delete the `import "vibecare_plugin.proto";` line.

Then delete the v1 proto and regenerate:

```bash
git rm proto/vibecare_plugin.proto
git rm clients/macos-swift/VibeCare/VCStubs/vibecare_plugin.pb.swift
git rm clients/macos-swift/VibeCare/VCStubs/vibecare_plugin.grpc.swift
just proto-gen
```

- [ ] **Step 3: Remove the v1 backend plugin system**

```bash
git rm -r backend/internal/plugins backend/pkg/pluginsdk backend/cmd/plugin-todos
```

In `backend/cmd/server/main.go`, delete: the `plugins` import, `hostService`/`hostAddr`/`pluginRegistry` construction, the `plugins.PluginIDUnaryServerInterceptor()` entry in the interceptor chain, `pb.RegisterHostServiceServer(...)`, `pluginRegistry.Stop()` in shutdown, and the `pluginRegistry.Start(...)` block at the end. The kernel wiring added in Task 10 stays exactly as it is.

In `backend/internal/api/`, drop the `pluginRegistry` parameter from `RegisterServices` and delete the `PluginHostService` implementation it registered.

**Do not delete `backend/pkg/pluginwire`** — `kernel/rpc.go` and `pkg/vc` both use its `PluginIDMetadataKey`.

Run: `cd backend && go build ./... && go test ./... -timeout 300s`
Expected: PASS. Fix every compile error the deletions surface; there should be no remaining reference to the v1 types.

- [ ] **Step 4: Remove the v1 Swift plugin code**

```bash
git rm clients/macos-swift/VibeCare/vibecare/Views/Plugins/PluginRenderer.swift
git rm clients/macos-swift/VibeCare/vibecare/Services/PluginService.swift
```

In `GRPCClientManager.swift`, delete `withPluginHostServiceClient` and its "Plugin Host Service Client" section header. `withShellClient` from Task 13 replaces it.

Run: `just swift-build && just swift-test`
Expected: PASS.

- [ ] **Step 5: Confirm nothing v1 survives**

Run:
```bash
rg -n 'PluginHostService|ViewDescriptor|RenderView|InvokeAction|pluginsdk|internal/plugins|plugin-todos' \
   --glob '!docs/**' .
```
Expected: no output. Documentation may still reference v1 by name where it is describing history — that is what `--glob '!docs/**'` allows.

- [ ] **Step 6: Update the documentation**

In `docs/architecture.md`, replace the plugin section with the v2 model, linking the spec. State plainly:

- plugins are supervised subprocesses discovered from `plugins/<id>/manifest.yaml`;
- they are gRPC clients only, over `~/.vibecare/core.sock`, with three RPCs;
- they serve their own HTTP UI, reverse-proxied by core at `<base_url>/p/<id>/`;
- clients get a roster and alerts over two RPCs and contain no plugin-specific code;
- core's dashboard is at `/_core/status`;
- **known gap:** alert action buttons are carried on the wire and through the client model but are not yet rendered (Task 13).

In root `CLAUDE.md`, add to **Essential Commands**:

```
just build-plugins      # Build every plugin binary into its own directory
```

and add to **Mono-Repo Conventions**:

```markdown
### Plugins are independent subprocesses (v2)

A plugin is a directory under `plugins/<id>/` with a `manifest.yaml` and a
binary. Core discovers it at startup, spawns it, and reverse-proxies its
HTTP UI at `/p/<id>/`. Adding a plugin requires **no change to core and no
client release** — see
[`docs/superpowers/specs/2026-08-13-plugin-architecture-v2-design.md`](docs/superpowers/specs/2026-08-13-plugin-architecture-v2-design.md).

- Plugin↔core contract: `proto/plugin/v1/plugin.proto` (3 RPCs, plugin is always the client)
- Client↔core contract: `proto/client/v1/client.proto` (2 RPCs, frozen)
- SDK: `backend/pkg/vc` — `vc.Connect()` is the whole entry point
- Reference plugin: `plugins/todo/`
- Kernel: `backend/kernel/` — contains zero product semantics, enforced by `TestKernelContainsNoProductNouns`
- Plugin state lives in `~/.vibecare/data/<id>/`; cross-plugin communication is bus topics only, never the filesystem
```

In `backend/CLAUDE.md`, note that `backend/kernel/` is generic infrastructure and that the D10 grep test will fail any product noun added there.

In `clients/macos-swift/VibeCare/CLAUDE.md`, note that the client contains no plugin-specific code: plugin screens are `WKWebView`s pointed at core's proxy, and the only plugin types are `PluginRoster`/`PluginEntry`/`PluginAlert`.

- [ ] **Step 7: Full verification**

Run: `just test && just swift-test && cd plugins/todo && go test ./...`
Expected: PASS everywhere.

Run: `just run` and `just swift-run`, then add a task in the Todo plugin tab.
Expected: works, with no v1 code in the tree.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: remove the v1 plugin system, document v2

Deletes PluginService/HostService, the declarative view vocabulary, the
v1 registry and SDK, and the client's native plugin renderer. The v2
kernel, SDK, todo plugin, and webview shell replace them end to end."
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task, except where explicitly deferred in Global Constraints:

| Spec | Task |
|---|---|
| §4 anatomy, discovery, id regex | 2 |
| §5 plugin↔core contract, 5.2 liveness/health/retries, 5.3 stats | 1, 3, 5, 6, 9, 11 |
| §6 client↔core contract, 6.1 coupling rule, 6.2 `/api/*` | 1, 9, 12, 13 |
| §7.1–7.3 core HTTP, plugin HTTP, auth | 7, 12 |
| §7.4 reserved paths, dashboard | 8, 10 |
| §7.5 shared origin | accepted; no `localStorage` in the todo plugin's UI (12) |
| §8 supervisor and lifecycle | 5, 9 |
| §9 storage | 5 (data dir), 12 (plugin-owned store) |
| §10 bus, 10.2 demand-driven capture | 4 |
| §10.1 sensor contract (`landmarks.proto`) | **deferred** — no provider or consumer exists until spec step 5/6; adding the proto now would ship an untested contract |
| §11 alerts | 9, 11, 13 (action buttons a stated gap) |
| §12 core layout | 2–10, file-for-file |
| §13 repo layout | 1, 11, 12 (`pluginsdk/` lives at `backend/pkg/vc` so it stays in the backend module) |
| §14 worked example | 12 |
| §15 impact on existing code | 10 (vibecheck), 14 (everything else) |
| §16 build order steps 2, 3, 4 | 2–13 |
| §17 risks 4, 5, 6 | 7 (streaming test), 12 (no localStorage), 13 (lazy single webview) |

**Deferred from this plan, deliberately:** spec §16 steps 1 and 5–8 (TCC spike, `vibecheck` rewrite, `vision-macos`, `activitywatch`, `vision-linux`, conformance suite) and §10.1's `landmarks.proto`. None are reachable without a camera-touching plugin, which is a separate plan.

**Known gaps recorded rather than hidden:** alert action buttons are transported and modeled but not rendered (Task 13, documented in Task 14).
