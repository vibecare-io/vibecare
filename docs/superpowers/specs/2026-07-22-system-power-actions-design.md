# System Power Actions (Sleep / Lock) — Design

**Date:** 2026-07-22
**Status:** Approved design, pending spec review
**Scope:** macOS client only (Linux/Windows: design-ready, not implemented)

## 1. Problem & Goal

VibeCare can notify the user on a schedule, but the `System Command` action type
(`ACTION_TYPE_SYSTEM_COMMAND`, already in the proto and the client's Add-Action
menu) is an unimplemented no-op. We want the client to actually control the
machine — starting with **putting the laptop to sleep and locking the screen** —
so a nightly wind-down routine works end to end:

- **22:30** → notification: "take rest"
- **22:45** → notification: "wrap up in 15 min"
- **22:59** → **sleep the machine** after a **30-second cancelable countdown**, locking on the way down.

A second, explicit requirement: the system-command mechanism must be **designed
so Linux and Windows clients can implement the same actions later** without a
redesign — even though only macOS is built now.

### Non-goals (explicitly out of scope)

- No general action-executor framework. Other stub actions (`run_script`,
  `play_sound`, `api_call`, `send_email`) are **not** implemented here.
- No meeting / screen-share detection to suppress sleep (deferred to backlog;
  the cancelable countdown is the safety mechanism for now).
- No backend action execution. The backend stays a pure scheduler/dispatcher.
- No Linux/Windows implementation — only the contract they will implement against.

## 2. Current State (as-built, verified)

- **Architecture is client-driven.** The Go backend only schedules and
  broadcasts lightweight `ScheduleTriggeredEvent`s (IDs only) over a gRPC
  stream. It has **zero** OS-specific code and never executes actions. The
  backend needs **no changes** for this feature.
- **The client executes actions locally** in `EventService.executeAction(_:for:)`
  (`clients/macos-swift/VibeCare/vibecare/Services/EventService.swift:227`), a
  `switch action.type`. Only `.notification` (→ `NotificationManager`) and
  `.openLink` (→ `LinkHandler`) do anything today.
- **`case .systemCommand:` is a `// TODO` no-op** (`EventService.swift:249`).
- **The app is not sandboxed** — `vibecare.entitlements` has only
  `network.client` and `files.user-selected.read-write`; no
  `com.apple.security.app-sandbox`. Hardened Runtime is on but does not block
  subprocess execution. Therefore the client **may** run `Process` (NSTask) to
  shell out to `pmset` / `CGSession`.
- **Action parameters are a free-form `map<string,string>`** on the `Action`
  proto message — no per-type schema in storage — so new command parameters need
  no proto/DB migration.
