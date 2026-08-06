# System Command Action — Authoring UI — Design

**Date:** 2026-08-06
**Status:** Approved design, pending spec review
**Scope:** macOS client only (`ActionEditSheet` / `ActionParametersView`)

## 1. Problem & Goal

When a user adds a **System Command** action, the editor renders a single
free-text box labeled "System command to execute". The user must *know* to type
the literal token `sleep` (or `lock`). This is poor UX:

- The valid vocabulary (`lock`, `sleep`, …) is invisible — the field looks like
  it accepts arbitrary shell commands.
- The other parameters the handler already honors — `countdown_seconds`,
  `cancelable`, `message` — cannot be set from the UI at all. Today they only
  exist if seeded by the Wind Down template.

**Goal:** make System Command actions fully self-serve from the editor — a
dropdown of known commands plus fields for countdown, cancelable, and message —
without changing the stored data contract, proto, DB, or the runtime handler.

### Non-goals

- No new action types; no changes to `SystemCommandHandler` execution.
- No proto or DB migration — the stored `parameters` map is unchanged.
- No conditional field visibility — all four fields are always shown.
- Only the implemented commands (`lock`, `sleep`) appear in the dropdown.

## 2. Current State (as-built, verified)

- `ActionEditSheet` (`Views/Schedules/ActionEditSheet.swift`) branches on action
  type: `.notification` → `NotificationActionParametersView`; everything else →
  the generic `ActionParametersView`.
- `ActionParametersView` (`Views/Schedules/ActionCardView.swift:292`) iterates
  `type.requiredParameters` and renders `.string`→`TextField`,
  `.number`→`TextField`, `.boolean`→`Toggle`. It **ignores**
  `ActionParameter.allowedValues` — there is no picker branch.
- `ActionParameter` (`Models/Action.swift:156`) already declares
  `allowedValues: [String]?` and `defaultValue: String?` — both currently unused
  by the renderer.
- `systemCommand.requiredParameters` (`Models/Action.swift:136`) declares exactly
  one param: `command` (`.string`, required, free-text).
- `ActionEditSheet` resets `parameters` to `[:]` on action-type change
  (`ActionEditSheet.swift:72`); `isValid` requires every `required` param to be
  non-empty (`ActionEditSheet.swift:168`).
- The runtime `SystemCommandRequest.parse` already reads `command`,
  `countdown_seconds`, `cancelable`, `message` from the parameters map
  (`Services/SystemCommandHandler.swift:23`).
- `CountdownTimerPicker` exists but is minutes-based and mutates a schedule
  `startDate` — **not** reusable for a seconds field. We will not reuse it.

## 3. Design

### 3.1 Declarative picker support (generic, reusable)

Add one branch to `ActionParametersView`: when a `.string` param has non-nil
`allowedValues`, render a SwiftUI `Picker` (menu style) instead of a `TextField`.
The picker shows a human label but stores the raw vocabulary term:

- Raw→label helper: capitalize words and replace `_` with a space
  (`display_sleep` → "Display Sleep"). Stored value is always the raw term.
- The binding writes the selected raw value into `parameters[param.name]`.

This is generic: any future param with `allowedValues` (e.g. a log `level`, an
HTTP `method`) gets a dropdown with no extra code.

### 3.2 Expanded `systemCommand.requiredParameters`

```
command            .string   required   allowedValues: ["lock", "sleep"]   default: "sleep"
countdown_seconds  .number   optional   default: "30"
cancelable         .boolean  optional   default: "true"
message            .string   optional   (no default; placeholder text)
```

Rendering with the existing branches (plus 3.1):
- `command` → dropdown (Lock / Sleep).
- `countdown_seconds` → number `TextField`, suffix hint "seconds".
- `cancelable` → `Toggle` ("Allow Esc to cancel").
- `message` → single-line `TextField`, placeholder "Overlay heading (optional)".

Note: `ActionParametersView` currently forces multi-line for any param named
`message`. Since our overlay heading is short, we will render `message`
single-line for `systemCommand` (adjust the multi-line predicate so it does not
apply here).

### 3.3 Default seeding

Empty parameters break the dropdown (nothing selected) and fail `isValid` for the
required `command`. So: when the action type is chosen (and when loading an
existing action for edit), for each param that has a `defaultValue`, if
`parameters[name]` is empty, write the default. Result: switching to System
Command lands on `command=sleep`, `countdown_seconds=30`, `cancelable=true`.

Implementation seam: the `onChange(of: actionType)` handler in `ActionEditSheet`
(currently resets to `[:]`) seeds defaults after reset; a small helper on
`ActionType` or `ActionParametersView.onAppear` does the same for the edit path.

### 3.4 What does NOT change

- Stored `parameters` map is byte-for-byte what the Wind Down template already
  produces. `SystemCommandRequest.parse` is untouched.
- No proto, no DB migration, no `SystemCommandHandler` change.
- Notification authoring path (`NotificationActionParametersView`) is untouched.

## 4. Testing

- **Unit:** assert `ActionType.systemCommand.requiredParameters` exposes the four
  keys with the expected `allowedValues` and `defaultValue`s.
- **Unit:** the raw→label helper (`display_sleep` → "Display Sleep",
  `lock` → "Lock").
- **Existing handler/parse tests unchanged** — they already cover the resulting
  map.
- **Manual:** Add Action → System Command → dropdown shows Lock/Sleep, defaults to
  Sleep with countdown 30 / cancelable on; Save; confirm the created action's
  parameters match a template-seeded sleep action; fire the schedule and see the
  overlay.

## 5. Files Touched (anticipated)

- `clients/.../vibecare/Models/Action.swift` — expand
  `systemCommand.requiredParameters`; add raw→label display helper.
- `clients/.../vibecare/Views/Schedules/ActionCardView.swift` — picker branch in
  `ActionParametersView`; single-line `message` for system commands.
- `clients/.../vibecare/Views/Schedules/ActionEditSheet.swift` — seed defaults on
  type change / edit load.
- `clients/.../vibecare/vibecareTests/` — parameter-schema + label-helper tests.
- **No proto, no DB migration, no backend or handler changes.**
