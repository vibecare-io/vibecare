# System Command Action — Authoring UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the free-text "System command to execute" box with a command dropdown plus countdown/cancelable/message fields, so System Command actions are fully self-serve.

**Architecture:** Declarative. Extend the generic `ActionParametersView` to render a dropdown for any parameter that declares `allowedValues`, expand `systemCommand.requiredParameters` to declare all four fields with defaults, and seed those defaults into the parameters map when the action type is chosen. No proto, DB, or handler changes — the stored `parameters` map is byte-for-byte what the Wind Down template already produces.

**Tech Stack:** SwiftUI (macOS 15+), Swift Testing (`@Test`), Xcode test target `vibecareTests` (synchronized group — new test files auto-include).

**Spec:** `docs/superpowers/specs/2026-08-06-system-command-action-ui-design.md`

## Global Constraints

- No proto, DB migration, or `SystemCommandHandler` change — stored `parameters` keys stay exactly: `command`, `countdown_seconds`, `cancelable`, `message`.
- Dropdown stores the **raw** vocabulary term (`lock`/`sleep`), never the display label.
- Only implemented commands appear: `["lock", "sleep"]`.
- Tests run via: `xcodebuild test -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests` (run from `clients/macos-swift/VibeCare/`). There is no SPM test target; `swift test` finds nothing.
- Swift Testing references undefined symbols as **compile errors** — a "failing test" here means the suite fails to build until the implementation exists.

## File Structure

- **Modify** `clients/macos-swift/VibeCare/vibecare/Models/Action.swift` — expand `systemCommand.requiredParameters`; add `ActionParameter.displayLabel(for:)` and `ActionType.seedingDefaults(into:)`. (git-tracked path uses capitalized `VibeCare/Services`-style casing on a case-insensitive FS; `git add` the path git reports if a lowercase spec differs.)
- **Modify** `clients/macos-swift/VibeCare/vibecare/Views/Schedules/ActionCardView.swift` — add a Picker branch + `isMultiline` gating to `ActionParametersView`.
- **Modify** `clients/macos-swift/VibeCare/vibecare/Views/Schedules/ActionEditSheet.swift` — seed defaults on init and on action-type change.
- **Create** `clients/macos-swift/VibeCare/vibecareTests/ActionParameterUITests.swift` — schema, label-helper, and seeding tests.

---

### Task 1: Parameter schema + display/seeding helpers

All the pure, unit-testable logic. The two view tasks depend on the symbols defined here.

**Files:**
- Modify: `clients/macos-swift/VibeCare/vibecare/Models/Action.swift` (`systemCommand` case at ~136; add extensions after the `ActionParameter` struct at ~179)
- Test: `clients/macos-swift/VibeCare/vibecareTests/ActionParameterUITests.swift` (create)

**Interfaces:**
- Consumes: existing `ActionParameter(name:type:required:description:defaultValue:allowedValues:)` initializer and `enum ParameterType { .string, .number, .boolean, ... }`.
- Produces:
  - `ActionType.systemCommand.requiredParameters` → `[command, countdown_seconds, cancelable, message]` with `command.allowedValues == ["lock","sleep"]`, `command.defaultValue == "sleep"`, `countdown_seconds.defaultValue == "30"`, `cancelable.defaultValue == "true"`.
  - `static func ActionParameter.displayLabel(for rawValue: String) -> String`
  - `func ActionType.seedingDefaults(into parameters: [String: String]) -> [String: String]`

- [ ] **Step 1: Write the failing tests**

Create `clients/macos-swift/VibeCare/vibecareTests/ActionParameterUITests.swift`:

```swift
import Testing
@testable import vibecare

@Test func systemCommandExposesCommandDropdownVocabulary() {
    let byName = Dictionary(uniqueKeysWithValues:
        ActionType.systemCommand.requiredParameters.map { ($0.name, $0) })
    #expect(byName["command"]?.allowedValues == ["lock", "sleep"])
    #expect(byName["command"]?.defaultValue == "sleep")
    #expect(byName["command"]?.required == true)
    #expect(byName["countdown_seconds"]?.defaultValue == "30")
    #expect(byName["cancelable"]?.defaultValue == "true")
    #expect(byName["message"]?.required == false)
    #expect(byName["message"]?.defaultValue == nil)
}

@Test func displayLabelHumanizesRawValues() {
    #expect(ActionParameter.displayLabel(for: "lock") == "Lock")
    #expect(ActionParameter.displayLabel(for: "sleep") == "Sleep")
    #expect(ActionParameter.displayLabel(for: "display_sleep") == "Display Sleep")
}

@Test func seedingFillsMissingSystemCommandDefaults() {
    let seeded = ActionType.systemCommand.seedingDefaults(into: [:])
    #expect(seeded["command"] == "sleep")
    #expect(seeded["countdown_seconds"] == "30")
    #expect(seeded["cancelable"] == "true")
    #expect(seeded["message"] == nil)
}

@Test func seedingPreservesExistingValues() {
    let seeded = ActionType.systemCommand.seedingDefaults(
        into: ["command": "lock", "countdown_seconds": "10"])
    #expect(seeded["command"] == "lock")
    #expect(seeded["countdown_seconds"] == "10")
    #expect(seeded["cancelable"] == "true")   // still filled from defaults
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `clients/macos-swift/VibeCare/`):
```bash
xcodebuild test -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | grep -iE "error:|TEST FAILED|TEST SUCCEEDED" | tail -20
```
Expected: build/compile error — `displayLabel`/`seedingDefaults` are undefined and `command` has no `allowedValues`/`defaultValue` yet.

- [ ] **Step 3: Expand the systemCommand parameter schema**

In `Models/Action.swift`, replace the `.systemCommand` case in `requiredParameters` (currently a single `command` string param):

```swift
        case .systemCommand:
            return [
                ActionParameter(name: "command", type: .string, required: true,
                                description: "Command", defaultValue: "sleep",
                                allowedValues: ["lock", "sleep"]),
                ActionParameter(name: "countdown_seconds", type: .number, required: false,
                                description: "Countdown (seconds)", defaultValue: "30"),
                ActionParameter(name: "cancelable", type: .boolean, required: false,
                                description: "Allow Esc to cancel", defaultValue: "true"),
                ActionParameter(name: "message", type: .string, required: false,
                                description: "Overlay heading (optional)")
            ]
