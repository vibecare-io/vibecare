# System Power Actions (Sleep / Lock) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the VibeCare macOS client actually execute `system_command` actions — starting with locking the screen and putting the Mac to sleep on a schedule, with a 30-second cancelable full-screen countdown — while keeping the mechanism cross-platform-ready.

**Architecture:** Actions execute client-side (the Go backend is a pure scheduler/dispatcher and is not touched for execution). A new `SystemCommandHandler` in the Swift client parses a platform-neutral command vocabulary from the action's `parameters` map and runs native shell invocations through an injectable `CommandRunner` seam (so pure logic is unit-testable without sleeping the machine). A borderless full-screen `NSWindow` overlay drives the cancelable countdown before `sleep`. The nightly wind-down flow ships as a seeded JSON template.

**Tech Stack:** Swift 6 / SwiftUI (macOS 15+), swift-testing (`import Testing`), `Foundation.Process`, AppKit `NSWindow`; Go backend (unchanged for logic — JSON template data only); Just command runner.

## Global Constraints

- **Backend:** no proto changes, no DB migration, no Go execution logic. The only backend change in this plan is adding one entry to a JSON data file (Task M2).
- **Target platform:** macOS 15+. The app is **not** sandboxed (`vibecare.entitlements` has no `com.apple.security.app-sandbox`), Hardened Runtime is on — `Process` subprocess execution is allowed. Do not add the App Sandbox entitlement.
- **Command vocabulary (verbatim):** `parameters["command"]` ∈ `lock`, `sleep`, `display_sleep`, `logout`, `shutdown`, `restart`. Only `lock` and `sleep` are implemented in this plan; the others parse but are treated as unimplemented (log + no-op, never crash). `countdown_seconds` (integer string, default `0` = immediate), `cancelable` (`"true"`/`"false"`, default `true`), `message` (optional overlay text).
- **The 22:59 step is a single `sleep` action.** `sleep` expands to lock-then-sleep so the machine is at the login window on wake regardless of the user's "require password after sleep" setting.
- **Xcode target membership:** new Swift source files under `vibecare/` must be added to the `vibecare` app target; new test files to the `vibecareTests` target. `swift build` (SPM) auto-discovers files, but `xcodebuild`/Xcode do not — register new files in `vibecare.xcodeproj/project.pbxproj` (creating the file inside Xcode does this automatically). Commit the `project.pbxproj` change with the file.
- **Build check (fast):** `just swift-build` (runs `swift build` in `clients/macos-swift/VibeCare`).
- **Test run:** `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests` (swift-testing runs under XCTest host).
- **TDD scope:** unit-test the pure logic (parameter parsing, command→invocation sequencing, countdown controller state machine) using a mock `CommandRunner`. Verify the real system calls and the overlay UI with the documented manual steps — never let an automated test actually run `pmset sleepnow`.
- **Commit cadence:** commit after each task's tests pass (or after manual verification for UI/system tasks). Work on a dedicated branch off `main`, not on `release`.

---

## File Structure

| File | Responsibility |
|---|---|
| `clients/macos-swift/VibeCare/vibecare/Services/CommandRunner.swift` | **New.** `CommandRunner` protocol, `ProcessCommandRunner` (real `Process`), `CommandError`. The side-effecting seam. |
| `clients/macos-swift/VibeCare/vibecare/Services/SystemCommandHandler.swift` | **New.** `SystemCommandType`, `SystemCommandRequest` (parse), invocation-sequencing, and `SystemCommandHandler` (`@MainActor` singleton, mirrors `LinkHandler`). |
| `clients/macos-swift/VibeCare/vibecare/Views/Overlay/SleepCountdownController.swift` | **New (M1).** Testable countdown state machine (tick / cancel / complete). |
| `clients/macos-swift/VibeCare/vibecare/Views/Overlay/SleepCountdownOverlay.swift` | **New (M1).** Full-screen `NSWindow` + SwiftUI overlay view driven by the controller. |
| `clients/macos-swift/VibeCare/vibecare/Services/EventService.swift` | **Modify** `.systemCommand` case (`:249`) to dispatch to `SystemCommandHandler`. |
| `clients/macos-swift/VibeCare/vibecareTests/SystemCommandTests.swift` | **New.** Unit tests for parsing, sequencing, and countdown controller. |
| `backend/internal/storage/data/schedule_templates.json` | **Modify (M2).** Add the three "Wind Down" template entries. |
| `clients/macos-swift/VibeCare/vibecare/Resources/TemplateConfigs.json` | **Modify (M2).** Mirror the wind-down entries for the client. |
| `docs/cross-platform-system-commands.md` | **New (M3).** The command→native mapping reference. |