- **Templates** are JSON entries (`backend/internal/storage/data/schedule_templates.json`,
  mirrored in the client's `Resources/TemplateConfigs.json`). Each entry is a
  routine + one schedule + `actions[]`, where each action has a `type` and a
  `parameters` map. Multiple entries sharing a `routine_name` group under one
  routine.

## 3. Design

### 3.1 The cross-platform seam

The cross-platform guarantee is **a platform-neutral command vocabulary carried
in the action's `parameters` map**, not an abstraction layer. We add one handler
in the existing per-handler style (alongside `NotificationManager`,
`LinkHandler`): **`SystemCommandHandler`**, wired into the `.systemCommand` case.

**Parameter contract** (stored in `Action.parameters`):

| key | values | notes |
|---|---|---|
| `command` | `lock`, `sleep`, `display_sleep`, `logout`, `shutdown`, `restart` | Only `lock` and `sleep` implemented now. Unknown/unimplemented → logged error + no-op, never a crash. |
| `countdown_seconds` | integer string, e.g. `"30"` | `0` or absent = execute immediately, no overlay. |
| `cancelable` | `"true"` / `"false"` | Default `true`. Only meaningful when a countdown is shown. |
| `message` | free text | Optional overlay heading; defaults per command. |

**Platform mapping table** (the design deliverable that makes Linux/Windows
drop-in — each client owns its column, same semantic `command`):

| command | macOS (implemented) | Linux (future) | Windows (future) |
|---|---|---|---|
| `lock` | `CGSession -suspend` | `loginctl lock-session` | `rundll32 user32.dll,LockWorkStation` |
| `sleep` | `pmset sleepnow` | `systemctl suspend` | `SetSuspendState` |
| `display_sleep` | `pmset displaysleepnow` | `xset dpms force off` | `SendMessage … SC_MONITORPOWER` |
| `logout` | `osascript … log out` | `loginctl terminate-session` | `shutdown /l` |
| `shutdown` | `osascript … shut down` | `systemctl poweroff` | `shutdown /s` |
| `restart` | `osascript … restart` | `systemctl reboot` | `shutdown /r` |

`SystemCommandHandler` is macOS-only (lives in the Swift client). A future GTK or
Windows client implements its own handler behind the same `command` vocabulary and
its own column of this table. No shared cross-platform code is written now.

### 3.2 macOS mechanism

`SystemCommandHandler` runs commands via `Process`:

- **`lock`** → `/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession -suspend`.
  Switches to the login window. No special permission, no Accessibility prompt,
  reliable across macOS versions.
- **`sleep`** → `/usr/bin/pmset sleepnow`. No root needed for `sleepnow`.
- **The 22:59 step = one action** `command: sleep`. On countdown expiry the
  handler runs **`lock` then `sleep`** in sequence, so the machine is at the login
  window on wake regardless of the user's "require password after sleep" setting.
  ("Sleep + lock" is satisfied by the single `sleep` action's lock-before-sleep.)
- **Error handling:** each `Process` call captures a non-zero exit / launch
  failure and surfaces it as a VibeNotify error toast plus an `ExecutionLog` note.
  A failed sleep is never silent.

### 3.3 Countdown overlay

A borderless `NSWindow` (or one per screen) at `.screenSaver` window level, dark
semi-transparent blur, large centered countdown — matching the approved mockup:

```
╔═══════════════════════════════╗
║          🌙  22:59            ║
║      Sleeping in  27          ║
║    press Esc to stay awake    ║
╚═══════════════════════════════╝
```

- **Shown only when** `countdown_seconds > 0`. Otherwise the command runs
  immediately with no overlay.
- **Cancel** (`Esc` or a "Stay awake" button, when `cancelable`): dismiss the
  overlay, **skip this occurrence only** (the schedule fires again next night),
  log the cancellation. No command runs.
- **Expiry:** animate out, then run the command (lock → sleep).
- **Edge cases:** a re-fire while an overlay is already showing is ignored
  (dedupe). The overlay rebuilds if displays are attached/detached mid-countdown.

### 3.4 Wind-down template (authoring path)

Per decision, the nightly flow is delivered as a **seeded template**, not a new
editor UI. Three template entries share `routine_name: "Wind Down"`:

1. `FREQ=DAILY;BYHOUR=22;BYMINUTE=30` → `notification` "take rest"
2. `FREQ=DAILY;BYHOUR=22;BYMINUTE=45` → `notification` "wrap up in 15 min"
3. `FREQ=DAILY;BYHOUR=22;BYMINUTE=59` → `system_command`
   `{ command: "sleep", countdown_seconds: "30", cancelable: "true",
   message: "Time to wind down" }`

Added to `backend/internal/storage/data/schedule_templates.json` and the client's
`Resources/TemplateConfigs.json`. Times are then editable in the existing schedule
editor. (Implementation note to verify in M2: confirm the template loader groups
the three shared-`routine_name` entries under one routine, or adjust.)

## 4. Milestones

- **M0 — Wire it up.** Add `SystemCommandHandler`; implement `lock` and `sleep`
  with `countdown_seconds: 0` (immediate, no overlay). Replace the `.systemCommand`
  TODO. Verify end-to-end: a real schedule sleeps/locks the Mac.
- **M1 — Countdown overlay.** Full-screen dim overlay with live countdown and
  Esc/"Stay awake" cancel, wired to `sleep`.
- **M2 — Wind-down template.** Seed the three-schedule "Wind Down" routine
  (22:30 / 22:45 / 22:59) with the sleep action pre-wired.
- **M3 — Cross-platform doc (no code).** Finalize the mapping table and the
  `command` vocabulary contract as reference for future Linux/Windows clients.
- **Backlog (not now).** Suppress sleep during meetings / screen-share (ties to
  `docs/ideas.org` "detect meetings"); implement the remaining stub actions.

## 5. Risks & Open Questions

- **`CGSession` path stability:** the `CGSession -suspend` path has been stable
  for many macOS releases but is technically undocumented. Fallback:
  `pmset displaysleepnow` (locks on wake if the user requires password after
  display sleep). Verify on the current macOS 15+ target during M0.
- **Template routine grouping:** verify the loader's behavior for multiple
  entries sharing a `routine_name` (M2).
- **Notifications during sleep window:** the 22:30/22:45 notifications use the
  existing VibeNotify path; no change needed, but confirm they don't collide with
  the overlay at 22:59.

## 6. Files Touched (anticipated)

- `clients/.../vibecare/Services/SystemCommandHandler.swift` — **new**, the handler.
- `clients/.../vibecare/Services/EventService.swift:249` — wire `.systemCommand`.
- `clients/.../vibecare/Views/…/SleepCountdownOverlay.swift` — **new** (M1).
- `backend/internal/storage/data/schedule_templates.json` — wind-down template (M2).
- `clients/.../vibecare/Resources/TemplateConfigs.json` — wind-down template (M2).
- `docs/` — cross-platform mapping reference (M3).
- **No proto, no DB migration, no backend Go logic changes.**
