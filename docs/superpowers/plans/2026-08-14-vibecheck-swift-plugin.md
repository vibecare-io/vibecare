# VibeCheck Swift Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the macOS client's in-app BFRB detection stack with `plugins/vibecheck/` — a self-contained Swift plugin that owns its camera, serves its own UI, and speaks the v2 plugin contract.

**Architecture:** One Swift executable. A hand-written `VCPluginSDK` (Swift port of `backend/pkg/vc`) registers with core over gRPC on a unix socket and serves HTTP on an ephemeral loopback port that core reverse-proxies at `/p/vibecheck/`. Capture → Vision → detection runs inside one actor; `LandmarkFrame` stays an internal seam so architecture-v2 step 6 can extract a `vision-macos` provider later without redesign.

**Tech Stack:** Swift 6 / SwiftPM, macOS 15+, AVFoundation, Vision, grpc-swift-2 over a unix-domain socket, SwiftNIO HTTP/1.1, swift-testing. One Go test module for the end-to-end kernel proof.

**Spec:** [`docs/superpowers/specs/2026-08-14-vibecheck-plugin-design.md`](../specs/2026-08-14-vibecheck-plugin-design.md)

## Global Constraints

Every task's requirements implicitly include this section.

- **Coordinate space.** `LandmarkFrame` and everything downstream carries **viewer space**: origin top-left, x right, y down, normalized 0..1. Vision's native output is origin bottom-left, y **up**, and must be converted at construction. Consumers never re-convert.
- **Mirroring.** x is **never** flipped for an already-mirrored source. The macOS front camera is auto-mirrored by `AVCaptureConnection.automaticallyAdjustsVideoMirroring`. A non-mirrored source (external USB webcam, Continuity Camera) **must** be x-flipped by the provider. Read `connection.isVideoMirrored` — do not assume.
- **Never call `exit()` unless core asked.** `supervisor.go` charges any unrequested exit as a failed start; `maxFailedStarts = 5` parks the plugin in `StateFailed` until a manual dashboard restart. Every failure path degrades in-process and retries.
- **Plugin id is `vibecheck`** — matches `^[a-z][a-z0-9-]*$`. It is the routing key, the data-dir name, and the topic namespace prefix.
- **Spawn environment is exactly three variables:** `VIBECARE_SOCKET`, `VIBECARE_PLUGIN_ID`, `VIBECARE_DATA_DIR`. All three required. Working directory is the plugin's own directory.
- **All URLs in HTML must be relative.** The plugin is mounted at `/p/vibecheck/` and must not know it.
- **No `localStorage`.** All plugins share one web origin in v1.
- **`x-vibecare-plugin-id` metadata on every unary call.** Core returns `Unauthenticated` without it.
- **Camera-touching plugins embed `__info_plist`** with `NSCameraUsageDescription` via `-sectcreate`. No Developer ID, no app bundle. (Proven empirically — spec §2.)
- **Test sockets go under `os.MkdirTemp("/tmp", …)`.** macOS caps `sockaddr_un.sun_path` at 104 bytes; `t.TempDir()` blows past it.
- **Do not run `go get` or `go mod tidy` on the `backend` module.** The local toolchain is newer than the declared `go 1.23.0` and will silently bump it.
- **Commit with an explicit pathspec.** The working tree carries unrelated modified files; a bare `git commit -a` sweeps them in. Verify every commit with `git show --stat`.
- **Do not run `just service-stop`.** It drops the `io.vibecare.server` LaunchAgent registration.
- **D10:** no product noun (`vibecheck`, `detection`, `behavior`, `camera`, `posture`, `todo`) may appear in any `backend/kernel/*.go` file. `TestKernelContainsNoProductNouns` fails the build. No task in this plan modifies `backend/kernel/`.

---

## File Structure

```
plugins/vibecheck/
  Package.swift                       SwiftPM manifest, pinned deps
  Info.plist                          embedded via -sectcreate; NSCameraUsageDescription
  manifest.yaml                       id/name/icon/exec/publishes/ui
  Sources/
    VCKStubs/                         generated plugin.pb.swift + plugin.grpc.swift
    VCPluginSDK/
      VCEnvironment.swift             the 3 env vars, parsed and validated
      VCReconnectLadder.swift         pure backoff state machine
      VCHTTPServer.swift              NIO HTTP/1.1, keep-alive, ephemeral port
      VCRouter.swift                  path -> handler, /health default
      VCHost.swift                    register stream, events, publish, alert, shutdown
      VCTypes.swift                   VCEvent, VCAlert, VCAlertAction, VCHealth
    VibeCheckKit/
      Geometry.swift                  BFRBBehavior, Hand/Face/HairMask, LandmarkFrame
      BFRBDetector.swift              pure per-frame geometry
      DetectionPolicy.swift           dwell/cooldown state machine
      ConfigStore.swift               config.json
      AlertPrefsStore.swift           alert-prefs.json
      CountsStore.swift               counts.json, date-keyed
      Ordinal.swift                   "1st"/"2nd"/... for nudge copy
    vibecheck/
      main.swift                      composition root
      CameraSession.swift             headless AVCaptureSession
      VisionLandmarkExtractor.swift   Vision -> viewer-space LandmarkFrame
      JPEGEncoder.swift               CVPixelBuffer -> JPEG Data
      DetectionEngine.swift           actor: throttle, detect, policy, alert, counts
      PreviewStream.swift             MJPEG multipart writer
      API.swift                       /api/* handlers + SSE
  Tests/
    VCPluginSDKTests/
    VibeCheckKitTests/
  ui/
    index.html                        preview + overlay + controls
  go.mod                              test-only module for the e2e
  e2e_test.go                         live-kernel drop-in proof
```

Client-side changes (Tasks 17–18) touch `clients/macos-swift/VibeCare/vibecare/`.

---

## Task 1: Package scaffold, generated stubs, and build recipe

Produces a plugin directory that builds and installs, before any SDK logic exists. Everything downstream depends on this layout.

**Files:**
- Create: `plugins/vibecheck/Package.swift`
- Create: `plugins/vibecheck/Info.plist`
- Create: `plugins/vibecheck/manifest.yaml`
- Create: `plugins/vibecheck/Sources/vibecheck/main.swift`
- Create: `plugins/vibecheck/.gitignore`
- Modify: `scripts/generate_proto.sh` (add a `plugin-swift` target)
- Modify: `Justfile:277-317` (add `build-vibecheck-plugin`, extend `build-plugins`)

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable SwiftPM package at `plugins/vibecheck/` whose release binary lands at `plugins/vibecheck/vibecheck`, next to `manifest.yaml`, satisfying `install-plugins`' existing `[ -x "$dir/$id" ]` convention.

- [ ] **Step 1: Generate the Swift stubs for the plugin contract**

`scripts/generate_proto.sh` already emits Swift for the whole `proto/` tree into the client's `VCStubs`. Add a target that emits **only** `plugin/v1` into the plugin. Find the target validation regex at `scripts/generate_proto.sh:67` and extend it:

```bash
    if [[ ! "$TARGET" =~ ^(backend|client-macos|plugin-swift|all)$ ]]; then
        echo -e "${RED}Invalid target: $TARGET${NC}"
        echo "Valid targets are: backend, client-macos, plugin-swift, all"
```

Add the default output dir next to the others near line 23:

```bash
PLUGIN_SWIFT_DEFAULT_DIR="$PROJECT_ROOT/plugins/vibecheck/Sources/VCKStubs"
```

Add a generation function that mirrors the existing Swift block but restricts the input set to `plugin/v1/plugin.proto`:

```bash
generate_plugin_swift() {
    local output_dir="${TARGET_DIR:-$PLUGIN_SWIFT_DEFAULT_DIR}"
    mkdir -p "$output_dir"
    echo -e "${BLUE}Generating Swift plugin stubs -> $output_dir${NC}"
    protoc \
        --proto_path="$PROTO_DIR" \
        --swift_opt=Visibility=Public \
        --swift_opt=FileNaming=DropPath \
        --swift_out="$output_dir" \
        --plugin=protoc-gen-grpc-swift="$grpc_plugin" \
        --grpc-swift_opt=Visibility=Public \
        --grpc-swift_opt=FileNaming=DropPath \
        --grpc-swift_out="$output_dir" \
        "$PROTO_DIR/plugin/v1/plugin.proto"
    echo -e "${GREEN}✓ Swift plugin stubs generated${NC}"
}
```

Wire it into the dispatch `case` alongside `backend` and `client-macos`. `plugin-swift` must **not** be part of `all` — `all` is the release path and this is plugin-local.

- [ ] **Step 2: Run generation and verify the stubs land**

Run: `./scripts/generate_proto.sh -t plugin-swift`
Expected: `plugins/vibecheck/Sources/VCKStubs/plugin.pb.swift` and `plugin.grpc.swift` exist.

Run: `grep -c 'VCKPluginHost' plugins/vibecheck/Sources/VCKStubs/plugin.grpc.swift`
Expected: a non-zero count. The `swift_prefix = "VCK"` option at `proto/plugin/v1/plugin.proto:5` gives every type a `VCK` prefix.

- [ ] **Step 3: Write Package.swift**

Versions are pinned explicitly. Two divergent `Package.resolved` files exist in this repo and disagree with each other — inherit from neither.

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "vibecheck",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "vibecheck", targets: ["vibecheck"]),
  ],
  dependencies: [
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.2.0"),
    .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.1.1"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.3.1"),
    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.31.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
  ],
  targets: [
    .target(
      name: "VCKStubs",
      dependencies: [
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ],
      path: "Sources/VCKStubs"
    ),
    .target(
      name: "VCPluginSDK",
      dependencies: [
        "VCKStubs",
        .product(name: "GRPCCore", package: "grpc-swift-2"),
        .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
      ],
      path: "Sources/VCPluginSDK"
    ),
    .target(name: "VibeCheckKit", path: "Sources/VibeCheckKit"),
    .executableTarget(
      name: "vibecheck",
      dependencies: ["VCPluginSDK", "VibeCheckKit"],
      path: "Sources/vibecheck",
      resources: [.copy("../../ui")]
    ),
    .testTarget(name: "VCPluginSDKTests", dependencies: ["VCPluginSDK"], path: "Tests/VCPluginSDKTests"),
    .testTarget(name: "VibeCheckKitTests", dependencies: ["VibeCheckKit"], path: "Tests/VibeCheckKitTests"),
  ]
)
```

Do **not** put `-sectcreate` in `linkerSettings.unsafeFlags`. A package using `unsafeFlags` cannot be consumed as a versioned dependency, and the command-line form is verified equivalent.

- [ ] **Step 4: Write Info.plist**

The usage description text is copied verbatim from the Xcode project (`project.pbxproj:493`) so the prompt reads identically to today's.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.vibecare.plugin.vibecheck</string>
  <key>CFBundleName</key><string>VibeCheck</string>
  <key>CFBundleExecutable</key><string>vibecheck</string>
  <key>NSCameraUsageDescription</key>
  <string>VibeCheck uses the camera to detect body-focused repetitive behaviors. Video is processed on-device and never leaves your Mac.</string>
</dict>
</plist>
```

- [ ] **Step 5: Write manifest.yaml**

```yaml
id: vibecheck
name: VibeCheck
icon: eye.trianglebadge.exclamationmark
exec: ./vibecheck
publishes: [vibecheck.behavior_detected.v1]
ui: webview
```

Only `id` and `exec` are required; `name` defaults to the id and `ui` defaults to `webview`. Discovery runs exactly once in `Kernel.Start` — changing this file requires a core restart.

- [ ] **Step 6: Write a placeholder main.swift**

Real composition arrives in Task 6. This exists so the package builds.

```swift
import Foundation

// Composition root. Wired in Task 6; this placeholder only proves the
// package builds and the binary lands next to manifest.yaml.
FileHandle.standardError.write(Data("vibecheck: not yet wired\n".utf8))
```

- [ ] **Step 7: Write .gitignore**

```
.build/
vibecheck
```

The built binary is a build artifact, not source, even though it lives next to the manifest.

- [ ] **Step 8: Build and verify the embedded plist seals**

```bash
cd plugins/vibecheck
swift build -c release \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
cp .build/release/vibecheck ./vibecheck
codesign -dvvv ./vibecheck 2>&1 | grep -E 'Identifier|Info.plist'
```

Expected: `Identifier=io.vibecare.plugin.vibecheck` and `Info.plist entries=4`. If `Info.plist=not bound`, the `-sectcreate` flags did not reach the linker — check flag ordering, each needs its own `-Xlinker`.

- [ ] **Step 9: Add the Justfile recipes**

Insert after `build-todo-plugin` (`Justfile:277-280`):

```just
# Build the vibecheck plugin. Swift, not Go. The -sectcreate flags embed
# Info.plist into the Mach-O so macOS has an NSCameraUsageDescription to
# show when the camera is first opened — a bare binary has no bundle and
# would otherwise get no prompt. No codesign step: the TCC grant is keyed
# to the spawning process (vibecare-server), not to this binary, so an
# ad-hoc signature is fine and the grant survives rebuilds.
[group('🧩 Plugins')]
build-vibecheck-plugin:
    @echo "{{GREEN}}Building vibecheck plugin...{{NC}}"
    cd plugins/vibecheck && swift build -c release \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
    cp plugins/vibecheck/.build/release/vibecheck plugins/vibecheck/vibecheck
    @echo "{{GREEN}}✓ vibecheck plugin built: plugins/vibecheck/vibecheck{{NC}}"
```

Change `build-plugins` (`Justfile:315-317`):

```just
[group('🧩 Plugins')]
build-plugins: build-todo-plugin build-vibecheck-plugin
    @echo "{{GREEN}}✓ All plugins built{{NC}}"
```

Leave `install-plugins` untouched — landing the binary at `plugins/vibecheck/vibecheck` satisfies its existing convention. Leave `build-plugins-dev` untouched; Swift live reload is out of scope.