---

## Milestone M0 — Wire up lock & sleep (immediate, no overlay)

### Task M0.1: `CommandRunner` seam

**Files:**
- Create: `clients/macos-swift/VibeCare/vibecare/Services/CommandRunner.swift`
- Test: `clients/macos-swift/VibeCare/vibecareTests/SystemCommandTests.swift`

**Interfaces:**
- Produces: `protocol CommandRunner { func run(executable: String, arguments: [String]) throws }`; `struct ProcessCommandRunner: CommandRunner`; `enum CommandError: Error, Equatable { case nonZeroExit(status: Int32, stderr: String); case launchFailed(String) }`; and a test helper `final class MockCommandRunner: CommandRunner` recording calls.

- [ ] **Step 1: Write the failing test** (create `vibecareTests/SystemCommandTests.swift`; add the file to the `vibecareTests` target in Xcode / pbxproj)

```swift
import Testing
@testable import vibecare

// A recording mock so tests never touch the real system.
final class MockCommandRunner: CommandRunner {
    struct Call: Equatable { let executable: String; let arguments: [String] }
    private(set) var calls: [Call] = []
    var errorToThrow: Error?
    func run(executable: String, arguments: [String]) throws {
        calls.append(Call(executable: executable, arguments: arguments))
        if let e = errorToThrow { throw e }
    }
}

@Test func mockRunnerRecordsCalls() throws {
    let runner = MockCommandRunner()
    try runner.run(executable: "/usr/bin/pmset", arguments: ["sleepnow"])
    #expect(runner.calls == [.init(executable: "/usr/bin/pmset", arguments: ["sleepnow"])])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: FAIL to compile — `CommandRunner` / `MockCommandRunner` unknown.

- [ ] **Step 3: Write minimal implementation** (`CommandRunner.swift`)

```swift
import Foundation

/// Side-effecting seam for launching external commands. Injected so the
/// pure command logic can be unit-tested without touching the real system.
protocol CommandRunner {
    func run(executable: String, arguments: [String]) throws
}

enum CommandError: Error, Equatable {
    case nonZeroExit(status: Int32, stderr: String)
    case launchFailed(String)
}