```

- [ ] **Step 4: Add the display-label and seeding helpers**

In `Models/Action.swift`, after the `ActionParameter` struct definition, add:

```swift
extension ActionParameter {
    /// Human-readable label for a raw allowedValues term:
    /// "lock" -> "Lock", "display_sleep" -> "Display Sleep".
    static func displayLabel(for rawValue: String) -> String {
        rawValue
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

extension ActionType {
    /// Return `parameters` with any missing values filled from each parameter's
    /// `defaultValue`. Existing (non-empty) values are preserved. Ensures pickers
    /// and toggles start on a valid selection and required params are satisfied.
    func seedingDefaults(into parameters: [String: String]) -> [String: String] {
        var result = parameters
        for param in requiredParameters {
            guard let def = param.defaultValue else { continue }
            if result[param.name]?.isEmpty ?? true {
                result[param.name] = def
            }
        }
        return result
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run (from `clients/macos-swift/VibeCare/`):
```bash
xcodebuild test -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | grep -iE "TEST FAILED|TEST SUCCEEDED" | tail -3
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add clients/macos-swift/VibeCare/vibecare/Models/Action.swift clients/macos-swift/VibeCare/vibecareTests/ActionParameterUITests.swift
git commit -m "feat(client): declare system command params with vocabulary + defaults"
```
(If `git add` reports the Action.swift path as unmodified, re-add using the exact path from `git status --short`.)

---

### Task 2: Dropdown rendering in ActionParametersView

Renders `allowedValues` params as a menu Picker and keeps the system-command `message` single-line. Pure SwiftUI; no automated test possible without ViewInspector (not in this project), so verification is build + visual.

**Files:**
- Modify: `clients/macos-swift/VibeCare/vibecare/Views/Schedules/ActionCardView.swift` (`ActionParametersView`, `.string` case at ~313; add `isMultiline` helper near `binding(for:)` at ~344)

**Interfaces:**
- Consumes: `ActionParameter.displayLabel(for:)` and `ActionParameter.allowedValues` (from Task 1); existing `binding(for:) -> Binding<String>` and `type: ActionType` on `ActionParametersView`.
- Produces: no new symbols; a Picker appears for params with `allowedValues`.

- [ ] **Step 1: Replace the `.string` case with picker-aware rendering**

In `ActionCardView.swift`, replace the `case .string:` block inside `ActionParametersView.body`:

```swift
                    case .string:
                        if let allowed = param.allowedValues {
                            // Fixed vocabulary -> dropdown; stores the raw term.
                            Picker(param.description, selection: binding(for: param.name)) {
                                ForEach(allowed, id: \.self) { raw in
                                    Text(ActionParameter.displayLabel(for: raw)).tag(raw)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        } else if isMultiline(param) {
                            // Multi-line text for long free-text fields
                            TextField(param.description, text: binding(for: param.name), axis: .vertical)
                                .textFieldStyle(.plain)
                                .lineLimit(3...6)
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(6)
                        } else {
                            // Single-line text for other fields
                            TextField(param.description, text: binding(for: param.name))
                                .textFieldStyle(.roundedBorder)
                        }
```

- [ ] **Step 2: Add the `isMultiline` helper**

In `ActionParametersView`, add next to `binding(for:)`:

```swift
    /// Long free-text fields render multi-line — except the system command's
    /// short overlay `message`, which stays single-line.
    private func isMultiline(_ param: ActionParameter) -> Bool {
        if type == .systemCommand { return false }
        return param.name == "body" || param.name == "script" || param.name == "message"
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run (from repo root): `just swift-build`
Expected: `Build complete!` with no errors.

- [ ] **Step 4: Run the test suite (no regressions)**

Run (from `clients/macos-swift/VibeCare/`):
```bash
xcodebuild test -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | grep -iE "TEST FAILED|TEST SUCCEEDED" | tail -3
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add clients/macos-swift/VibeCare/vibecare/Views/Schedules/ActionCardView.swift
git commit -m "feat(client): render allowedValues params as a dropdown"
```

---

### Task 3: Seed defaults in ActionEditSheet

Wires seeding so the dropdown lands on Sleep (not blank) and countdown/cancelable are pre-filled, both when switching to System Command and when editing an existing action. Verified end-to-end in the running app.

**Files:**
- Modify: `clients/macos-swift/VibeCare/vibecare/Views/Schedules/ActionEditSheet.swift` (init at ~36; `onChange(of: actionType)` at ~72)

**Interfaces:**
- Consumes: `ActionType.seedingDefaults(into:)` (from Task 1); existing `NotificationActionViewModel(preferences:parameters:)`.
- Produces: no new symbols.

- [ ] **Step 1: Seed defaults on the edit/load path**

In `ActionEditSheet.init`, replace the `_viewModel` initializer:

```swift
        self._viewModel = State(initialValue: NotificationActionViewModel(
            preferences: actionCard.notificationPreferences,
            parameters: actionCard.type.seedingDefaults(into: actionCard.parameters)
        ))
```

- [ ] **Step 2: Seed defaults when the action type changes**

Replace the `.onChange(of: actionType)` body:

```swift
                        .onChange(of: actionType) { _, newType in
                            // Reset ViewModel and seed defaults for the new type
                            viewModel = NotificationActionViewModel(
                                preferences: .default,
                                parameters: newType.seedingDefaults(into: [:])
                            )
                        }
```

- [ ] **Step 3: Build**

Run (from repo root): `just swift-build`
Expected: `Build complete!`

- [ ] **Step 4: Manual end-to-end verification**

Run the client (`just swift-run`). Then:
1. Add a schedule (or edit one) → **Add Action** → set Action Type to **System Command**.
2. Confirm: a **Command** dropdown shows **Lock / Sleep**, defaulting to **Sleep**; a **Countdown (seconds)** field shows **30**; **Allow Esc to cancel** toggle is **on**; **Overlay heading** is empty (single-line).
3. Switch Action Type away (e.g. Notification) and back to System Command — fields re-seed to the defaults (no blank dropdown).
4. Set command to **Lock**, Save. Reopen the action and confirm it persists as `command=lock`.
5. (Optional full loop) Fire the schedule and confirm the overlay/lock behaves per the saved values.

- [ ] **Step 5: Run the test suite**

Run (from `clients/macos-swift/VibeCare/`):
```bash
xcodebuild test -scheme vibecare -destination 'platform=macOS' -only-testing:vibecareTests 2>&1 | grep -iE "TEST FAILED|TEST SUCCEEDED" | tail -3
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add clients/macos-swift/VibeCare/vibecare/Views/Schedules/ActionEditSheet.swift
git commit -m "feat(client): seed system command defaults in the action editor"
```

---

## Self-Review

**Spec coverage:**
- §3.1 declarative picker support → Task 2 (Picker branch driven by `allowedValues`).
- §3.2 expanded parameters (command/countdown/cancelable/message with defaults) → Task 1.
- §3.2 single-line `message` for system commands → Task 2 (`isMultiline` gate).
- §3.3 default seeding on type change + edit load → Task 3 (+ `seedingDefaults` in Task 1).
- §3.4 no proto/DB/handler change → Global Constraints; no such files touched.
- §4 tests (schema + label helper) → Task 1; existing handler/parse tests untouched; manual UI check → Task 3 Step 4.

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step has literal code.

**Type consistency:** `displayLabel(for:)` and `seedingDefaults(into:)` signatures match between Task 1 (definition) and Tasks 2–3 (use). `allowedValues`/`defaultValue`/`required` property names match the existing `ActionParameter` struct. Dropdown binding is `Binding<String>` with `String` tags — consistent.
