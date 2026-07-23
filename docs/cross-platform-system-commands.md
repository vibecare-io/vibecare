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