- [ ] **Step 10: Verify the full build path**

Run: `just build-plugins`
Expected: both plugins build, `plugins/vibecheck/vibecheck` exists and is executable.

- [ ] **Step 11: Commit**

```bash
git add plugins/vibecheck/Package.swift plugins/vibecheck/Info.plist \
        plugins/vibecheck/manifest.yaml plugins/vibecheck/.gitignore \
        plugins/vibecheck/Sources scripts/generate_proto.sh Justfile
git commit -m "feat(vibecheck): scaffold the Swift plugin package and build recipe"
git show --stat
```

Confirm the stat lists only these paths.

---

## Task 2: VCEnvironment — the spawn contract, parsed

**Files:**
- Create: `plugins/vibecheck/Sources/VCPluginSDK/VCEnvironment.swift`
- Test: `plugins/vibecheck/Tests/VCPluginSDKTests/VCEnvironmentTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `VCEnvironment.from(_ env: [String: String]) throws -> VCEnvironment` with `socketPath: String`, `pluginID: String`, `dataDir: URL`; throws `VCEnvironmentError.missing(String)`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import VCPluginSDK

@Test func parsesAllThreeVariables() throws {
    let env = VCEnvironment.from([
        "VIBECARE_SOCKET": "/tmp/core.sock",
        "VIBECARE_PLUGIN_ID": "vibecheck",
        "VIBECARE_DATA_DIR": "/tmp/data/vibecheck",
    ])
    let parsed = try env.get()
    #expect(parsed.socketPath == "/tmp/core.sock")
    #expect(parsed.pluginID == "vibecheck")
    #expect(parsed.dataDir.path == "/tmp/data/vibecheck")
}

@Test func rejectsEachMissingVariable() {
    let complete = [
        "VIBECARE_SOCKET": "/tmp/core.sock",
        "VIBECARE_PLUGIN_ID": "vibecheck",
        "VIBECARE_DATA_DIR": "/tmp/data/vibecheck",
    ]
    for key in complete.keys {
        var partial = complete
        partial.removeValue(forKey: key)
        #expect(throws: VCEnvironmentError.self) {
            try VCEnvironment.from(partial).get()
        }
    }
}

@Test func rejectsEmptyStringSameAsMissing() {
    // An empty value is a misconfigured spawn, not a valid socket path.
    // vc.go:145-150 treats it identically to absent.
    var env = [
        "VIBECARE_SOCKET": "",
        "VIBECARE_PLUGIN_ID": "vibecheck",
        "VIBECARE_DATA_DIR": "/tmp/data/vibecheck",
    ]
    #expect(throws: VCEnvironmentError.self) { try VCEnvironment.from(env).get() }
    env["VIBECARE_SOCKET"] = "/tmp/core.sock"
    env["VIBECARE_PLUGIN_ID"] = ""
    #expect(throws: VCEnvironmentError.self) { try VCEnvironment.from(env).get() }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd plugins/vibecheck && swift test --filter VCEnvironmentTests`
Expected: FAIL — `cannot find 'VCEnvironment' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public enum VCEnvironmentError: Error, Equatable {
    case missing(String)
}

/// The entire spawn contract: three variables, all required.
/// `supervisor.go:229-233` sets exactly these and nothing else.
public struct VCEnvironment: Sendable {
    public let socketPath: String
    public let pluginID: String
    public let dataDir: URL

    /// Returns a thunk rather than throwing directly so callers can build
    /// the value in one expression and decide where to surface the failure.
    public static func from(_ env: [String: String]) -> Result<VCEnvironment, VCEnvironmentError> {
        func require(_ key: String) -> Result<String, VCEnvironmentError> {
            guard let v = env[key], !v.isEmpty else { return .failure(.missing(key)) }
            return .success(v)
        }
        return require("VIBECARE_SOCKET").flatMap { socket in
            require("VIBECARE_PLUGIN_ID").flatMap { id in
                require("VIBECARE_DATA_DIR").map { dir in
                    VCEnvironment(socketPath: socket,
                                  pluginID: id,
                                  dataDir: URL(fileURLWithPath: dir))
                }
            }
        }
    }

    public static func fromProcess() -> Result<VCEnvironment, VCEnvironmentError> {
        from(ProcessInfo.processInfo.environment)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd plugins/vibecheck && swift test --filter VCEnvironmentTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add plugins/vibecheck/Sources/VCPluginSDK/VCEnvironment.swift \
        plugins/vibecheck/Tests/VCPluginSDKTests/VCEnvironmentTests.swift
git commit -m "feat(vibecheck): parse and validate the three spawn env vars"
git show --stat
```

---

## Task 3: VCReconnectLadder — backoff as a pure state machine

Extracting the ladder from the reconnect loop is what makes it testable at all. The Go SDK's equivalent is untested because it is welded to a `for` loop.

**Files:**
- Create: `plugins/vibecheck/Sources/VCPluginSDK/VCReconnectLadder.swift`
- Test: `plugins/vibecheck/Tests/VCPluginSDKTests/VCReconnectLadderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct VCReconnectLadder` with `mutating func sessionEnded(lastedSeconds: TimeInterval) -> TimeInterval` and `mutating func reset()`.

**Design note:** the cap is **8 s**, deliberately tighter than the Go SDK's 30 s. While the Register stream is down, core demotes the plugin to `starting("reconnecting")` and `proxy.go:44-48` serves a 503 page for `/p/vibecheck/`. The upper rungs of a 30 s ladder are user-visible UI downtime.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import VCPluginSDK

@Test func doublesFromOneSecondAndCapsAtEight() {
    var ladder = VCReconnectLadder()
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 1)
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 2)
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 4)
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 8)
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 8)
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 8)
}

@Test func aStableSessionResetsTheLadder() {
    var ladder = VCReconnectLadder()
    _ = ladder.sessionEnded(lastedSeconds: 0)
    _ = ladder.sessionEnded(lastedSeconds: 0)
    _ = ladder.sessionEnded(lastedSeconds: 0)   // now at 4
    // A session that survived the stability threshold means the previous
    // failures were unrelated; the next drop starts over at the bottom.
    #expect(ladder.sessionEnded(lastedSeconds: 60) == 1)
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 2)
}

@Test func aSessionJustUnderTheThresholdDoesNotReset() {
    var ladder = VCReconnectLadder()
    _ = ladder.sessionEnded(lastedSeconds: 0)   // 1
    #expect(ladder.sessionEnded(lastedSeconds: 59.9) == 2)
}