/// Real runner: launches `executable`, waits, throws on non-zero exit.
struct ProcessCommandRunner: CommandRunner {
    func run(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw CommandError.nonZeroExit(status: process.terminationStatus, stderr: stderr)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: PASS (`mockRunnerRecordsCalls`).

- [ ] **Step 5: Commit**

```bash
git add clients/macos-swift/VibeCare/vibecare/Services/CommandRunner.swift \
        clients/macos-swift/VibeCare/vibecareTests/SystemCommandTests.swift \
        clients/macos-swift/VibeCare/vibecare.xcodeproj/project.pbxproj
git commit -m "feat(client): add CommandRunner seam for system commands"
```

---

### Task M0.2: Parse `SystemCommandRequest` from action parameters

**Files:**
- Create: `clients/macos-swift/VibeCare/vibecare/Services/SystemCommandHandler.swift`
- Test: `clients/macos-swift/VibeCare/vibecareTests/SystemCommandTests.swift` (append)

**Interfaces:**
- Consumes: `Action` (`Models/Action.swift`), which has `parameters: [String: String]`.
- Produces: `enum SystemCommandType: String { case lock; case sleep; case displaySleep = "display_sleep"; case logout; case shutdown; case restart }`; `struct SystemCommandRequest: Equatable { let type: SystemCommandType; let countdownSeconds: Int; let cancelable: Bool; let message: String? ; static func parse(from parameters: [String: String]) -> SystemCommandRequest? }`.

- [ ] **Step 1: Write the failing test** (append to `SystemCommandTests.swift`)

```swift
@Test func parsesFullSleepRequest() {
    let req = SystemCommandRequest.parse(from: [
        "command": "sleep", "countdown_seconds": "30",
        "cancelable": "true", "message": "Time to wind down"
    ])
    #expect(req == SystemCommandRequest(type: .sleep, countdownSeconds: 30,
                                        cancelable: true, message: "Time to wind down"))
}

@Test func parseDefaultsCountdownZeroAndCancelableTrue() {
    let req = SystemCommandRequest.parse(from: ["command": "lock"])
    #expect(req == SystemCommandRequest(type: .lock, countdownSeconds: 0,
                                        cancelable: true, message: nil))
}

@Test func parseReturnsNilForMissingCommand() {
    #expect(SystemCommandRequest.parse(from: ["countdown_seconds": "30"]) == nil)
}

@Test func parseReturnsNilForUnknownCommand() {
    #expect(SystemCommandRequest.parse(from: ["command": "frobnicate"]) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: FAIL to compile — `SystemCommandRequest` unknown.

- [ ] **Step 3: Write minimal implementation** (`SystemCommandHandler.swift`)

```swift
import Foundation
import Logging

/// Platform-neutral system command vocabulary. Each platform client maps the
/// same case to its own native invocation (see docs/cross-platform-system-commands.md).
enum SystemCommandType: String {
    case lock
    case sleep
    case displaySleep = "display_sleep"
    case logout
    case shutdown
    case restart
}

struct SystemCommandRequest: Equatable {
    let type: SystemCommandType
    let countdownSeconds: Int
    let cancelable: Bool
    let message: String?

    /// Parse from an Action's parameters map. Returns nil if `command` is
    /// missing or not a known vocabulary term.
    static func parse(from parameters: [String: String]) -> SystemCommandRequest? {
        guard let raw = parameters["command"],
              let type = SystemCommandType(rawValue: raw) else {
            return nil
        }
        let countdown = parameters["countdown_seconds"].flatMap { Int($0) } ?? 0
        let cancelable = (parameters["cancelable"] ?? "true").lowercased() != "false"
        let message = parameters["message"]?.isEmpty == false ? parameters["message"] : nil
        return SystemCommandRequest(type: type,
                                    countdownSeconds: max(0, countdown),
                                    cancelable: cancelable,
                                    message: message)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: PASS (4 new tests).

- [ ] **Step 5: Commit**

```bash
git add clients/macos-swift/VibeCare/vibecare/Services/SystemCommandHandler.swift \
        clients/macos-swift/VibeCare/vibecareTests/SystemCommandTests.swift \
        clients/macos-swift/VibeCare/vibecare.xcodeproj/project.pbxproj
git commit -m "feat(client): parse system command parameters"
```

---

### Task M0.3: Command → native invocation sequencing

**Files:**
- Modify: `clients/macos-swift/VibeCare/vibecare/Services/SystemCommandHandler.swift`
- Test: `clients/macos-swift/VibeCare/vibecareTests/SystemCommandTests.swift` (append)

**Interfaces:**
- Produces: `static func invocations(for type: SystemCommandType) -> [(executable: String, arguments: [String])]` on `SystemCommandHandler`. `lock` → CGSession suspend; `sleep` → lock-then-`pmset sleepnow`; every unimplemented type → `[]`.

- [ ] **Step 1: Write the failing test** (append)

```swift
private let cgSession = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"

@MainActor @Test func lockInvocationIsCGSessionSuspend() {
    let inv = SystemCommandHandler.invocations(for: .lock)
    #expect(inv.count == 1)
    #expect(inv[0].executable == cgSession)
    #expect(inv[0].arguments == ["-suspend"])
}

@MainActor @Test func sleepLocksThenSleeps() {
    let inv = SystemCommandHandler.invocations(for: .sleep)
    #expect(inv.count == 2)
    #expect(inv[0].executable == cgSession)          // lock first
    #expect(inv[0].arguments == ["-suspend"])
    #expect(inv[1].executable == "/usr/bin/pmset")   // then sleep
    #expect(inv[1].arguments == ["sleepnow"])
}

@MainActor @Test func unimplementedCommandsHaveNoInvocations() {
    #expect(SystemCommandHandler.invocations(for: .shutdown).isEmpty)
    #expect(SystemCommandHandler.invocations(for: .restart).isEmpty)
    #expect(SystemCommandHandler.invocations(for: .logout).isEmpty)
    #expect(SystemCommandHandler.invocations(for: .displaySleep).isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: FAIL to compile — `invocations(for:)` unknown.

- [ ] **Step 3: Write minimal implementation** (append to `SystemCommandHandler.swift`, before/after the struct — add the class)

```swift
@MainActor
final class SystemCommandHandler {
    static let shared = SystemCommandHandler()

    private static let cgSession =
        "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
    private static let pmset = "/usr/bin/pmset"

    private let runner: CommandRunner
    private let logger = Logger(label: "com.vibecare.system-command")

    init(runner: CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    /// The ordered native invocations for a command type on macOS.
    /// Unimplemented commands return [] (logged + no-op by the caller).
    static func invocations(
        for type: SystemCommandType
    ) -> [(executable: String, arguments: [String])] {
        let lock = (executable: cgSession, arguments: ["-suspend"])
        switch type {
        case .lock:
            return [lock]
        case .sleep:
            return [lock, (executable: pmset, arguments: ["sleepnow"])]
        case .displaySleep, .logout, .shutdown, .restart:
            return []   // not implemented in this milestone
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add clients/macos-swift/VibeCare/vibecare/Services/SystemCommandHandler.swift \
        clients/macos-swift/VibeCare/vibecareTests/SystemCommandTests.swift
git commit -m "feat(client): map system commands to macOS invocations"
```

---

### Task M0.4: `executeAction` runs immediate commands via the runner

**Files:**
- Modify: `clients/macos-swift/VibeCare/vibecare/Services/SystemCommandHandler.swift`
- Test: `clients/macos-swift/VibeCare/vibecareTests/SystemCommandTests.swift` (append)

**Interfaces:**
- Produces: `func executeAction(_ action: Action)` on `SystemCommandHandler`. For `countdownSeconds == 0` it runs the invocations immediately in order through the injected `CommandRunner`. Also `func runInvocations(for type: SystemCommandType)` (internal) reused by the overlay in M1.

- [ ] **Step 1: Write the failing test** (append)

```swift
@MainActor @Test func executeSleepImmediatelyRunsLockThenSleep() {
    let runner = MockCommandRunner()
    let handler = SystemCommandHandler(runner: runner)
    let action = Action(profileId: "p", type: .systemCommand, name: "Sleep",
                        parameters: ["command": "sleep", "countdown_seconds": "0"])
    handler.executeAction(action)
    #expect(runner.calls.map { $0.arguments } == [["-suspend"], ["sleepnow"]])
}

@MainActor @Test func executeUnknownCommandRunsNothing() {
    let runner = MockCommandRunner()
    let handler = SystemCommandHandler(runner: runner)
    let action = Action(profileId: "p", type: .systemCommand, name: "Bad",
                        parameters: ["command": "frobnicate"])
    handler.executeAction(action)
    #expect(runner.calls.isEmpty)
}

@MainActor @Test func executeWrongActionTypeRunsNothing() {
    let runner = MockCommandRunner()
    let handler = SystemCommandHandler(runner: runner)
    let action = Action(profileId: "p", type: .notification, name: "N",
                        parameters: ["command": "sleep"])
    handler.executeAction(action)
    #expect(runner.calls.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: FAIL to compile — `executeAction` unknown.

- [ ] **Step 3: Write minimal implementation** (add methods to `SystemCommandHandler`)

```swift
    /// Entry point called by EventService for `.systemCommand` actions.
    /// M0: only immediate (countdown == 0) execution. Countdown handling is
    /// wired in M1.
    func executeAction(_ action: Action) {
        guard action.type == .systemCommand else {
            logger.error("Invalid action type for SystemCommandHandler: \(action.type)")
            return
        }
        guard let request = SystemCommandRequest.parse(from: action.parameters) else {
            logger.error("Unrecognized system command in action \(action.id): \(action.parameters)")
            return
        }
        // M1 replaces this branch with the countdown overlay when > 0.
        runInvocations(for: request.type)
    }

    /// Run the ordered invocations for a command type, stopping on the first error.
    func runInvocations(for type: SystemCommandType) {
        let invocations = Self.invocations(for: type)
        if invocations.isEmpty {
            logger.warning("System command '\(type.rawValue)' not implemented on macOS yet")
            return
        }
        for inv in invocations {
            do {
                try runner.run(executable: inv.executable, arguments: inv.arguments)
                logger.info("Ran system command: \(inv.executable) \(inv.arguments.joined(separator: " "))")
            } catch {
                logger.error("System command failed: \(inv.executable) — \(error)")
                return   // stop the sequence; surfaced to the user in M0.5/M1
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add clients/macos-swift/VibeCare/vibecare/Services/SystemCommandHandler.swift \
        clients/macos-swift/VibeCare/vibecareTests/SystemCommandTests.swift
git commit -m "feat(client): execute immediate system commands"
```

---

### Task M0.5: Wire `.systemCommand` into EventService

**Files:**
- Modify: `clients/macos-swift/VibeCare/vibecare/Services/EventService.swift:249-251`

**Interfaces:**
- Consumes: `SystemCommandHandler.shared.executeAction(_:)`.

- [ ] **Step 1: Replace the TODO branch** (`EventService.swift`, the `.systemCommand` case at ~`:249`)

```swift
        case .systemCommand:
            SystemCommandHandler.shared.executeAction(action)
```

- [ ] **Step 2: Build to verify it compiles**

Run: `just swift-build 2>&1 | tail -20`
Expected: build succeeds (no `system_command action not yet implemented` warning remains).

- [ ] **Step 3: Manual end-to-end verification of `lock`** (do NOT automate — this locks your screen)

1. Start backend: `just run`. Run the app: `just swift-run`.
2. In the app, create a routine + a schedule ~1–2 minutes out, and attach a `System Command` action with `parameters` `{"command":"lock"}` (via the app UI's Add Action → System Command, or seed it through the MCP/`ActionService`).
3. Wait for the schedule to fire.
4. **Expected:** the screen locks to the login window. Log in again.
5. Confirm the app log shows `Ran system command: …/CGSession -suspend`.

- [ ] **Step 4: Commit**

```bash
git add clients/macos-swift/VibeCare/vibecare/Services/EventService.swift
git commit -m "feat(client): dispatch system_command actions to handler"
```

---

## Milestone M1 — Cancelable countdown overlay for `sleep`

### Task M1.1: `SleepCountdownController` state machine

**Files:**
- Create: `clients/macos-swift/VibeCare/vibecare/Views/Overlay/SleepCountdownController.swift`
- Test: `clients/macos-swift/VibeCare/vibecareTests/SystemCommandTests.swift` (append)

**Interfaces:**
- Produces: `@MainActor final class SleepCountdownController: ObservableObject` with `@Published private(set) var remaining: Int`, `let cancelable: Bool`, `init(seconds: Int, cancelable: Bool, onComplete: @escaping () -> Void, onCancel: @escaping () -> Void)`, `func tick()` (decrement; fire `onComplete` exactly once at 0), `func cancel()` (fire `onCancel` at most once, only if `cancelable` and not finished). Callbacks fire at most once total across the object's life.

- [ ] **Step 1: Write the failing test** (append)

```swift
@MainActor @Test func countdownCompletesAfterTicks() {
    var completed = 0, canceled = 0
    let c = SleepCountdownController(seconds: 2, cancelable: true,
                                    onComplete: { completed += 1 },
                                    onCancel: { canceled += 1 })
    #expect(c.remaining == 2)
    c.tick(); #expect(c.remaining == 1)
    c.tick(); #expect(c.remaining == 0)
    #expect(completed == 1 && canceled == 0)
    c.tick()   // extra ticks must not re-fire
    #expect(completed == 1)
}

@MainActor @Test func countdownCancelFiresOnceAndBlocksCompletion() {
    var completed = 0, canceled = 0
    let c = SleepCountdownController(seconds: 3, cancelable: true,
                                    onComplete: { completed += 1 },
                                    onCancel: { canceled += 1 })
    c.cancel(); c.cancel()
    #expect(canceled == 1 && completed == 0)
    c.tick(); c.tick(); c.tick()
    #expect(completed == 0)   // canceled: no completion
}

@MainActor @Test func nonCancelableIgnoresCancel() {
    var canceled = 0
    let c = SleepCountdownController(seconds: 2, cancelable: false,
                                    onComplete: {}, onCancel: { canceled += 1 })
    c.cancel()
    #expect(canceled == 0)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: FAIL to compile — `SleepCountdownController` unknown.

- [ ] **Step 3: Write minimal implementation** (`SleepCountdownController.swift`; add file to both app & test-visible target)

```swift
import Foundation

@MainActor
final class SleepCountdownController: ObservableObject {
    @Published private(set) var remaining: Int
    let cancelable: Bool

    private let onComplete: () -> Void
    private let onCancel: () -> Void
    private var finished = false   // true once completed or canceled

    init(seconds: Int, cancelable: Bool,
         onComplete: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.remaining = max(0, seconds)
        self.cancelable = cancelable
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    func tick() {
        guard !finished else { return }
        if remaining > 0 { remaining -= 1 }
        if remaining == 0 {
            finished = true
            onComplete()
        }
    }

    func cancel() {
        guard !finished, cancelable else { return }
        finished = true
        onCancel()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add clients/macos-swift/VibeCare/vibecare/Views/Overlay/SleepCountdownController.swift \
        clients/macos-swift/VibeCare/vibecareTests/SystemCommandTests.swift \
        clients/macos-swift/VibeCare/vibecare.xcodeproj/project.pbxproj
git commit -m "feat(client): add sleep countdown state machine"
```

---

### Task M1.2: Full-screen overlay window + view

**Files:**
- Create: `clients/macos-swift/VibeCare/vibecare/Views/Overlay/SleepCountdownOverlay.swift`

**Interfaces:**
- Consumes: `SleepCountdownController`.
- Produces: `@MainActor final class SleepCountdownOverlay` with `static let shared` and `func present(seconds: Int, cancelable: Bool, message: String?, onComplete: @escaping () -> Void)`. Owns the `NSWindow`(s), a 1s `Timer` calling `controller.tick()`, an `Esc`/button handler calling `controller.cancel()`, and tears down the window on complete/cancel. Dedupe: a second `present` while one is showing is ignored.

- [ ] **Step 1: Write the implementation** (UI — verified manually, not unit-tested)

```swift
import AppKit
import SwiftUI
import Logging

@MainActor
final class SleepCountdownOverlay {
    static let shared = SleepCountdownOverlay()
    private let logger = Logger(label: "com.vibecare.sleep-overlay")

    private var window: NSWindow?
    private var controller: SleepCountdownController?
    private var timer: Timer?

    /// Show the countdown. `onComplete` runs when it reaches zero (not on cancel).
    func present(seconds: Int, cancelable: Bool, message: String?,
                 onComplete: @escaping () -> Void) {
        guard window == nil else {
            logger.warning("Countdown already showing; ignoring duplicate present")
            return
        }
        let controller = SleepCountdownController(
            seconds: seconds, cancelable: cancelable,
            onComplete: { [weak self] in self?.dismiss(); onComplete() },
            onCancel:   { [weak self] in self?.dismiss() })
        self.controller = controller

        let screenFrame = NSScreen.main?.frame ?? .zero
        let window = NSWindow(contentRect: screenFrame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(
            rootView: SleepCountdownView(controller: controller, message: message,
                                         onCancel: { controller.cancel() }))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in controller.tick() }
        }
    }

    private func dismiss() {
        timer?.invalidate(); timer = nil
        window?.orderOut(nil); window = nil
        controller = nil
    }
}

private struct SleepCountdownView: View {
    @ObservedObject var controller: SleepCountdownController
    let message: String?
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 24) {
                Text("🌙 \(message ?? "Time to wind down")")
                    .font(.system(size: 34, weight: .semibold))
                Text("Sleeping in \(controller.remaining)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if controller.cancelable {
                    Text("press Esc to stay awake")
                        .font(.title3).foregroundStyle(.secondary)
                    Button("Stay awake", action: onCancel)
                        .keyboardShortcut(.cancelAction)   // Esc
                        .controlSize(.large)
                }
            }
            .foregroundStyle(.white)
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `just swift-build 2>&1 | tail -20`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add clients/macos-swift/VibeCare/vibecare/Views/Overlay/SleepCountdownOverlay.swift \
        clients/macos-swift/VibeCare/vibecare.xcodeproj/project.pbxproj
git commit -m "feat(client): full-screen sleep countdown overlay"
```

---

### Task M1.3: Route `sleep` with a countdown through the overlay

**Files:**
- Modify: `clients/macos-swift/VibeCare/vibecare/Services/SystemCommandHandler.swift` (`executeAction`)
- Test: `clients/macos-swift/VibeCare/vibecareTests/SystemCommandTests.swift` (append)

**Interfaces:**
- Produces: updated `executeAction` — when `request.countdownSeconds > 0` it presents `SleepCountdownOverlay.shared` and runs invocations on completion; when `0` it runs immediately (unchanged M0 path). Because the overlay is UI, the branch decision is made testable via an injectable presenter closure defaulting to the real overlay.

- [ ] **Step 1: Write the failing test** (append) — verifies routing, not the UI

```swift
@MainActor @Test func countdownZeroRunsImmediatelyNoOverlay() {
    let runner = MockCommandRunner()
    var presented = false
    let handler = SystemCommandHandler(runner: runner,
        presentCountdown: { _, _, _, _ in presented = true })
    handler.executeAction(Action(profileId: "p", type: .systemCommand, name: "S",
        parameters: ["command": "sleep", "countdown_seconds": "0"]))
    #expect(presented == false)
    #expect(runner.calls.count == 2)   // ran immediately
}

@MainActor @Test func countdownPositivePresentsOverlayAndDefersRun() {
    let runner = MockCommandRunner()
    var captured: (() -> Void)?
    let handler = SystemCommandHandler(runner: runner,
        presentCountdown: { _, _, _, onComplete in captured = onComplete })
    handler.executeAction(Action(profileId: "p", type: .systemCommand, name: "S",
        parameters: ["command": "sleep", "countdown_seconds": "30"]))
    #expect(runner.calls.isEmpty)      // deferred until countdown completes
    captured?()                        // simulate countdown finishing
    #expect(runner.calls.map { $0.arguments } == [["-suspend"], ["sleepnow"]])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: FAIL to compile — `presentCountdown:` initializer parameter unknown.

- [ ] **Step 3: Update `SystemCommandHandler`** — add the presenter seam and countdown branch

```swift
    typealias CountdownPresenter =
        (_ seconds: Int, _ cancelable: Bool, _ message: String?, _ onComplete: @escaping () -> Void) -> Void

    private let presentCountdown: CountdownPresenter

    init(runner: CommandRunner = ProcessCommandRunner(),
         presentCountdown: @escaping CountdownPresenter = { s, c, m, done in
             SleepCountdownOverlay.shared.present(seconds: s, cancelable: c, message: m, onComplete: done)
         }) {
        self.runner = runner
        self.presentCountdown = presentCountdown
    }
```

Replace the body of `executeAction` after parsing with:

```swift
        if request.countdownSeconds > 0 {
            presentCountdown(request.countdownSeconds, request.cancelable, request.message) {
                [weak self] in self?.runInvocations(for: request.type)
            }
        } else {
            runInvocations(for: request.type)
        }
```

(Remove the old unconditional `runInvocations(for:)` call. Keep the two `guard`s.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd clients/macos-swift/VibeCare && xcodebuild test -project vibecare.xcodeproj -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | tail -20`
Expected: PASS (all system-command tests, including M0.4's still-valid immediate tests).

- [ ] **Step 5: Manual end-to-end verification of `sleep` + countdown** (do NOT automate)

1. `just run` (backend) and `just swift-run` (app).
2. Create a schedule ~1–2 min out with a `System Command` action `{"command":"sleep","countdown_seconds":"30","cancelable":"true","message":"Time to wind down"}`.
3. When it fires: **expected** the full-screen dim overlay appears counting down from 30.
4. **Test cancel:** press `Esc` → overlay disappears, machine stays awake, log shows a cancellation. Nothing runs.
5. **Test completion:** trigger again, let it reach 0 → machine locks then sleeps. Wake it → you're at the login window.

- [ ] **Step 6: Commit**

```bash
git add clients/macos-swift/VibeCare/vibecare/Services/SystemCommandHandler.swift \
        clients/macos-swift/VibeCare/vibecareTests/SystemCommandTests.swift
git commit -m "feat(client): show cancelable countdown before sleep"
```

---

## Milestone M2 — Seed the "Wind Down" template

### Task M2.1: Add wind-down entries to the template data

**Files:**
- Modify: `backend/internal/storage/data/schedule_templates.json`
- Modify: `clients/macos-swift/VibeCare/vibecare/Resources/TemplateConfigs.json`

**Interfaces:**
- Consumes: existing template JSON schema — each entry has `id`, `category`, `routine_name`, `routine_description`, `routine_icon`, `routine_color`, `schedule_name`, `schedule_description`, `rrule`, `default_times`, `actions[]` (each `{ type, name, parameters }`).

- [ ] **Step 1: Add three entries** (append to the `templates` array in `backend/internal/storage/data/schedule_templates.json`; use the same field shape as the existing `walk-pets` entry)

```json
{
  "id": "wind-down-rest",
  "category": "daily",
  "routine_name": "Wind Down",
  "routine_description": "Evening routine to rest, wrap up, and sleep",
  "routine_icon": "moon.fill",
  "routine_color": "indigo",
  "schedule_name": "Take a Rest",
  "schedule_description": "Nudge to step away and rest",
  "rrule": "FREQ=DAILY;BYHOUR=22;BYMINUTE=30",
  "default_times": ["22:30"],
  "actions": [
    { "type": "notification", "name": "Rest Nudge",
      "parameters": { "title": "Time to wind down", "body": "Take a rest — the day is wrapping up.", "position": "center", "auto_dismiss": "20" } }
  ]
},
{
  "id": "wind-down-wrap-up",
  "category": "daily",
  "routine_name": "Wind Down",
  "routine_description": "Evening routine to rest, wrap up, and sleep",
  "routine_icon": "moon.fill",
  "routine_color": "indigo",
  "schedule_name": "Wrap Up",
  "schedule_description": "15-minute warning before sleep",
  "rrule": "FREQ=DAILY;BYHOUR=22;BYMINUTE=45",
  "default_times": ["22:45"],
  "actions": [
    { "type": "notification", "name": "Wrap-Up Warning",
      "parameters": { "title": "Wrap things up", "body": "Sleep in 15 minutes. Save your work.", "position": "center", "auto_dismiss": "20" } }
  ]
},
{
  "id": "wind-down-sleep",
  "category": "daily",
  "routine_name": "Wind Down",
  "routine_description": "Evening routine to rest, wrap up, and sleep",
  "routine_icon": "moon.fill",
  "routine_color": "indigo",
  "schedule_name": "Sleep & Lock",
  "schedule_description": "Sleep the Mac after a 30s cancelable countdown",
  "rrule": "FREQ=DAILY;BYHOUR=22;BYMINUTE=59",
  "default_times": ["22:59"],
  "actions": [
    { "type": "system_command", "name": "Sleep & Lock",
      "parameters": { "command": "sleep", "countdown_seconds": "30", "cancelable": "true", "message": "Time to wind down" } }
  ]
}
```

- [ ] **Step 2: Mirror the same three entries** into `clients/macos-swift/VibeCare/vibecare/Resources/TemplateConfigs.json` (match that file's existing structure/field names — inspect an existing entry first and adapt keys if they differ from the backend file).

- [ ] **Step 3: Verify both JSON files are valid**

Run:
```bash
python3 -c "import json;json.load(open('backend/internal/storage/data/schedule_templates.json'));print('backend OK')"
python3 -c "import json;json.load(open('clients/macos-swift/VibeCare/vibecare/Resources/TemplateConfigs.json'));print('client OK')"
```
Expected: `backend OK` and `client OK`.

- [ ] **Step 4: Verify backend still passes and template loads**

Run: `just test 2>&1 | tail -20`
Expected: backend tests pass. If a template-loader test exists, confirm the new IDs load; otherwise this is covered by the JSON-parse check above.

- [ ] **Step 5: Verify routine grouping (spec open question)**

Load the template in the running app (Template selection UI) and confirm the three schedules land under **one** "Wind Down" routine. If the loader creates three separate routines instead, note it and adjust the loader (`backend/internal/storage/template_loader.go`) so entries sharing `routine_name` reuse one routine — track as a follow-up if larger than a trivial change.

- [ ] **Step 6: Commit**

```bash
git add backend/internal/storage/data/schedule_templates.json \
        clients/macos-swift/VibeCare/vibecare/Resources/TemplateConfigs.json
git commit -m "feat: add Wind Down template with sleep+lock action"
```

---

## Milestone M3 — Cross-platform mapping reference (docs only)

### Task M3.1: Write the command→native mapping doc

**Files:**
- Create: `docs/cross-platform-system-commands.md`

- [ ] **Step 1: Write the reference doc**

```markdown
# Cross-Platform System Commands

System commands execute **client-side**. The contract is the platform-neutral
`command` vocabulary stored in an Action's `parameters` map; each platform client
maps the same command to its own native invocation. macOS is implemented today
(`SystemCommandHandler`); this table is the spec a future Linux/Windows client
implements against.

## Parameters
- `command`: lock | sleep | display_sleep | logout | shutdown | restart
- `countdown_seconds`: integer string, 0 = immediate (no overlay)
- `cancelable`: "true" | "false" (default true)
- `message`: optional overlay heading

## Mapping

| command | macOS (implemented) | Linux (future) | Windows (future) |
|---|---|---|---|
| lock | `CGSession -suspend` | `loginctl lock-session` | `rundll32 user32.dll,LockWorkStation` |
| sleep | lock, then `pmset sleepnow` | `systemctl suspend` | `SetSuspendState` |
| display_sleep | `pmset displaysleepnow` | `xset dpms force off` | `SendMessage … SC_MONITORPOWER` |
| logout | `osascript … log out` | `loginctl terminate-session` | `shutdown /l` |
| shutdown | `osascript … shut down` | `systemctl poweroff` | `shutdown /s` |
| restart | `osascript … restart` | `systemctl reboot` | `shutdown /r` |

## Contract for new platform clients
1. Implement a handler switching on the `command` vocabulary above.
2. `sleep` must lock (or guarantee lock-on-wake) before suspending.
3. Honor `countdown_seconds`/`cancelable` with a cancelable UI before destructive commands.
4. Never crash on unknown commands — log and no-op.
```

- [ ] **Step 2: Verify links/table render** (open in a Markdown preview; confirm the table and both non-macOS columns are filled).

- [ ] **Step 3: Commit**

```bash
git add docs/cross-platform-system-commands.md
git commit -m "docs: cross-platform system command mapping"
```

---

## Self-Review Notes (for the implementer)

- **Spec coverage:** cross-platform seam → M0.2/M0.3 + M3; macOS mechanism → M0.3/M0.4; countdown overlay → M1; wind-down template → M2; "backend untouched" → enforced by Global Constraints; error surfacing → `runInvocations` logs + stops (a VibeNotify error toast can be added when wiring `NotificationManager`, tracked as a small follow-up, not required for the flow).
- **Manual-only steps** (M0.5 Step 3, M1.3 Step 5) are intentional: they exercise real `pmset`/`CGSession` and the overlay, which must never run inside `xcodebuild test`.
- **Follow-ups explicitly deferred:** meeting/screen-share suppression; the remaining unimplemented commands (`display_sleep`/`logout`/`shutdown`/`restart` already parse and route — only their `invocations` are empty); a VibeNotify error toast on command failure.
```