@Test func explicitResetReturnsToTheBottom() {
    var ladder = VCReconnectLadder()
    _ = ladder.sessionEnded(lastedSeconds: 0)
    _ = ladder.sessionEnded(lastedSeconds: 0)
    ladder.reset()
    #expect(ladder.sessionEnded(lastedSeconds: 0) == 1)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd plugins/vibecheck && swift test --filter VCReconnectLadderTests`
Expected: FAIL — `cannot find 'VCReconnectLadder' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Backoff for the Register stream, as a value type so it can be tested
/// without a network. Pulled out of the reconnect loop deliberately: the
/// Go SDK's equivalent is welded into a `for` and has never been tested.
///
/// The 8s cap is tighter than the Go SDK's 30s on purpose. While the stream
/// is down core demotes the plugin to starting("reconnecting") and the proxy
/// serves a 503 page for /p/<id>/, so the upper rungs are visible downtime.
public struct VCReconnectLadder: Sendable, Equatable {
    public var base: TimeInterval = 1
    public var cap: TimeInterval = 8
    public var stableAfter: TimeInterval = 60

    private var failures: Int = 0

    public init() {}

    /// Call when a session ends, however it ended. Returns how long to wait
    /// before the next attempt.
    public mutating func sessionEnded(lastedSeconds: TimeInterval) -> TimeInterval {
        if lastedSeconds >= stableAfter { failures = 0 }
        let delay = min(cap, base * pow(2, Double(failures)))
        failures += 1
        return delay
    }

    public mutating func reset() { failures = 0 }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd plugins/vibecheck && swift test --filter VCReconnectLadderTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Prove the cap guard can actually fail**

Two guards in this codebase's history were decorative and nobody knew. Temporarily change `cap` to `1000`, re-run, confirm `doublesFromOneSecondAndCapsAtEight` goes **red**, then restore `8` and confirm green. Do not commit the broken value.

- [ ] **Step 6: Commit**

```bash
git add plugins/vibecheck/Sources/VCPluginSDK/VCReconnectLadder.swift \
        plugins/vibecheck/Tests/VCPluginSDKTests/VCReconnectLadderTests.swift
git commit -m "feat(vibecheck): reconnect backoff ladder as a tested value type"
git show --stat
```

---

## Task 4: VCHTTPServer and VCRouter — the plugin's own HTTP

**Files:**
- Create: `plugins/vibecheck/Sources/VCPluginSDK/VCRouter.swift`
- Create: `plugins/vibecheck/Sources/VCPluginSDK/VCHTTPServer.swift`
- Test: `plugins/vibecheck/Tests/VCPluginSDKTests/VCHTTPServerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct VCRequest { let method: String; let path: String; let query: [String: String]; let body: Data }`
  - `struct VCResponse { var status: Int; var headers: [String: String]; var body: Data }` plus `static func json(_ value: Encodable, status: Int = 200) throws -> VCResponse` and `static func html(_ s: String) -> VCResponse`
  - `actor VCRouter` with `func handle(_ path: String, _ h: @escaping VCHandler)`, `func handlePrefix(_ prefix: String, _ h: @escaping VCHandler)`, where `typealias VCHandler = @Sendable (VCRequest, VCResponseWriter) async throws -> Void`
  - `actor VCHTTPServer` with `func start(router: VCRouter) async throws -> Int` returning the bound port, and `func stop() async`

**Design note:** the response writer is a **streaming** interface, not a returned value, because `/preview.mjpeg` and `/api/events` never complete. `VCResponseWriter` exposes `writeHead(status:headers:)`, `write(_ chunk: Data)`, and `finish()`.

**Critical:** the server must speak **persistent HTTP/1.1**. `health.go:135` probes with a shared `http.Client` on the default transport, i.e. keep-alive on, and will hold an idle connection open. A listener that closes after each response fails probes intermittently.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import VCPluginSDK

@Test func servesHealthOnAnEphemeralPortOverAPersistentConnection() async throws {
    let router = VCRouter()
    await router.handle("/health") { _, w in
        try await w.writeHead(status: 200, headers: ["Content-Type": "application/json"])
        try await w.write(Data(#"{"status":"ok","detail":""}"#.utf8))
        try await w.finish()
    }
    let server = VCHTTPServer()
    let port = try await server.start(router: router)
    #expect(port > 0)

    // A URLSession reuses connections by default, so two sequential requests
    // over one session exercise the keep-alive path the health prober uses.
    let session = URLSession(configuration: .ephemeral)
    for _ in 0..<2 {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let (data, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("\"status\":\"ok\""))
    }
    await server.stop()
}

@Test func unknownPathIs404() async throws {
    let router = VCRouter()
    let server = VCHTTPServer()
    let port = try await server.start(router: router)
    let url = URL(string: "http://127.0.0.1:\(port)/nope")!
    let (_, response) = try await URLSession(configuration: .ephemeral).data(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 404)
    await server.stop()
}

@Test func prefixRoutesMatchSubpaths() async throws {
    let router = VCRouter()
    await router.handlePrefix("/api/tasks/") { req, w in
        try await w.writeHead(status: 200, headers: [:])
        try await w.write(Data(req.path.utf8))
        try await w.finish()
    }
    let server = VCHTTPServer()
    let port = try await server.start(router: router)
    let url = URL(string: "http://127.0.0.1:\(port)/api/tasks/abc/toggle")!
    let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
    #expect(String(decoding: data, as: UTF8.self) == "/api/tasks/abc/toggle")
    await server.stop()
}

@Test func streamsChunksWithoutClosing() async throws {
    // Proves the writer can emit before finishing — the property MJPEG and
    // SSE depend on. Without it the preview hangs.
    let router = VCRouter()
    await router.handle("/stream") { _, w in
        try await w.writeHead(status: 200, headers: ["Content-Type": "text/plain"])
        for i in 0..<3 {
            try await w.write(Data("chunk\(i)\n".utf8))
        }
        try await w.finish()
    }
    let server = VCHTTPServer()
    let port = try await server.start(router: router)
    let url = URL(string: "http://127.0.0.1:\(port)/stream")!
    let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
    #expect(String(decoding: data, as: UTF8.self) == "chunk0\nchunk1\nchunk2\n")
    await server.stop()
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd plugins/vibecheck && swift test --filter VCHTTPServerTests`
Expected: FAIL — `cannot find 'VCRouter' in scope`.

- [ ] **Step 3: Write VCRouter.swift**

```swift
import Foundation

public struct VCRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let body: Data
}

/// Streaming response interface. Handlers write rather than return, because
/// /preview.mjpeg and /api/events never complete — a returned-value API
/// cannot express them.
public protocol VCResponseWriter: Sendable {
    func writeHead(status: Int, headers: [String: String]) async throws
    func write(_ chunk: Data) async throws
    func finish() async throws
}

public typealias VCHandler = @Sendable (VCRequest, any VCResponseWriter) async throws -> Void

public actor VCRouter {
    private var exact: [String: VCHandler] = [:]
    private var prefixes: [(String, VCHandler)] = []

    public init() {}

    public func handle(_ path: String, _ h: @escaping VCHandler) {
        exact[path] = h
    }

    /// Longest prefix wins, so "/api/tasks/" beats "/api/" regardless of
    /// registration order.
    public func handlePrefix(_ prefix: String, _ h: @escaping VCHandler) {
        prefixes.append((prefix, h))
        prefixes.sort { $0.0.count > $1.0.count }
    }

    public func route(_ path: String) -> VCHandler? {
        if let h = exact[path] { return h }
        for (prefix, h) in prefixes where path.hasPrefix(prefix) { return h }
        return nil
    }
}
```

- [ ] **Step 4: Write VCHTTPServer.swift**

```swift
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

public enum VCHTTPError: Error { case notStarted, noPort }

/// HTTP/1.1 on 127.0.0.1:0. Keep-alive is left ON: the kernel's health
/// prober (health.go:135) uses a shared http.Client with the default
/// transport and holds an idle persistent connection. A close-per-response
/// server fails those probes intermittently.
public actor VCHTTPServer {
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    public init() {}

    public func start(router: VCRouter) async throws -> Int {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(VCHTTPHandler(router: router))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        // Bind before Register: RegisterReq.http_port must carry the port the
        // OS actually assigned, and the proxy targets it the instant core
        // marks the plugin up.
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        self.channel = channel
        guard let port = channel.localAddress?.port else { throw VCHTTPError.noPort }
        return port
    }

    public func stop() async {
        try? await channel?.close().get()
        try? await group?.shutdownGracefully()
        channel = nil
        group = nil
    }
}
```

The `VCHTTPHandler` `ChannelInboundHandler` accumulates the request body, builds a `VCRequest`, resolves the handler from the router, and adapts the NIO channel to `VCResponseWriter`. It must respond 404 when `route` returns nil, and 500 when a handler throws **after** nothing has been written yet (once bytes are on the wire, log and close instead — you cannot retroactively change a status line).

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd plugins/vibecheck && swift test --filter VCHTTPServerTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Prove the keep-alive assertion can fail**

Temporarily make the handler close the channel after `finish()`. Re-run `servesHealthOnAnEphemeralPortOverAPersistentConnection` and confirm the **second** request fails or the test goes red. Restore. This guard is the whole reason the test issues two requests over one session.

- [ ] **Step 7: Commit**

```bash
git add plugins/vibecheck/Sources/VCPluginSDK/VCRouter.swift \
        plugins/vibecheck/Sources/VCPluginSDK/VCHTTPServer.swift \
        plugins/vibecheck/Tests/VCPluginSDKTests/VCHTTPServerTests.swift
git commit -m "feat(vibecheck): streaming HTTP/1.1 server and router for the plugin SDK"
git show --stat
```

---

## Task 5: VCHost — register, stream, publish, alert, shut down

The core of the SDK. Everything in §5.3 of the spec is a requirement here.

**Files:**
- Create: `plugins/vibecheck/Sources/VCPluginSDK/VCTypes.swift`
- Create: `plugins/vibecheck/Sources/VCPluginSDK/VCHost.swift`
- Test: `plugins/vibecheck/Tests/VCPluginSDKTests/VCHostTests.swift`

**Interfaces:**
- Consumes: `VCEnvironment`, `VCReconnectLadder`, `VCHTTPServer`, `VCRouter`, `VCKStubs`.
- Produces:
  ```swift
  public struct VCAlertAction: Sendable, Codable { public var label: String; public var url: String }
  public struct VCAlert: Sendable { public var title, body, level: String; public var actions: [VCAlertAction] }
  public struct VCEvent: Sendable { public let topic: String; public let payload: Data; public let ts: Date? }
  public struct VCDemand: Sendable, Codable { public let topic: String; public let subscribers: Int }
  public actor VCHost {
      public static func connect(env: VCEnvironment, router: VCRouter) async throws -> VCHost
      public nonisolated var id: String { get }
      public nonisolated var dataDir: URL { get }
      public func events() -> AsyncStream<VCEvent>
      public func publish(topic: String, payload: Data) async throws
      public func alert(_ a: VCAlert) async throws
      public func onShutdown(_ hook: @escaping @Sendable () async -> Void)
      public func setHealth(_ probe: @escaping @Sendable () -> (status: String, detail: String))
  }
  ```

**Requirements this task must satisfy** — each is a spec §5.3 trap:

1. `RegisterReq.id` is `env.pluginID` **verbatim**. Core does not cross-check it against call metadata; a wrong id hijacks another plugin's proxy target and bus subscription.
2. `x-vibecare-plugin-id` metadata on `publish` and `alert`.
3. A **clean** end of the response stream re-enters the ladder, exactly like a thrown error.
4. `publish` and `alert` carry a per-call deadline (5 s). Neither has one in the Go SDK; both can block forever against a wedged core.
5. `connect` **never throws on a registration failure** — it retries in-process. It throws only for a programming error (an unusable socket path). No path in this SDK calls `exit()`.
6. SIGTERM runs the shutdown hooks; hooks are registered before the stream task starts, so the once-guard cannot burn early.
7. The default `/health` handler is installed on the router **before** `Register` is called.
8. `/health` reports `detail` only when status is `degraded` — core force-clears detail on any transition to `up`.

- [ ] **Step 1: Write the failing test**

Only the pure, injectable parts are unit-tested here; the live loop is proven by the Go e2e in Task 6. Extract the stream-outcome classification so it can be tested without a network.

```swift
import Testing
import Foundation
@testable import VCPluginSDK

@Test func cleanStreamEndIsTreatedAsAReconnect() {
    // rpc.go:146-149 returns nil when a non-superseded cancel closes the
    // subscriber channel. In grpc-swift that surfaces as an AsyncSequence
    // that simply finishes — nothing thrown. A do/catch-driven loop would
    // fall out and never reconnect again.
    #expect(VCSessionOutcome.classify(error: nil) == .reconnect)
    #expect(VCSessionOutcome.classify(error: VCHostError.streamEnded) == .reconnect)
}

@Test func shutdownRequestIsTheOnlyNonReconnectOutcome() {
    #expect(VCSessionOutcome.classify(error: VCHostError.shutdownRequested) == .stop)
}

@Test func healthBodyOmitsDetailWhenOk() throws {
    // health.go:179-181 force-clears detail on any transition to up, so a
    // detail string alongside "ok" is silently discarded. Do not emit one.
    let ok = VCHealthBody(status: "ok", detail: "camera warming")
    let encoded = String(decoding: try JSONEncoder().encode(ok.normalized()), as: UTF8.self)
    #expect(encoded.contains("\"status\":\"ok\""))
    #expect(!encoded.contains("camera warming"))

    let degraded = VCHealthBody(status: "degraded", detail: "camera unavailable")
    let d = String(decoding: try JSONEncoder().encode(degraded.normalized()), as: UTF8.self)
    #expect(d.contains("camera unavailable"))
}

@Test func demandPayloadDecodes() throws {
    let json = Data(#"{"topic":"sensor.landmarks.v1","subscribers":2}"#.utf8)
    let d = try JSONDecoder().decode(VCDemand.self, from: json)
    #expect(d.topic == "sensor.landmarks.v1")
    #expect(d.subscribers == 2)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd plugins/vibecheck && swift test --filter VCHostTests`
Expected: FAIL — `cannot find 'VCSessionOutcome' in scope`.

- [ ] **Step 3: Write VCTypes.swift**

```swift
import Foundation

public struct VCAlertAction: Sendable, Codable, Equatable {
    public var label: String
    public var url: String          // plugin-relative; core routes to /p/<id>/<url>
    public init(label: String, url: String) { self.label = label; self.url = url }
}

public struct VCAlert: Sendable, Equatable {
    public var title: String
    public var body: String
    public var level: String        // "info" | "warn" — nothing else exists
    public var actions: [VCAlertAction]
    public init(title: String, body: String, level: String = "info",
                actions: [VCAlertAction] = []) {
        self.title = title; self.body = body; self.level = level; self.actions = actions
    }
}

public struct VCEvent: Sendable {
    public let topic: String
    public let payload: Data
    public let ts: Date?
}

/// Delivered on the reserved topic `_core.demand.v1` without being declared
/// in the manifest. Authoritative STATE, not a delta: overwrite local state
/// from every event, and expect a full burst on reconnect. Transitions that
/// happen while the stream is down are dropped and never replayed.
///
/// Note: a plugin with an empty `publishes` list never receives this at all,
/// and declaring the topic in `subscribes` does nothing — announceDemand
/// writes straight to the publisher's channel.
public struct VCDemand: Sendable, Codable, Equatable {
    public let topic: String
    public let subscribers: Int
}

public let VCTopicDemand = "_core.demand.v1"

public struct VCHealthBody: Sendable, Codable, Equatable {
    public var status: String       // "ok" | "degraded"
    public var detail: String

    /// Core force-clears detail on any transition to `up` (health.go:179-181),
    /// so a detail carried alongside "ok" is silently discarded. Drop it here
    /// rather than emitting something the operator will never see.
    public func normalized() -> VCHealthBody {
        status == "ok" ? VCHealthBody(status: "ok", detail: "") : self
    }
}

public enum VCHostError: Error, Equatable {
    case streamEnded
    case shutdownRequested
    case registrationRejected(String)
}

public enum VCSessionOutcome: Equatable {
    case reconnect
    case stop

    /// A clean end and a thrown error both mean the same thing: get back on
    /// the ladder. Only an explicit shutdown stops.
    public static func classify(error: Error?) -> VCSessionOutcome {
        if let e = error as? VCHostError, e == .shutdownRequested { return .stop }
        return .reconnect
    }
}
```

- [ ] **Step 4: Write VCHost.swift**

```swift
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import VCKStubs

public actor VCHost {
    public nonisolated let id: String
    public nonisolated let dataDir: URL

    private let router: VCRouter
    private var httpPort: Int = 0
    private var ladder = VCReconnectLadder()
    private var shutdownHooks: [@Sendable () async -> Void] = []
    private var didRunShutdown = false
    private var healthProbe: @Sendable () -> (status: String, detail: String) = { ("ok", "") }
    private var eventContinuations: [UUID: AsyncStream<VCEvent>.Continuation] = [:]

    private static let callDeadline: Duration = .seconds(5)

    private init(env: VCEnvironment, router: VCRouter) {
        self.id = env.pluginID
        self.dataDir = env.dataDir
        self.router = router
    }

    /// Startup order is mandatory:
    ///   1. install /health   2. bind and accept   3. Register with the bound port
    /// The proxy targets the port the instant core marks the plugin up, so a
    /// bound-but-not-accepting socket produces 502s rather than the down page.
    public static func connect(env: VCEnvironment, router: VCRouter) async throws -> VCHost {
        let host = VCHost(env: env, router: router)
        await host.installHealthRoute()
        let server = VCHTTPServer()
        let port = try await server.start(router: router)
        await host.setPort(port)
        await host.startSessionLoop(socketPath: env.socketPath, server: server)
        return host
    }
}
```

The session loop is a detached `Task` that repeatedly:

1. builds a `GRPCClient` over `HTTP2ClientTransport.Posix(target: .unixDomainSocket(path:), transportSecurity: .plaintext)`;
2. calls `register` with `VCKRegisterReq(id: self.id, httpPort: UInt32(httpPort))`;
3. records the session start time, then iterates the response stream, dispatching `.ready`, `.event`, `.shutdown`;
4. on **any** exit from the iteration — thrown or clean — computes `VCSessionOutcome.classify(error:)`, and on `.reconnect` sleeps `ladder.sessionEnded(lastedSeconds:)` and loops.

A `NOT_FOUND` registration (`rpc.go` returns it for an unknown id) is terminal in the sense that retrying cannot succeed — but the loop **still** must not exit the process. Log it at error level and keep retrying at the capped interval; a core restart with a fixed manifest recovers without a plugin restart.

`publish` and `alert` build a `ClientRequest` with `metadata: ["x-vibecare-plugin-id": "\(id)"]` and a 5 s deadline. Neither requires an active Register stream — `rpc.go:170-172, 198-200` check only that the manifest id is known — so both are safe to call during a reconnect.

`installHealthRoute` registers `/health` returning `healthProbe()` passed through `VCHealthBody.normalized()`.

SIGTERM is trapped with a `DispatchSourceSignal`; the handler runs `runShutdown()` and then exits. Hooks are registered before the session task starts so the once-guard cannot burn on an early signal. **SIGTERM is the only guaranteed shutdown notice** — `BroadcastShutdown` iterates live streams only, so a plugin mid-reconnect never receives `CoreMsg.shutdown`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd plugins/vibecheck && swift test --filter VCHostTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Verify the whole package still builds**

Run: `cd plugins/vibecheck && swift build -c release`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add plugins/vibecheck/Sources/VCPluginSDK/VCTypes.swift \
        plugins/vibecheck/Sources/VCPluginSDK/VCHost.swift \
        plugins/vibecheck/Tests/VCPluginSDKTests/VCHostTests.swift
git commit -m "feat(vibecheck): VCHost — register stream, publish, alert, shutdown"
git show --stat
```

---

## Task 6: Drop-in proof — wire main.swift and the live-kernel e2e

The first task whose deliverable is visible in the app. Nothing camera-related yet: this proves the plugin registers, appears in the roster, serves through the proxy, and writes to its data dir.

**Files:**
- Modify: `plugins/vibecheck/Sources/vibecheck/main.swift`
- Create: `plugins/vibecheck/ui/index.html`
- Create: `plugins/vibecheck/go.mod`
- Create: `plugins/vibecheck/e2e_test.go`
- Modify: `Justfile` (add vibecheck to the test recipe near line 732)

**Interfaces:**
- Consumes: `VCHost.connect(env:router:)`, `VCRouter.handle(_:_:)`.
- Produces: a registered plugin serving `GET /` and `GET /api/state`.

- [ ] **Step 1: Write the failing e2e test**

Modeled directly on `plugins/todo/e2e_test.go`, which starts a **real in-process kernel** — not a mock.

```go
package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/vibecare-io/vibecare/backend/kernel"
	"go.uber.org/zap"
)

// buildVibeCheck compiles the Swift plugin into dir. The -sectcreate flags
// embed Info.plist so macOS has an NSCameraUsageDescription to show; without
// them a bare binary gets no camera prompt at all.
func buildVibeCheck(t *testing.T, dir string) {
	t.Helper()
	cmd := exec.Command("swift", "build", "-c", "release",
		"-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
		"-Xlinker", "__info_plist", "-Xlinker", "Info.plist")
	cmd.Dir = "."
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("swift build: %v\n%s", err, out)
	}
	src := filepath.Join(".build", "release", "vibecheck")
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read built binary: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "vibecheck"), data, 0o755); err != nil {
		t.Fatalf("install binary: %v", err)
	}
}

func liveKernel(t *testing.T) (*http.Client, string, string) {
	t.Helper()
	home := t.TempDir()
	pluginDir := filepath.Join(home, "plugins", "vibecheck")
	if err := os.MkdirAll(pluginDir, 0o755); err != nil {
		t.Fatal(err)
	}
	buildVibeCheck(t, pluginDir)
	manifest, err := os.ReadFile("manifest.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pluginDir, "manifest.yaml"), manifest, 0o644); err != nil {
		t.Fatal(err)
	}

	// macOS caps sockaddr_un.sun_path at 104 bytes and t.TempDir() is a long
	// nested path under $TMPDIR that routinely blows past it.
	sockDir, err := os.MkdirTemp("/tmp", "vcvibe")
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

	jar, _ := cookiejar.New(nil)
	client := &http.Client{Jar: sessionJar{token: k.Token(), inner: jar}}
	base := k.BaseURL(context.Background())

	deadline := time.Now().Add(60 * time.Second) // swift build is slow on a cold cache
	for time.Now().Before(deadline) {
		resp, err := client.Get(base + "/p/vibecheck/api/state")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				return client, base, home
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("plugin never became reachable through the proxy")
	return nil, "", ""
}

// sessionJar always presents the session cookie, which is what the Swift
// shell's webview does after the ?vc= handoff.
type sessionJar struct {
	token string
	inner http.CookieJar
}

func (j sessionJar) SetCookies(u *url.URL, c []*http.Cookie) { j.inner.SetCookies(u, c) }
func (j sessionJar) Cookies(u *url.URL) []*http.Cookie {
	return []*http.Cookie{{Name: "vc_session", Value: j.token}}
}

func TestPluginServesUIAndAPIThroughTheProxy(t *testing.T) {
	client, base, _ := liveKernel(t)
	resp, err := client.Get(base + "/p/vibecheck/")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("got %d, want 200", resp.StatusCode)
	}
}

func TestDashboardShowsThePluginUp(t *testing.T) {
	client, base, _ := liveKernel(t)
	resp, err := client.Get(base + "/_core/api/plugins")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var payload struct {
		Plugins []struct {
			ID    string `json:"id"`
			State string `json:"state"`
			PID   int    `json:"pid"`
		} `json:"plugins"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	for _, p := range payload.Plugins {
		if p.ID == "vibecheck" {
			if p.State != "up" {
				t.Fatalf("state = %q, want up", p.State)
			}
			if p.PID == 0 {
				t.Fatal("pid is 0; the plugin is not actually running")
			}
			return
		}
	}
	t.Fatal("vibecheck not in the roster")
}

func TestProxyRejectsUnauthenticatedRequests(t *testing.T) {
	_, base, _ := liveKernel(t)
	resp, err := http.Get(base + "/p/vibecheck/api/state")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatalf("got %d, want 401", resp.StatusCode)
	}
}

func TestConfigPersistsToTheDataDir(t *testing.T) {
	client, base, home := liveKernel(t)
	body := `{"enabled":true,"sensitivity":0.7,"dwell":0.15,"cooldown":5,"enabledBehaviors":["nailBiting"]}`
	req, _ := http.NewRequest("PUT", base+"/p/vibecheck/api/config", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("got %d, want 200", resp.StatusCode)
	}

	// A GET here would only prove in-memory state, which is true even of a
	// store whose flush is a silent no-op. The claim this test exists to make
	// is the wiring: DataRoot -> VIBECARE_DATA_DIR -> the file on disk.
	onDisk, err := os.ReadFile(filepath.Join(home, "data", "vibecheck", "config.json"))
	if err != nil {
		t.Fatalf("config.json not on disk: %v", err)
	}
	var saved struct {
		Sensitivity float64 `json:"sensitivity"`
	}
	if err := json.Unmarshal(onDisk, &saved); err != nil {
		t.Fatal(err)
	}
	if saved.Sensitivity != 0.7 {
		t.Fatalf("sensitivity on disk = %v, want 0.7", saved.Sensitivity)
	}
}
```

`TestConfigPersistsToTheDataDir` will not pass until Task 10 lands the config store. Mark it `t.Skip("config store arrives in Task 10")` for now and remove the skip in Task 10.

- [ ] **Step 2: Write go.mod**

```
module github.com/vibecare-io/vibecare/plugins/vibecheck

go 1.23.0

replace github.com/vibecare-io/vibecare/backend => ../../backend

require (
	github.com/vibecare-io/vibecare/backend v0.0.0-00010101000000-000000000000
	go.uber.org/zap v1.27.0
)
```

Copy the indirect-require block verbatim from `plugins/todo/go.mod`. Do **not** run `go mod tidy` against the backend module.

- [ ] **Step 3: Run the e2e to verify it fails**

Run: `cd plugins/vibecheck && go test ./... -run TestPluginServesUIAndAPIThroughTheProxy -v`
Expected: FAIL — "plugin never became reachable through the proxy", because `main.swift` is still the placeholder.

- [ ] **Step 4: Write the real main.swift**

```swift
import Foundation
import VCPluginSDK

// Composition root. Order matters: routes before connect, because connect
// binds, accepts, and registers — and the proxy targets our port the instant
// core marks us up.
let env: VCEnvironment
switch VCEnvironment.fromProcess() {
case .success(let e): env = e
case .failure(let err):
    // Nothing to serve and nothing to retry — this is a misconfigured spawn,
    // not a transient failure. This is the ONE place exiting is correct,
    // because there is no core connection to degrade against.
    FileHandle.standardError.write(Data("vibecheck: \(err)\n".utf8))
    exit(1)
}

let router = VCRouter()

await router.handle("/") { _, w in
    try await w.writeHead(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"])
    try await w.write(uiIndexHTML())
    try await w.finish()
}

await router.handle("/api/state") { _, w in
    try await w.writeHead(status: 200, headers: ["Content-Type": "application/json"])
    try await w.write(Data(#"{"running":false}"#.utf8))
    try await w.finish()
}

let host = try await VCHost.connect(env: env, router: router)

// Register the shutdown hook immediately after connecting: the Go SDK has a
// once-guard that can burn if SIGTERM lands in the gap, and we must not
// reproduce it.
await host.onShutdown { }

// Park forever. Returning from main would exit the process, and an
// unrequested exit is charged as a failed start — five of those and core
// parks us in StateFailed until a manual dashboard restart.
try await Task.sleep(for: .seconds(Int.max))
```

`uiIndexHTML()` reads `ui/index.html` from the SwiftPM resource bundle. Task 16 replaces it with the real page.

- [ ] **Step 5: Write a minimal ui/index.html**

```html
<!doctype html>
<meta charset="utf-8">
<title>VibeCheck</title>
<h1>VibeCheck</h1>
<p>Detection UI arrives in Task 16.</p>
```

- [ ] **Step 6: Run the e2e to verify it passes**

Run: `cd plugins/vibecheck && go test ./... -v`
Expected: PASS for the proxy, roster, and 401 tests; SKIP for the config test.

- [ ] **Step 7: Add the test recipe**

Find the todo test recipe near `Justfile:732` and add alongside it:

```just
    cd plugins/vibecheck && swift test
    cd plugins/vibecheck && go test ./...
```

- [ ] **Step 8: Confirm it in the real app**

Run `just run`, then `just swift-run`. A **VibeCheck** tab appears in the sidebar with the placeholder page. This is the first end-to-end confirmation and is worth doing by hand — the webview rendering path has never been visually confirmed in this codebase.

- [ ] **Step 9: Commit**

```bash
git add plugins/vibecheck/Sources/vibecheck/main.swift plugins/vibecheck/ui \
        plugins/vibecheck/go.mod plugins/vibecheck/go.sum \
        plugins/vibecheck/e2e_test.go Justfile
git commit -m "feat(vibecheck): register with core and serve through the proxy"
git show --stat
```

---

## Task 7: Geometry types in viewer space

The coordinate conversion the whole plan hinges on. `BFRB.swift` moves here, with its documented convention **inverted**.

**Files:**
- Create: `plugins/vibecheck/Sources/VibeCheckKit/Geometry.swift`
- Test: `plugins/vibecheck/Tests/VibeCheckKitTests/GeometryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `BFRBBehavior`, `HandGeometry`, `FaceGeometry`, `HairMask`, `LandmarkFrame`, plus `ViewerSpace.point(_:)` / `ViewerSpace.rect(_:)` converters.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import CoreGraphics
@testable import VibeCheckKit

@Test func pointConversionFlipsYAndLeavesXAlone() {
    // Vision: origin bottom-left, y up. Viewer: origin top-left, y down.
    // x is NEVER touched — the front-camera buffer is already mirrored and
    // re-mirroring draws everything on the wrong horizontal side.
    let p = ViewerSpace.point(CGPoint(x: 0.25, y: 0.75))
    #expect(p.x == 0.25)
    #expect(p.y == 0.25)
}

@Test func rectConversionMapsTopEdgeCorrectly() {
    // A Vision box sitting in the upper half: y=0.6, height=0.3, so its top
    // edge is at y-up 0.9 -> viewer y 0.1. Height is unchanged.
    let r = ViewerSpace.rect(CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3))
    #expect(r.minX == 0.1)
    #expect(abs(r.minY - 0.1) < 1e-9)
    #expect(r.width == 0.2)
    #expect(abs(r.height - 0.3) < 1e-9)
}

@Test func conversionIsItsOwnInverse() {
    let original = CGPoint(x: 0.3, y: 0.8)
    #expect(ViewerSpace.point(ViewerSpace.point(original)) == original)
}

@Test func hairMaskRowZeroIsTopInViewerSpace() {
    // 2 cols x 2 rows, only the top-left cell set.
    let mask = HairMask(cols: 2, rows: 2, cells: [true, false, false, false])
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.25, y: 0.25)) == true)   // top-left
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.75, y: 0.25)) == false)  // top-right
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.25, y: 0.75)) == false)  // bottom-left
}

@Test func hairMaskClampsAndRejectsOutOfRange() {
    let mask = HairMask(cols: 2, rows: 2, cells: [true, true, true, true])
    #expect(mask.isPerson(atNormalized: CGPoint(x: -0.1, y: 0.5)) == false)
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.5, y: 1.1)) == false)
    #expect(mask.isPerson(atNormalized: CGPoint(x: 1.0, y: 1.0)) == true)   // clamped edge
}

@Test func emptyMaskIsNeverPerson() {
    let mask = HairMask(cols: 0, rows: 0, cells: [])
    #expect(mask.isPerson(atNormalized: CGPoint(x: 0.5, y: 0.5)) == false)
}

@Test func everyBehaviorHasNonEmptyPresentation() {
    for b in BFRBBehavior.allCases {
        #expect(!b.label.isEmpty)
        #expect(!b.nudge.isEmpty)
        #expect(!b.alertIcon.isEmpty)
        #expect(!b.defaultIconId.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd plugins/vibecheck && swift test --filter GeometryTests`
Expected: FAIL — `cannot find 'ViewerSpace' in scope`.

- [ ] **Step 3: Write the implementation**

Copy `clients/macos-swift/VibeCare/vibecare/Models/BFRB.swift` verbatim, then apply exactly these changes:

1. Replace the `HandGeometry`/`FaceGeometry` doc comment with the viewer-space statement.
2. Change `HairMask`'s `isPerson` row computation from `Int((1 - p.y) * CGFloat(rows))` to `Int(p.y * CGFloat(rows))`.
3. Add the `ViewerSpace` enum.
4. Add `ts`, `seq`, and `mirrored` to `LandmarkFrame`.

```swift
import CoreGraphics
import Foundation

/// Converts Vision's normalized coordinates (origin bottom-left, y UP) into
/// viewer space (origin top-left, y DOWN) — the frame as the user sees
/// themselves in a mirrored selfie preview, per architecture v2 §10.1.
///
/// x is deliberately untouched. The macOS front-camera buffer is already
/// x-mirrored by AVCaptureConnection's automaticallyAdjustsVideoMirroring,
/// so the landmark x already aligns with what is on screen. A source that is
/// NOT mirrored must be flipped by the capture layer before it reaches here
/// (see CameraSession.isSourceMirrored) — not by consumers.
public enum ViewerSpace {
    public static func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: 1 - p.y)
    }

    /// A Vision rect's TOP edge is at y-up `maxY`, which becomes viewer
    /// `1 - maxY`. Width and height are unchanged.
    public static func rect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }
}

/// All points are normalized [0,1] in VIEWER space: origin top-left,
/// x increases right, y increases DOWN. Consumers never re-convert.
public struct HandGeometry: Sendable { public var fingertips: [CGPoint] }
public struct FaceGeometry: Sendable {
    public var box: CGRect
    public var nose: CGPoint
    public var mouth: CGPoint
}

/// Coarse boolean grid of the person-segmentation mask, row-major,
/// row 0 = TOP. In viewer space y=0 is the top, so the row index is a
/// direct scale of y with no flip.
public struct HairMask: Sendable, Equatable {
    public let cols: Int
    public let rows: Int
    public let cells: [Bool]

    public func isPerson(atNormalized p: CGPoint) -> Bool {
        guard cols > 0, rows > 0, p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return false }
        let col = min(cols - 1, max(0, Int(p.x * CGFloat(cols))))
        let row = min(rows - 1, max(0, Int(p.y * CGFloat(rows))))
        return cells[row * cols + col]
    }
}

public struct LandmarkFrame: Sendable {
    public var hand: HandGeometry?
    public var face: FaceGeometry?
    public var imageSize: CGSize = .zero
    public var hairMask: HairMask?
    /// Capture time, not analysis time. Sampling at analysis time folds
    /// inference latency into the timestamp, which step 6's ±250ms
    /// conformance budget cannot absorb.
    public var ts: Date = Date()
    /// Monotonic per provider. Gaps mean dropped frames — the 15fps throttle
    /// discards frames and today there is no record of it.
    public var seq: UInt64 = 0
    /// Whether the SOURCE was already mirrored. Recorded for diagnostics
    /// only; coordinates in this struct are always viewer space regardless.
    public var mirrored: Bool = true
}
```

`BFRBBehavior` moves verbatim — the enum, `label`, `alertIcon`, `nudge`, and `defaultIconId` are unchanged. Add `public` to the type and each member.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd plugins/vibecheck && swift test --filter GeometryTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Prove the y-flip guard can fail**

Temporarily change `ViewerSpace.point` to return `p` unchanged. Confirm `pointConversionFlipsYAndLeavesXAlone` and `hairMaskRowZeroIsTopInViewerSpace` go red. Restore.

- [ ] **Step 6: Commit**

```bash
git add plugins/vibecheck/Sources/VibeCheckKit/Geometry.swift \
        plugins/vibecheck/Tests/VibeCheckKitTests/GeometryTests.swift
git commit -m "feat(vibecheck): geometry types in viewer space (y-down)"
git show --stat
```

---

## Task 8: BFRBDetector in viewer space

**Files:**
- Create: `plugins/vibecheck/Sources/VibeCheckKit/BFRBDetector.swift`
- Test: `plugins/vibecheck/Tests/VibeCheckKitTests/BFRBDetectorTests.swift`

**Interfaces:**
- Consumes: `LandmarkFrame`, `FaceGeometry`, `HairMask`, `BFRBBehavior`.
- Produces: `struct DetectionResult { let behavior: BFRBBehavior; let point: CGPoint }` and `struct BFRBDetector { var sensitivity: Double; func detect(_:enabled:) -> DetectionResult?; static func hairZone(for: CGRect) -> CGRect }`.

- [ ] **Step 1: Write the failing test**

Port `clients/macos-swift/VibeCare/vibecareTests/BFRBDetectorTests.swift` (14 tests), inverting every y. The two below are the ones the flip actually changes; port the remaining 12 mechanically by replacing each literal `y` with `1 - y`.

```swift
import Testing
import CoreGraphics
@testable import VibeCheckKit

// Face box in VIEWER space: top edge at y=0.3, bottom at y=0.7.
private func face() -> FaceGeometry {
    FaceGeometry(box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4),
                 nose: CGPoint(x: 0.5, y: 0.5),
                 mouth: CGPoint(x: 0.5, y: 0.62))
}

@Test func fingertipOnTheNoseFiresNosePicking() {
    let d = BFRBDetector(sensitivity: 0.5)     // radius 0.08
    let frame = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.52, y: 0.5)]),
                              face: face())
    #expect(d.detect(frame, enabled: [.nosePicking])?.behavior == .nosePicking)
}

@Test func hairContactRequiresBeingABOVETheForehead() {
    // In viewer space "above the forehead" is a SMALLER y than box.minY.
    // This is the assertion the coordinate flip inverts; getting it backwards
    // makes the detector fire on the chin instead of the scalp.
    let d = BFRBDetector(sensitivity: 0.5)
    let above = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.2)]),
                              face: face())
    let below = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.8)]),
                              face: face())
    #expect(d.detect(above, enabled: [.hairPulling])?.behavior == .hairPulling)
    #expect(d.detect(below, enabled: [.hairPulling]) == nil)
}

@Test func hairZoneSitsAboveTheFaceBox() {
    let zone = BFRBDetector.hairZone(for: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4))
    #expect(abs(zone.maxY - 0.3) < 1e-9)      // bottom of the band meets the top of the face
    #expect(abs(zone.height - 0.2) < 1e-9)    // half the face height
    #expect(abs(zone.minX - 0.37) < 1e-9)     // padded 15% of face width
}

@Test func noHandOrNoFaceNeverFires() {
    let d = BFRBDetector(sensitivity: 1.0)
    #expect(d.detect(LandmarkFrame(hand: nil, face: face()), enabled: [.nosePicking]) == nil)
    #expect(d.detect(LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.5)]),
                                   face: nil), enabled: [.nosePicking]) == nil)
}

@Test func disabledBehaviorsNeverFire() {
    let d = BFRBDetector(sensitivity: 0.5)
    let frame = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.5)]),
                              face: face())
    #expect(d.detect(frame, enabled: []) == nil)
}

@Test func nosePickingWinsOverNailBitingForTheSameFingertip() {
    // First-match-wins, and the order within a fingertip is nose -> mouth ->
    // hair. A tip equidistant from nose and mouth reports nose-picking.
    let d = BFRBDetector(sensitivity: 1.0)     // radius 0.12, both in range
    let frame = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.56)]),
                              face: face())
    #expect(d.detect(frame, enabled: [.nosePicking, .nailBiting])?.behavior == .nosePicking)
}

@Test func maskOverridesTheGeometricZoneWhenPresent() {
    let d = BFRBDetector(sensitivity: 0.5)
    let allFalse = HairMask(cols: 2, rows: 2, cells: [false, false, false, false])
    let frame = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.2)]),
                              face: face(), hairMask: allFalse)
    // Inside the geometric zone, but the mask says "not person" — mask wins.
    #expect(d.detect(frame, enabled: [.hairPulling]) == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd plugins/vibecheck && swift test --filter BFRBDetectorTests`
Expected: FAIL — `cannot find 'BFRBDetector' in scope`.

- [ ] **Step 3: Write the implementation**

Copy `Services/Detection/BFRBDetector.swift` verbatim, mark the types `public`, and apply exactly two changes:

```swift
    /// Hair zone: a band ABOVE the forehead in viewer space — from half a
    /// face-height above the box top, down to the box top — extended
    /// laterally past the temples by 15% of face width.
    public static func hairZone(for box: CGRect) -> CGRect {
        let pad = box.width * 0.15
        let height = box.height * 0.5
        return CGRect(x: box.minX - pad,
                      y: box.minY - height,
                      width: box.width + 2 * pad,
                      height: height)
    }

    private func isHairContact(_ p: CGPoint, face: FaceGeometry, mask: HairMask?) -> Bool {
        guard p.y < face.box.minY else { return false }   // above the forehead (viewer space)
        if let mask, mask.cols > 0 {
            return mask.isPerson(atNormalized: p)
        }
        return Self.hairZone(for: face.box).contains(p)
    }
```

`detect`, `sensitivity`, and `distance` are unchanged. Note that `distance` is **not** aspect-corrected, so the trigger region is an ellipse in pixel space on a 16:9 frame. Preserve that exactly — changing it silently retunes every user's sensitivity.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd plugins/vibecheck && swift test --filter BFRBDetectorTests`
Expected: PASS, all ported tests.

- [ ] **Step 5: Commit**

```bash
git add plugins/vibecheck/Sources/VibeCheckKit/BFRBDetector.swift \
        plugins/vibecheck/Tests/VibeCheckKitTests/BFRBDetectorTests.swift
git commit -m "feat(vibecheck): BFRB fingertip geometry in viewer space"
git show --stat
```

---

## Task 9: DetectionPolicy

A verbatim move. The file has no coordinate dependency and no clock dependency — time is injected.

**Files:**
- Create: `plugins/vibecheck/Sources/VibeCheckKit/DetectionPolicy.swift`
- Test: `plugins/vibecheck/Tests/VibeCheckKitTests/DetectionPolicyTests.swift`

**Interfaces:**
- Consumes: `DetectionResult`, `BFRBBehavior`.
- Produces: `struct BFRBEvent { let behavior: BFRBBehavior; let time: TimeInterval }` and `struct DetectionPolicy { var dwell, cooldown: TimeInterval; init(dwell:cooldown:); mutating func ingest(_:at:) -> BFRBEvent? }`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import CoreGraphics
@testable import VibeCheckKit

private func hit(_ b: BFRBBehavior) -> DetectionResult {
    DetectionResult(behavior: b, point: CGPoint(x: 0.5, y: 0.5))
}

@Test func firesOnlyAfterContinuousDwell() {
    var p = DetectionPolicy(dwell: 0.15, cooldown: 5)
    #expect(p.ingest(hit(.nailBiting), at: 0) == nil)
    #expect(p.ingest(hit(.nailBiting), at: 0.10) == nil)
    #expect(p.ingest(hit(.nailBiting), at: 0.20)?.behavior == .nailBiting)
}

@Test func anyGapResetsDwell() {
    // Dwell is CONTINUOUS presence, not a hit count. One frame without a hit
    // — hand leaves frame, Vision misses, confidence dips — starts over.
    var p = DetectionPolicy(dwell: 0.15, cooldown: 5)
    _ = p.ingest(hit(.nailBiting), at: 0)
    #expect(p.ingest(nil, at: 0.10) == nil)
    #expect(p.ingest(hit(.nailBiting), at: 0.20) == nil)
    #expect(p.ingest(hit(.nailBiting), at: 0.40)?.behavior == .nailBiting)
}

@Test func cooldownSuppressesRepeatsOfTheSameBehavior() {
    var p = DetectionPolicy(dwell: 0.15, cooldown: 5)
    _ = p.ingest(hit(.nailBiting), at: 0)
    #expect(p.ingest(hit(.nailBiting), at: 0.2)?.behavior == .nailBiting)
    _ = p.ingest(hit(.nailBiting), at: 1.0)
    #expect(p.ingest(hit(.nailBiting), at: 2.0) == nil)     // inside cooldown
    _ = p.ingest(hit(.nailBiting), at: 6.0)
    #expect(p.ingest(hit(.nailBiting), at: 6.5)?.behavior == .nailBiting)
}

@Test func cooldownIsPerBehaviorSoTwoCanFireBackToBack() {
    var p = DetectionPolicy(dwell: 0.15, cooldown: 5)
    _ = p.ingest(hit(.nailBiting), at: 0)
    #expect(p.ingest(hit(.nailBiting), at: 0.2)?.behavior == .nailBiting)
    _ = p.ingest(hit(.nosePicking), at: 0.3)
    #expect(p.ingest(hit(.nosePicking), at: 0.5)?.behavior == .nosePicking)
}

@Test func dwellIsExclusiveAcrossBehaviors() {
    // Switching regions restarts the clock; you cannot accumulate dwell on
    // two behaviors at once.
    var p = DetectionPolicy(dwell: 0.15, cooldown: 5)
    _ = p.ingest(hit(.nailBiting), at: 0)
    _ = p.ingest(hit(.nosePicking), at: 0.10)
    #expect(p.ingest(hit(.nailBiting), at: 0.16) == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd plugins/vibecheck && swift test --filter DetectionPolicyTests`
Expected: FAIL — `cannot find 'DetectionPolicy' in scope`.

- [ ] **Step 3: Write the implementation**

Copy `Services/Detection/DetectionPolicy.swift` verbatim and mark `BFRBEvent`, `DetectionPolicy`, `dwell`, `cooldown`, `init`, and `ingest` as `public`. No logic changes.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd plugins/vibecheck && swift test --filter DetectionPolicyTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add plugins/vibecheck/Sources/VibeCheckKit/DetectionPolicy.swift \
        plugins/vibecheck/Tests/VibeCheckKitTests/DetectionPolicyTests.swift
git commit -m "feat(vibecheck): dwell/cooldown detection policy"
git show --stat
```

---

## Task 10: Config, alert-prefs, and date-keyed counts on disk

Replaces `UserDefaults`, which a bare binary cannot use correctly — it has no bundle id, so `UserDefaults.standard` resolves to an argv0-derived domain and writes land in `~/Library/Preferences/`, outside the data dir.

**Files:**
- Create: `plugins/vibecheck/Sources/VibeCheckKit/ConfigStore.swift`
- Create: `plugins/vibecheck/Sources/VibeCheckKit/AlertPrefsStore.swift`
- Create: `plugins/vibecheck/Sources/VibeCheckKit/CountsStore.swift`
- Create: `plugins/vibecheck/Sources/VibeCheckKit/Ordinal.swift`
- Test: `plugins/vibecheck/Tests/VibeCheckKitTests/StoreTests.swift`
- Modify: `plugins/vibecheck/e2e_test.go` (remove the `t.Skip`)

**Interfaces:**
- Consumes: `BFRBBehavior`.
- Produces:
  ```swift
  public struct VibeCheckConfig: Codable, Sendable, Equatable {
      public var enabled: Bool
      public var sensitivity: Double        // 0...1
      public var dwell: TimeInterval        // was hardcoded 0.15
      public var cooldown: TimeInterval     // 1...30
      public var enabledBehaviors: [String] // BFRBBehavior raw values
      public static let `default`: VibeCheckConfig
  }
  public actor ConfigStore {
      public init(directory: URL) throws
      public func load() -> VibeCheckConfig
      public func save(_ c: VibeCheckConfig) throws
  }
  public actor CountsStore {
      public init(directory: URL) throws
      public func increment(_ behavior: BFRBBehavior, on day: String) throws -> Int
      public func count(_ behavior: BFRBBehavior, on day: String) -> Int
      public static func dayKey(_ date: Date) -> String   // "yyyy-MM-dd", local time
  }
  public enum Ordinal { public static func format(_ n: Int) -> String }
  ```

Four values that are RAM-only today become persistent: `sensitivity`, `cooldown`, `enabledBehaviors`, and `dwell`. Every relaunch silently resets them today.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import VibeCheckKit

private func tempDir() throws -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Test func configRoundTripsThroughDisk() async throws {
    let dir = try tempDir()
    let store = try ConfigStore(directory: dir)
    var c = VibeCheckConfig.default
    c.sensitivity = 0.7
    c.enabledBehaviors = ["nailBiting"]
    try await store.save(c)

    // A fresh store, so this reads the file rather than an in-memory cache.
    // An in-memory round trip would pass even against a no-op flush.
    let reloaded = try ConfigStore(directory: dir)
    #expect(await reloaded.load().sensitivity == 0.7)
    #expect(await reloaded.load().enabledBehaviors == ["nailBiting"])
}

@Test func missingConfigFileYieldsDefaults() async throws {
    let store = try ConfigStore(directory: try tempDir())
    #expect(await store.load() == VibeCheckConfig.default)
}

@Test func corruptConfigFileYieldsDefaultsRatherThanCrashing() async throws {
    let dir = try tempDir()
    try Data("not json".utf8).write(to: dir.appendingPathComponent("config.json"))
    let store = try ConfigStore(directory: dir)
    // Refusing to start because a config file got truncated would be an
    // unrequested exit — five of those park the plugin in StateFailed.
    #expect(await store.load() == VibeCheckConfig.default)
}

@Test func countsAreKeyedByDayAndPersist() async throws {
    let dir = try tempDir()
    let store = try CountsStore(directory: dir)
    #expect(try await store.increment(.nailBiting, on: "2026-08-14") == 1)
    #expect(try await store.increment(.nailBiting, on: "2026-08-14") == 2)
    #expect(try await store.increment(.nailBiting, on: "2026-08-15") == 1)
    #expect(try await store.increment(.nosePicking, on: "2026-08-14") == 1)

    let reloaded = try CountsStore(directory: dir)
    #expect(await reloaded.count(.nailBiting, on: "2026-08-14") == 2)
}

@Test func ordinalFollowsEnglishRules() {
    #expect(Ordinal.format(1) == "1st")
    #expect(Ordinal.format(2) == "2nd")
    #expect(Ordinal.format(3) == "3rd")
    #expect(Ordinal.format(4) == "4th")
    #expect(Ordinal.format(11) == "11th")
    #expect(Ordinal.format(12) == "12th")
    #expect(Ordinal.format(13) == "13th")
    #expect(Ordinal.format(21) == "21st")
    #expect(Ordinal.format(22) == "22nd")
    #expect(Ordinal.format(23) == "23rd")
    #expect(Ordinal.format(101) == "101st")
    #expect(Ordinal.format(111) == "111th")
    #expect(Ordinal.format(112) == "112th")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd plugins/vibecheck && swift test --filter StoreTests`
Expected: FAIL — `cannot find 'ConfigStore' in scope`.

- [ ] **Step 3: Write ConfigStore.swift**

```swift
import Foundation

public struct VibeCheckConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var sensitivity: Double
    public var dwell: TimeInterval
    public var cooldown: TimeInterval
    public var enabledBehaviors: [String]

    /// Matches the values the client's view model used, except that dwell was
    /// hardcoded at 0.15 and is now configurable, and all of these were
    /// RAM-only and reset on every relaunch.
    public static let `default` = VibeCheckConfig(
        enabled: false,
        sensitivity: 0.5,
        dwell: 0.15,
        cooldown: 5,
        enabledBehaviors: BFRBBehavior.allCases.map(\.rawValue)
    )

    /// Clamps to the ranges the UI exposes, so a hand-edited file or a
    /// malformed PUT cannot put the detector into a nonsense state.
    public func clamped() -> VibeCheckConfig {
        var c = self
        c.sensitivity = min(1, max(0, sensitivity))
        c.cooldown = min(30, max(1, cooldown))
        c.dwell = min(5, max(0, dwell))
        return c
    }
}

public actor ConfigStore {
    private let url: URL
    private var cached: VibeCheckConfig

    public init(directory: URL) throws {
        self.url = directory.appendingPathComponent("config.json")
        // A missing or corrupt file is not a reason to fail: refusing to
        // start would be an unrequested exit, and five of those park the
        // plugin in StateFailed until a manual dashboard restart.
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(VibeCheckConfig.self, from: data) {
            self.cached = decoded.clamped()
        } else {
            self.cached = .default
        }
    }

    public func load() -> VibeCheckConfig { cached }

    public func save(_ c: VibeCheckConfig) throws {
        let clamped = c.clamped()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(clamped)
        // Atomic: a partially-written config that fails to parse on next
        // launch would silently reset every one of the user's settings.
        try data.write(to: url, options: .atomic)
        cached = clamped
    }
}
```

`CountsStore` follows the same shape over `[String: [String: Int]]` keyed `day -> behavior -> count`, writing atomically. `AlertPrefsStore` stores `[String: NotificationPreferences]` where `NotificationPreferences` is a local copy of the client's Codable shape (13 fields — `bundledIconId`, `svgPath`, `svgWidth`, `svgHeight`, `title`, `message`, `position`, `width`, `height`, `moveable`, `autoDismissAfter`, `screenBlurEnabled`, `screenBlurIntensity`), byte-compatible with the client's existing `vibecheck.alert.preferences` blob so a user's settings can be lifted across. Seed defaults with `svgPath` pointing at `icons/<defaultIconId>.svg` — **plugin-relative**, because the client's `backend_url` is not available here.

- [ ] **Step 4: Write Ordinal.swift**

```swift
import Foundation

/// Formats the "Nth nudge today" copy. Moved from the client's
/// VibeNotifyConfiguration.ordinal, which is deleted in Task 18.
public enum Ordinal {
    public static func format(_ n: Int) -> String {
        let tens = n % 100
        if (11...13).contains(tens) { return "\(n)th" }
        switch n % 10 {
        case 1:  return "\(n)st"
        case 2:  return "\(n)nd"
        case 3:  return "\(n)rd"
        default: return "\(n)th"
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd plugins/vibecheck && swift test --filter StoreTests`
Expected: PASS, 5 tests.

- [ ] **Step 6: Wire /api/config and un-skip the e2e**

Add `GET` and `PUT /api/config` handlers to `main.swift` backed by `ConfigStore`, then remove the `t.Skip` from `TestConfigPersistsToTheDataDir`.

Run: `cd plugins/vibecheck && go test ./... -run TestConfigPersistsToTheDataDir -v`
Expected: PASS. This is the assertion that proves `DataRoot → VIBECARE_DATA_DIR → file on disk` is really wired, independently of the process that wrote it.

- [ ] **Step 7: Commit**

```bash
git add plugins/vibecheck/Sources/VibeCheckKit/ConfigStore.swift \
        plugins/vibecheck/Sources/VibeCheckKit/AlertPrefsStore.swift \
        plugins/vibecheck/Sources/VibeCheckKit/CountsStore.swift \
        plugins/vibecheck/Sources/VibeCheckKit/Ordinal.swift \
        plugins/vibecheck/Tests/VibeCheckKitTests/StoreTests.swift \
        plugins/vibecheck/Sources/vibecheck/main.swift \
        plugins/vibecheck/e2e_test.go
git commit -m "feat(vibecheck): file-backed config, alert prefs, and date-keyed counts"
git show --stat
```

---

## Task 11: Headless CameraSession with mirroring normalization

**Files:**
- Create: `plugins/vibecheck/Sources/vibecheck/CameraSession.swift`
- Test: manual (see Step 5) — `AVCaptureSession` cannot be unit-tested without hardware.

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  ```swift
  protocol CameraFrameReceiver: AnyObject, Sendable {
      func didOutput(_ pixelBuffer: CVPixelBuffer, mirrored: Bool)
  }
  final class CameraSession: NSObject {
      var receiver: CameraFrameReceiver?
      func start() async -> CameraStartResult   // .started | .denied | .noDevice
      func stop()
      var isSourceMirrored: Bool { get }
  }
  enum CameraStartResult { case started, denied, noDevice }
  ```

Two changes from the client's version:

1. **`previewLayer` is deleted.** It is CoreAnimation handed to the window server and has no meaning in a daemon. Its replacement is the MJPEG stream in Task 14. Deleting it does **not** break mirroring — `automaticallyAdjustsVideoMirroring` belongs to `AVCaptureConnection`, and the data output's connection has its own instance.
2. **Mirroring is now read, not assumed.** `AVCaptureDevice.default(for: .video)` can select an external USB webcam or a Continuity Camera, which are **not** auto-mirrored. Today nothing detects this and every x is silently wrong in that case.

- [ ] **Step 1: Copy the source and delete the preview layer**

Copy `clients/macos-swift/VibeCare/vibecare/Services/Detection/CameraSession.swift`. Remove `import Logging` (use `FileHandle.standardError` or a small local logger), the `previewLayer` property, its initializer line, and the `videoGravity` assignment.

- [ ] **Step 2: Change the receiver protocol to carry the mirroring flag**

```swift
protocol CameraFrameReceiver: AnyObject, Sendable {
    /// `mirrored` reports whether the SOURCE connection already mirrored x.
    /// The extractor uses it to normalize into viewer space; nothing
    /// downstream of LandmarkFrame ever sees it.
    func didOutput(_ pixelBuffer: CVPixelBuffer, mirrored: Bool)
}
```

```swift
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Read it per frame rather than caching: isVideoMirrored is only
        // meaningful once the connection is ready, and the client hit exactly
        // this timing bug — forcing it in configure() took effect on
        // first-open but not re-open, flipping the overlay's coordinate
        // space depending on timing.
        receiver?.didOutput(pixelBuffer, mirrored: connection.isVideoMirrored)
    }
```

- [ ] **Step 3: Change `start()` to distinguish denial from absence**

```swift
    /// Returns why it failed, because the UI must tell "grant camera access"
    /// apart from "no camera found" — and because neither is a reason to
    /// exit the process.
    func start() async -> CameraStartResult {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            // Needs a live run loop to deliver the completion. main.swift
            // parks on an async sleep rather than returning, so one exists.
            guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
        default:
            return .denied
        }
        if session.inputs.isEmpty {
            guard configure() else { return .noDevice }
        }
        frameQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
        return .started
    }
```

Keep the `configure()` comment about **not** touching mirroring on the output connection verbatim — it documents a real bug that was hit and fixed empirically.

- [ ] **Step 4: Build**

Run: `cd plugins/vibecheck && swift build -c release`
Expected: `Build complete!`

- [ ] **Step 5: Manual verification**

There is no way to unit-test this without hardware. Add a temporary `--probe-camera` argument to `main.swift` that starts the session, logs the first frame's dimensions and `mirrored` flag, and exits. Run the plugin under `just run`, hit the probe, and confirm: a camera prompt appears the first time, `mirrored=true` for the built-in camera, and the frame is 1280x720. Remove the temporary argument before committing.

- [ ] **Step 6: Commit**

```bash
git add plugins/vibecheck/Sources/vibecheck/CameraSession.swift
git commit -m "feat(vibecheck): headless camera session reporting source mirroring"
git show --stat
```

---

## Task 12: VisionLandmarkExtractor producing viewer space

**Files:**
- Create: `plugins/vibecheck/Sources/vibecheck/VisionLandmarkExtractor.swift`
- Test: `plugins/vibecheck/Tests/VibeCheckKitTests/` — not unit-testable (needs Vision + a real buffer); covered by the manual check in Step 4.

**Interfaces:**
- Consumes: `LandmarkFrame`, `ViewerSpace`, `HandGeometry`, `FaceGeometry`, `HairMask`.
- Produces: `struct VisionLandmarkExtractor { func analyze(_ pixelBuffer: CVPixelBuffer, mirrored: Bool, seq: UInt64, ts: Date) -> LandmarkFrame }`.

- [ ] **Step 1: Copy the source**

Copy `clients/macos-swift/VibeCare/vibecare/Services/Detection/VisionLandmarkExtractor.swift`. Replace `import Logging` with a local stderr logger.

- [ ] **Step 2: Add the coordinate normalization**

Add a single conversion closure used by **every** point and rect leaving this type. This is the only place in the plugin where Vision's convention exists.

```swift
    /// The one place Vision's coordinate space is converted. Everything that
    /// leaves this type is viewer space: origin top-left, y down, x already
    /// aligned with what the user sees.
    ///
    /// y is always flipped (Vision is y-up). x is flipped ONLY when the
    /// source was not already mirrored — an external USB webcam or a
    /// Continuity Camera is not auto-mirrored, and without this every x
    /// would be silently wrong for those devices.
    private func normalize(_ p: CGPoint, mirrored: Bool) -> CGPoint {
        let x = mirrored ? p.x : 1 - p.x
        return CGPoint(x: x, y: 1 - p.y)
    }

    private func normalize(_ r: CGRect, mirrored: Bool) -> CGRect {
        let minX = mirrored ? r.minX : 1 - r.maxX
        return CGRect(x: minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }
```

Thread `mirrored` through `extractHand`, `extractFace`, and `extractHairMask`, applying `normalize` to every fingertip, the face box, nose, mouth, and the two fallback points.

- [ ] **Step 3: Fix the hair-mask row order and x mirroring**

The mask grid is sampled from the buffer top-down and stored row 0 = top. In viewer space y=0 is also the top, so **the row order is now correct with no flip** — and `HairMask.isPerson` was changed in Task 7 to match. Update the doc comment to say so; the old comment describes the y-up reconciliation that no longer happens.

When `mirrored` is false, the mask columns must be reversed as well, or the mask and the landmarks disagree:

```swift
                let sourceCol = mirrored ? c : (cols - 1 - c)
                let mx = min(maskWidth - 1,
                             Int((CGFloat(sourceCol) + 0.5) / CGFloat(cols) * CGFloat(maskWidth)))
```

- [ ] **Step 4: Add ts and seq, and set the mirrored flag**

```swift
        return LandmarkFrame(hand: extractHand(mirrored: mirrored),
                             face: extractFace(mirrored: mirrored),
                             imageSize: imageSize,
                             hairMask: extractHairMask(mirrored: mirrored),
                             ts: ts,
                             seq: seq,
                             mirrored: mirrored)
```

`ts` is passed in from the capture callback, **not** sampled here — sampling after Vision has run folds inference latency into the timestamp, which step 6's ±250ms conformance budget cannot absorb.

- [ ] **Step 5: Build and verify manually**

Run: `cd plugins/vibecheck && swift build -c release`

Then, with the camera running, confirm through the temporary probe that a face box has `minY < maxY` with `minY` in the upper half when you are centered in frame, and that a fingertip raised **above** your head reports a **smaller** y than the face box's `minY`. Getting this backwards is the single most likely silent failure in this plan.

- [ ] **Step 6: Commit**

```bash
git add plugins/vibecheck/Sources/vibecheck/VisionLandmarkExtractor.swift
git commit -m "feat(vibecheck): Vision extraction normalized to viewer space"
git show --stat
```

---

## Task 13: DetectionEngine — the actor that replaces the view model

**Files:**
- Create: `plugins/vibecheck/Sources/vibecheck/DetectionEngine.swift`
- Test: `plugins/vibecheck/Tests/VibeCheckKitTests/DetectionEngineTests.swift`

**Interfaces:**
- Consumes: `CameraSession`, `VisionLandmarkExtractor`, `BFRBDetector`, `DetectionPolicy`, `ConfigStore`, `CountsStore`, `AlertPrefsStore`, `VCHost`.
- Produces:
  ```swift
  actor DetectionEngine {
      init(config: ConfigStore, counts: CountsStore, prefs: AlertPrefsStore, sink: DetectionSink)
      func start() async -> CameraStartResult
      func stop() async
      func apply(_ config: VibeCheckConfig) async
      func snapshot() -> EngineSnapshot
      func frames() -> AsyncStream<LandmarkFrame>
  }
  protocol DetectionSink: Sendable {
      func fired(_ event: BFRBEvent, count: Int, behavior: BFRBBehavior) async
  }
  struct EngineSnapshot: Codable, Sendable {
      var running: Bool
      var permission: String        // "granted" | "denied" | "noDevice" | "unknown"
      var config: VibeCheckConfig
      var todayCounts: [String: Int]
  }
  ```

**`DetectionSink` exists so the engine can be tested without core.** The production implementation calls `VCHost.alert` and `VCHost.publish`; the test uses a spy. This mirrors the `DetectionNotifying` seam the client already had.

The pipeline preserved verbatim from `VibeCheckViewModel.didOutput`/`consume`:

- 15 fps throttle (`minInterval = 1.0 / 15.0`);
- Vision runs on the capture queue, detection on the engine actor;
- `detector.sensitivity` and `policy.cooldown` are re-read from config **every frame**, so a slider move takes effect immediately;
- `policy.ingest(result, at: <time>)`.

**One change:** the client used `Date().timeIntervalSinceReferenceDate`, a wall clock. A clock adjustment can produce a negative delta and defeat the cooldown. Use a monotonic source (`ContinuousClock` / `uptimeNanoseconds`) for policy time. The `ts` on `LandmarkFrame` stays a wall-clock `Date` because it is a timestamp, not a duration.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import CoreGraphics
@testable import VibeCheckKit

private actor SpySink: DetectionSink {
    // Named `calls`, not `fired` — a stored property and a method cannot
    // share a base name in Swift, and the protocol requirement is `fired`.
    private(set) var calls: [(BFRBBehavior, Int)] = []
    func fired(_ event: BFRBEvent, count: Int, behavior: BFRBBehavior) async {
        calls.append((behavior, count))
    }
}

@Test func firesThroughTheSinkWithAPostIncrementCount() async throws {
    // The client's notifier asserted the count is post-increment — the first
    // nudge of the day reads "1st", not "0th".
    let engine = try makeTestEngine()
    let sink = SpySink()
    await engine.setSink(sink)

    // Feed frames directly, bypassing the camera.
    let face = FaceGeometry(box: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.4),
                            nose: CGPoint(x: 0.5, y: 0.5),
                            mouth: CGPoint(x: 0.5, y: 0.62))
    let hit = LandmarkFrame(hand: HandGeometry(fingertips: [CGPoint(x: 0.5, y: 0.5)]),
                            face: face)
    await engine.ingestForTesting(hit, at: 0)
    await engine.ingestForTesting(hit, at: 0.2)

    let calls = await sink.calls
    #expect(calls.count == 1)
    #expect(calls[0].0 == .nosePicking)
    #expect(calls[0].1 == 1)
}

@Test func aDisabledBehaviorNeverReachesTheSink() async throws {
    let engine = try makeTestEngine(enabledBehaviors: [])
    let sink = SpySink()
    await engine.setSink(sink)
    // ... feed the same frames ...
    #expect(await sink.calls.isEmpty)
}

@Test func configChangesTakeEffectWithoutRestart() async throws {
    // The client re-read sensitivity and cooldown every frame so a slider
    // move applied immediately. Preserve that.
    let engine = try makeTestEngine(sensitivity: 0.0)   // radius 0.04
    let sink = SpySink()
    await engine.setSink(sink)
    // A fingertip 0.06 away is outside radius 0.04 but inside 0.12.
    // ... feed frames, expect nothing ...
    var c = VibeCheckConfig.default
    c.sensitivity = 1.0
    await engine.apply(c)
    // ... feed the same frames, expect a fire ...
}
```

`makeTestEngine`, `setSink`, and `ingestForTesting` are test-support entry points on the engine — `ingestForTesting` runs the detect→policy→sink path with an injected time, skipping the camera and Vision entirely.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd plugins/vibecheck && swift test --filter DetectionEngineTests`
Expected: FAIL — `cannot find 'DetectionEngine' in scope`.

- [ ] **Step 3: Write the implementation**

The actor owns `detector`, `policy`, `config`, `latestFrame`, `seq`, and the frame continuations. `CameraFrameReceiver.didOutput` hops onto the actor via a `Task`, applying the 15 fps throttle **before** running Vision so discarded frames cost nothing.

The three `nonisolated(unsafe)` escape hatches in the client's view model vanish — they existed only because `@MainActor` forced a boundary crossing, and there is no such boundary here.

- [ ] **Step 4: Write the production sink**

```swift
/// Production sink: an alert to every connected client, plus a bus publish.
/// The publish is an enhancement gated on presence — nothing subscribes to
/// this topic today, so it simply goes nowhere.
struct HostSink: DetectionSink {
    let host: VCHost
    let prefs: AlertPrefsStore

    func fired(_ event: BFRBEvent, count: Int, behavior: BFRBBehavior) async {
        let alert = VCAlert(
            title: behavior.label,
            body: "\(behavior.nudge) — \(Ordinal.format(count)) nudge today",
            level: "warn",
            actions: [
                VCAlertAction(label: "Snooze 10 min", url: "api/snooze?minutes=10"),
                VCAlertAction(label: "Turn off", url: "api/config/disable"),
            ]
        )
        do { try await host.alert(alert) } catch {
            log("alert failed: \(error)")   // never fatal — core may be reconnecting
        }
        do {
            try await host.publish(topic: "vibecheck.behavior_detected.v1",
                                   payload: Data(behavior.rawValue.utf8))
        } catch {
            log("publish failed: \(error)")
        }
    }
}
```

Level is `"warn"` so the banner holds for 8 s rather than 3 s. Only `"info"` and `"warn"` exist — anything else silently renders as info.

**The camera is gated on `config.enabled` alone.** Do **not** gate it on `_core.demand.v1`: `vibecheck` publishes `vibecheck.behavior_detected.v1`, nothing in-tree subscribes, the macOS client is not a bus participant, and the count is therefore structurally 0 forever. Gating on it means the camera never opens. That rule attaches to `sensor.landmarks.v1` at step 6.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd plugins/vibecheck && swift test --filter DetectionEngineTests`
Expected: PASS, 3 tests.

- [ ] **Step 6: Commit**

```bash
git add plugins/vibecheck/Sources/vibecheck/DetectionEngine.swift \
        plugins/vibecheck/Tests/VibeCheckKitTests/DetectionEngineTests.swift
git commit -m "feat(vibecheck): detection engine actor replacing the view model"
git show --stat
```

---

## Task 14: MJPEG preview stream

**Files:**
- Create: `plugins/vibecheck/Sources/vibecheck/JPEGEncoder.swift`
- Create: `plugins/vibecheck/Sources/vibecheck/PreviewStream.swift`
- Test: `plugins/vibecheck/Tests/VibeCheckKitTests/JPEGEncoderTests.swift`

**Interfaces:**
- Consumes: `CVPixelBuffer`, `VCResponseWriter`.
- Produces:
  ```swift
  enum JPEGEncoder { static func encode(_ buffer: CVPixelBuffer, quality: Double) -> Data? }
  actor PreviewStream {
      func attach(_ w: any VCResponseWriter) async
      func publish(_ buffer: CVPixelBuffer) async
      /// Framing helper, static so it is testable without a live stream.
      static func multipartChunk(_ jpeg: Data, boundary: String) -> Data
  }
  ```

`getUserMedia` is not an option: `PluginWebView.makeNSView` builds a bare `WKWebViewConfiguration` with no `uiDelegate`, so WebKit denies capture by default — and even if permitted, the prompt would attribute to the client. Frames come from the plugin over HTTP.

`proxy.go:64-74` names the MJPEG case explicitly and sets `FlushInterval: -1`, so per-write flush through the proxy is already guaranteed.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import CoreVideo
import Foundation
@testable import VibeCheckKit

private func solidBuffer(width: Int, height: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_32BGRA, nil, &buffer)
    return buffer!
}

@Test func encodesABufferToJPEGBytes() {
    let data = JPEGEncoder.encode(solidBuffer(width: 64, height: 48), quality: 0.6)
    let jpeg = try #require(data)
    #expect(jpeg.count > 0)
    // JPEG SOI marker.
    #expect(jpeg[0] == 0xFF && jpeg[1] == 0xD8)
}

@Test func multipartFrameCarriesBoundaryAndLength() {
    let payload = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let chunk = PreviewStream.multipartChunk(payload, boundary: "vcframe")
    let text = String(decoding: chunk, as: UTF8.self)
    #expect(text.hasPrefix("--vcframe\r\n"))
    #expect(text.contains("Content-Type: image/jpeg\r\n"))
    #expect(text.contains("Content-Length: 4\r\n"))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd plugins/vibecheck && swift test --filter JPEGEncoderTests`
Expected: FAIL — `cannot find 'JPEGEncoder' in scope`.

- [ ] **Step 3: Write the implementation**

`JPEGEncoder` uses `CIContext.jpegRepresentation(of:colorSpace:options:)` over a `CIImage(cvPixelBuffer:)`. Hold **one** `CIContext` in a `static let` — constructing one per frame is expensive enough to dominate the frame budget.

`PreviewStream` keeps a set of attached writers, encodes at most at the preview rate (independent of the 15 fps analysis rate — the preview can be slower), writes each frame as a multipart chunk, and drops any writer whose write throws.

The response head is:

```
Content-Type: multipart/x-mixed-replace; boundary=vcframe
Cache-Control: no-store
```

**The stream must idle when nobody is attached.** Encoding JPEGs into a void burns CPU for nothing.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd plugins/vibecheck && swift test --filter JPEGEncoderTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Verify streaming survives the proxy**

Add a Go e2e test that requests `/p/vibecheck/preview.mjpeg` through the proxy and asserts that **at least two** boundary markers arrive within 5 s while the response is still open. One frame proves nothing — MJPEG and SSE hang without `FlushInterval: -1`, and a test that reads a single chunk passes either way.

Run: `cd plugins/vibecheck && go test ./... -run TestPreviewStreamsThroughTheProxy -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add plugins/vibecheck/Sources/vibecheck/JPEGEncoder.swift \
        plugins/vibecheck/Sources/vibecheck/PreviewStream.swift \
        plugins/vibecheck/Tests/VibeCheckKitTests/JPEGEncoderTests.swift \
        plugins/vibecheck/e2e_test.go
git commit -m "feat(vibecheck): MJPEG camera preview served through the proxy"
git show --stat
```

---

## Task 15: The /api/* surface

`/api/*` is the real interface; the HTML is its first consumer. Keeping it complete and honest is what lets a TUI client exist later with no core change.

**Files:**
- Create: `plugins/vibecheck/Sources/vibecheck/API.swift`
- Modify: `plugins/vibecheck/Sources/vibecheck/main.swift`
- Test: `plugins/vibecheck/e2e_test.go` (extend)

**Interfaces:**
- Consumes: `DetectionEngine`, `ConfigStore`, `AlertPrefsStore`, `CountsStore`, `PreviewStream`, `VCRouter`.
- Produces: the routes below.

| Method | Path | Behavior |
|---|---|---|
| GET | `/api/state` | `EngineSnapshot` as JSON |
| GET | `/api/config` | current `VibeCheckConfig` |
| PUT | `/api/config` | validate, clamp, persist, apply live; 400 on malformed JSON |
| POST | `/api/config/disable` | sets `enabled: false`, stops the camera (alert action target) |
| POST | `/api/snooze` | `?minutes=N`, suppresses alerts until a deadline |
| GET | `/api/alert-prefs` | per-behavior preferences |
| PUT | `/api/alert-prefs` | persist |
| GET | `/api/events` | SSE: `frame` events with viewer-space landmarks, `detection` events |
| GET | `/preview.mjpeg` | Task 14 |
| GET | `/icons/<id>.svg` | the three bundled behavior icons |
| GET | `/health` | SDK default |

Error discipline, copied from `plugins/todo/main.go`'s comments because they encode real rules: **a caller's mistake gets a 400 with the message; anything else gets a logged server-side error and a generic 500.** Store errors can contain the store's absolute filesystem path, which is not the client's to see.

- [ ] **Step 1: Write the failing e2e tests**

```go
func TestConfigRejectsMalformedJSON(t *testing.T) {
	client, base, _ := liveKernel(t)
	req, _ := http.NewRequest("PUT", base+"/p/vibecheck/api/config",
		strings.NewReader("{not json"))
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("got %d, want 400", resp.StatusCode)
	}
}

func TestConfigClampsOutOfRangeValues(t *testing.T) {
	client, base, _ := liveKernel(t)
	body := `{"enabled":true,"sensitivity":5.0,"dwell":0.15,"cooldown":900,"enabledBehaviors":[]}`
	req, _ := http.NewRequest("PUT", base+"/p/vibecheck/api/config", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, _ := client.Do(req)
	resp.Body.Close()

	getResp, err := client.Get(base + "/p/vibecheck/api/config")
	if err != nil {
		t.Fatal(err)
	}
	defer getResp.Body.Close()
	var c struct {
		Sensitivity float64 `json:"sensitivity"`
		Cooldown    float64 `json:"cooldown"`
	}
	json.NewDecoder(getResp.Body).Decode(&c)
	if c.Sensitivity != 1.0 {
		t.Fatalf("sensitivity = %v, want clamped to 1.0", c.Sensitivity)
	}
	if c.Cooldown != 30 {
		t.Fatalf("cooldown = %v, want clamped to 30", c.Cooldown)
	}
}

func TestStateReportsPermissionAndConfig(t *testing.T) {
	client, base, _ := liveKernel(t)
	resp, err := client.Get(base + "/p/vibecheck/api/state")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var s struct {
		Running    bool   `json:"running"`
		Permission string `json:"permission"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&s); err != nil {
		t.Fatal(err)
	}
	if s.Permission == "" {
		t.Fatal("permission must always be reported so the UI can explain itself")
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd plugins/vibecheck && go test ./... -run 'TestConfig|TestState' -v`
Expected: FAIL — 404 or 200-with-wrong-shape.

- [ ] **Step 3: Implement API.swift and wire it into main.swift**

- [ ] **Step 4: Run to verify they pass**

Run: `cd plugins/vibecheck && go test ./... -v`
Expected: PASS, all tests.

- [ ] **Step 5: Commit**

```bash
git add plugins/vibecheck/Sources/vibecheck/API.swift \
        plugins/vibecheck/Sources/vibecheck/main.swift \
        plugins/vibecheck/e2e_test.go
git commit -m "feat(vibecheck): /api/* surface for state, config, prefs, and events"
git show --stat
```

---

## Task 16: The HTML UI

**Files:**
- Modify: `plugins/vibecheck/ui/index.html`

**Interfaces:**
- Consumes: `/api/state`, `/api/config`, `/api/events`, `/preview.mjpeg`, `/icons/*.svg`.
- Produces: nothing consumed by later tasks.

Constraints: **relative URLs only** (the plugin is mounted at `/p/vibecheck/` and must not know it), **no `localStorage`** (all plugins share one web origin), and `prefers-color-scheme` for dark mode.

The overlay must reproduce the aspect-**fill** mapping exactly. The `<img>` is `object-fit: cover`; using `contain` drifts the overlay off the face whenever pane aspect differs from frame aspect.

```js
// Aspect-FILL (cover) mapping, matching the camera preview's object-fit.
// Ported from DetectionOverlay.swift:24-34 with the y-flip REMOVED —
// landmarks now arrive in viewer space (y already down), so mapping is a
// direct scale. Re-flipping here would put everything upside down.
function mapPoint(p, w, h, imageSize) {
  const fa = imageSize.height > 0 ? imageSize.width / imageSize.height : 16 / 9;
  const viewAspect = w / h;
  const dispW = viewAspect > fa ? w : h * fa;
  const dispH = viewAspect > fa ? w / fa : h;
  const ox = (w - dispW) / 2;
  const oy = (h - dispH) / 2;
  return { x: ox + p.x * dispW, y: oy + p.y * dispH };
}
```

The canvas must be sized to the `<img>`'s **rendered** box (`clientWidth`/`clientHeight`), not its intrinsic size, and resized on `ResizeObserver`.

The hair mask is 64×48 = **3072 cells per frame**. Draw it into the `<canvas>`; 3072 SVG rects per frame will not hold frame rate.

Controls, whose ranges are the de-facto config schema: three behavior toggles, sensitivity slider `0…1`, alert-interval slider `1…30` seconds, an overlay toggle, and today's per-behavior counts. Every change PUTs `/api/config`.

- [ ] **Step 1: Write the page**

- [ ] **Step 2: Verify in the real client**

Run `just run` then `just swift-run`, open the VibeCheck tab, and confirm: the preview renders, the overlay tracks your face, a fingertip raised above your head lights the hair zone, and moving the sensitivity slider changes the trigger radius immediately.

**The overlay orientation check is the important one.** Touch your nose — the marker must land on your nose, not your forehead. If it is vertically inverted, the y-flip is applied twice; if horizontally, x is being mirrored somewhere it should not be.

- [ ] **Step 3: Commit**

```bash
git add plugins/vibecheck/ui/index.html
git commit -m "feat(vibecheck): preview, overlay, and controls UI"
git show --stat
```

---

## Task 17: Render alert action buttons in the Swift shell

The one client-side change that is a feature rather than a deletion. Without it, snooze and dismiss are unreachable and the plugin's alerts are strictly weaker than what VibeCheck does today.

**Files:**
- Modify: `clients/macos-swift/VibeCare/vibecare/Services/PluginShellService.swift:103-119`
- Test: `clients/macos-swift/VibeCare/vibecareTests/PluginRosterTests.swift` (extend)

**Interfaces:**
- Consumes: `PluginAlert`, `PluginAlertAction` (`Models/PluginRoster.swift:99-118`), `PluginRoster.url(for:path:)` (lines 74-79).
- Produces: rendered action buttons.

The groundwork already exists and is unused: `PluginAlertAction` is decoded, `url(for:path:)` builds the target URL, and nothing calls it. `deliver()` currently logs carried actions and drops them.

A button press is an HTTP GET to `/p/vibecheck/<url>` through the existing proxy — no new callback channel, no core change.

- [ ] **Step 1: Write the failing test**

```swift
@Test func actionURLResolvesAgainstThePluginBasePath() throws {
    let roster = PluginRoster(baseURL: "http://127.0.0.1:8080", token: "t0ken",
                              plugins: [.init(id: "vibecheck", name: "VibeCheck",
                                              icon: "eye", path: "/p/vibecheck/",
                                              state: .up, detail: "")])
    let url = try #require(roster.url(for: "vibecheck", path: "api/snooze?minutes=10"))
    #expect(url.absoluteString == "http://127.0.0.1:8080/p/vibecheck/api/snooze?minutes=10")
}

@Test func anActionForAnUnknownPluginResolvesToNil() {
    let roster = PluginRoster(baseURL: "http://127.0.0.1:8080", token: "t0ken", plugins: [])
    #expect(roster.url(for: "ghost", path: "api/x") == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `just swift-test`
Expected: FAIL if `url(for:path:)` does not already handle these cases; if it passes immediately, verify by breaking it temporarily.

- [ ] **Step 3: Implement rendering in `deliver()`**

Replace the logging branch with real buttons. Each button's action issues the GET with the session cookie and dismisses the notification. Keep the existing `level` switch — only `"info"` and `"warn"` exist, and everything else falls through to info.

Errors from the GET must be logged, never surfaced as a second notification — a failed snooze producing an error banner is worse than a silent one.

- [ ] **Step 4: Run to verify it passes**

Run: `just swift-test`
Expected: PASS.

- [ ] **Step 5: Verify by hand**

Trigger a detection, confirm the banner shows **Snooze 10 min** and **Turn off**, press each, and confirm the plugin's behavior changes.

- [ ] **Step 6: Commit**

```bash
git add clients/macos-swift/VibeCare/vibecare/Services/PluginShellService.swift \
        clients/macos-swift/VibeCare/vibecareTests/PluginRosterTests.swift
git commit -m "feat(client): render plugin alert action buttons"
git show --stat
```

---

## Task 18: Delete the client's detection stack

**Do this only when the plugin has reached parity.** One commit, the way v1 was removed.

**Files:**
- Delete: `clients/macos-swift/VibeCare/vibecare/Services/Detection/` (7 files)
- Delete: `clients/macos-swift/VibeCare/vibecare/ViewModels/VibeCheckViewModel.swift`
- Delete: `clients/macos-swift/VibeCare/vibecare/Views/VibeCheck/` (5 files)
- Delete: `clients/macos-swift/VibeCare/vibecare/Models/BFRB.swift`
- Delete: `clients/macos-swift/VibeCare/vibecareTests/{BFRBDetector,DetectionPolicy,DetectionPreference,DetectionAlertPreferencesStore,VibeCheckViewModel}Tests.swift`
- Modify: `Views/Dashboard/Dashboard.swift`, `Views/Dashboard/Sidebar.swift`, `Views/Dashboard/DashboardState.swift`, `App.swift`, `Views/PlaceholderViews.swift`, `Services/VibeNotifyConfiguration.swift`, `vibecareTests/BFRBBehaviorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a client with no per-plugin Swift.

- [ ] **Step 1: Remove the sidebar case first and let the compiler find the rest**

Delete `case vibecheck = "VibeCheck"` at `Sidebar.swift:8`. `Dashboard.swift:99` and `:197` switch exhaustively over `SidebarItem?` and will fail to compile, as will `DashboardState.swift:29-30`.

Run: `just swift-build`
Expected: compile errors at exactly those sites. Fix each by deleting the case.

- [ ] **Step 2: Remove the remaining Sidebar sites**

`Sidebar.swift:19` (`iconName`), `:30` (`color`), `:79-80` (`getItemCount`).

- [ ] **Step 3: Remove the Dashboard sites**

`Dashboard.swift:11` (`@StateObject`), `:135-137` (`vibeCheckContentView`), `:156-163` (the always-visible detection toggle in `toolbarButtons`).

- [ ] **Step 4: Remove the sites the handoff omitted**

- `DashboardState.swift:9` — `selectedVibeCheck`, a dead field never read anywhere
- `App.swift:38-39` — the auto-resume call
- `PlaceholderViews.swift:178` and `:244-246` — the menu-bar row
- `VibeNotifyConfiguration.swift:253-311` — `showBFRBAlert` and `ordinal`. `ordinal` is used **only** by `showBFRBAlert`, so both go; `Ordinal.format` in the plugin replaces it.
- `vibecareTests/BFRBBehaviorTests.swift:21-35` — `ordinalSuffixesFollowEnglishRules`, which tests only `VibeNotifyConfig.ordinal`. Those 13 assertions already moved to the plugin in Task 10.

- [ ] **Step 5: Delete the files**

```bash
git rm -r clients/macos-swift/VibeCare/vibecare/Services/Detection \
          clients/macos-swift/VibeCare/vibecare/Views/VibeCheck
git rm clients/macos-swift/VibeCare/vibecare/ViewModels/VibeCheckViewModel.swift \
       clients/macos-swift/VibeCare/vibecare/Models/BFRB.swift \
       clients/macos-swift/VibeCare/vibecareTests/BFRBDetectorTests.swift \
       clients/macos-swift/VibeCare/vibecareTests/DetectionPolicyTests.swift \
       clients/macos-swift/VibeCare/vibecareTests/DetectionPreferenceTests.swift \
       clients/macos-swift/VibeCare/vibecareTests/DetectionAlertPreferencesStoreTests.swift \
       clients/macos-swift/VibeCare/vibecareTests/VibeCheckViewModelTests.swift
```

**Do not delete** `Models/NotificationPreferences.swift` or `Views/Schedules/NotificationCustomizationView.swift`. Both are shared with the schedule-notification feature, which stays in the client.

- [ ] **Step 6: Verify nothing references the deleted symbols**

```bash
grep -rn 'VibeCheckViewModel\|BFRBBehavior\|BFRBDetector\|DetectionPolicy\|CameraSession\|VisionLandmarkExtractor\|showBFRBAlert' \
  clients/macos-swift/VibeCare/vibecare clients/macos-swift/VibeCare/vibecareTests
```

Expected: no output.

- [ ] **Step 7: Build and test both sides**

Run: `just swift-build && just swift-test`
Expected: clean build, tests pass.

Run: `just test`
Expected: backend and plugin tests pass.

- [ ] **Step 8: Confirm the app end to end**

Run `just run` then `just swift-run`. The VibeCheck tab is now served entirely by the plugin. Confirm detection still fires and the alert still appears — with working action buttons.

- [ ] **Step 9: Commit**

```bash
git add -A clients/macos-swift/VibeCare
git commit -m "refactor(client): remove the in-app detection stack, now a plugin"
git show --stat
```

Verify the stat lists only client paths.

---

## Verification checklist

Before calling this done, run each and confirm the output rather than assuming it:

```bash
just build-plugins                              # both plugins build
cd plugins/vibecheck && swift test              # SDK + kit unit tests
cd plugins/vibecheck && go test ./...           # live-kernel e2e
just test                                       # backend, incl. TestKernelContainsNoProductNouns
just swift-build && just swift-test             # client still builds and passes
git status --porcelain                          # no unintended files
```

Then the manual checks that no test covers:

- The VibeCheck tab renders in the real client (the webview path has never been visually confirmed in this codebase).
- The camera prompt appears on first run, and Privacy → Camera lists the server binary.
- The overlay marker lands on your nose when you touch your nose — not your forehead, not mirrored.
- Detection fires, the banner shows both action buttons, and both work.
- Killing the plugin (`pkill vibecheck`) shows it restart and return to `up` on `/_core/status`, without landing in `failed`.
