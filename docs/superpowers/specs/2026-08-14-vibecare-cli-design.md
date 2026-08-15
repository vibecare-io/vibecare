# VibeCare CLI & TUI — design

**Date:** 2026-08-14
**Status:** approved, ready for implementation planning

## 1. Purpose

A single Go binary, `vibecare`, that answers "what is VibeCare doing right
now, and why is it broken" without opening the Swift app.

It serves two audiences from one codebase:

- **A human debugging the stack.** `vibecare` with no arguments launches a
  full-screen TUI: plugin roster, live state, logs, alerts, schedules.
- **An agent or script driving VibeCare.** Every read command supports
  `--json` against a stable schema, and every command returns a meaningful
  exit code.

The binary is a *client*. It owns no state, no database, and no scheduling
logic. Everything it displays comes from core over gRPC, from the kernel's
HTTP surface, or from log files on disk.

## 2. What already exists

Establishing the surface the client consumes, because two facts about it
are non-obvious and shape the whole design.

**gRPC on `:50051`** carries both API generations:

- `ProfileService`, `RoutineService`, `ScheduleService`, `ActionService` —
  the v1 domain API (`proto/vibecare.proto`).
- `Shell` — the frozen v2 client contract (`proto/client/v1/client.proto`):
  `Plugins` streams the roster, `Intents` streams alerts.

Reflection is registered, so `grpcurl` remains available for spot checks.

**HTTP on `:8080`** serves `/version`, `/api/scheduler/status`, `/status`,
and pprof.

**The kernel's HTTP surface is on a different, ephemeral port.** The kernel
binds `127.0.0.1:0` deliberately — "no ports to configure and nothing to
collide with" (`backend/kernel/kernel.go:19-21`). It serves:

- `GET /_core/api/plugins` — per-plugin id, name, path, ui, state, detail,
  pid, uptime, restarts, probe latency, events published/delivered.
- `POST /_core/api/plugins/<id>/restart`
- `/p/<id>/` — reverse proxy to each plugin's own UI.

Because that port is ephemeral, **it cannot be guessed or configured**. The
only way to learn it is the `Shell.Plugins` stream, whose `PluginList`
carries `base_url` and `token`. This is by design, and the client follows
the designed path rather than working around it.

**Logs are the gap.** `backend/kernel/supervisor.go:234` sets
`cmd.Stdout = os.Stderr` and `cmd.Stderr = os.Stderr`, so plugin output goes
to core's stderr. Core's zap logger writes to `~/.vibecare/logs/server.log`,
but it never sees the plugin's file descriptors — plugin output reaches the
terminal that started core and nowhere else. Retrieving a crashed plugin's
last words is currently impossible.

## 3. Backend change

Deliberately minimal: teach the supervisor to persist plugin output, and
make the resulting path discoverable. **No new endpoints.**

### 3.1 Per-plugin log files

`backend/kernel/plugin_log.go` (new) provides a `pluginLog` writer:

- Opens `<LogsDir>/plugins/<id>.log` append-mode, `0o600`.
- Rotates at 8 MiB to `<id>.log.1`, keeping exactly one generation. Two
  files, bounded at 16 MiB per plugin, no external dependency, no timer.
- Safe for concurrent writes from the two file descriptors it backs.

`supervisor.go` changes one thing:

```go
lw, err := newPluginLog(s.logsDir, m.ID)   // nil-safe on error
cmd.Stdout = io.MultiWriter(lw, os.Stderr)
cmd.Stderr = io.MultiWriter(lw, os.Stderr)
```

Teeing to `os.Stderr` is retained so `just run` output is unchanged. If the
log file cannot be opened the supervisor logs a warning and falls back to
stderr only — logging must never prevent a plugin from starting.

The writer is closed in the existing process-exit cleanup path.

### 3.2 Discoverable path

- `kernel.Config` gains `LogsDir`; `DefaultConfig` sets it to
  `<home>/.vibecare/logs`, alongside `server.log`.
- `PluginStat` gains `LogPath string`.
- `statusPluginJSON` gains `log_path`.

The client reads the path from the JSON rather than reconstructing it. The
convention is documented but never hard-coded in the client, so changing it
later does not break the client.

### 3.3 Tests

Table tests in `backend/kernel/`: rotation at threshold, single generation
retained, append across reopen, graceful degradation when the directory is
unwritable, and that a spawned plugin's stdout lands in its file.
`TestKernelContainsNoProductNouns` must continue to pass — nothing added
here names a product concept.

## 4. Client architecture

### 4.1 Module

`clients/cli/` is its own Go module, following the pattern
`plugins/vibecheck/` established:

```
module github.com/vibecare-io/vibecare/clients/cli
replace github.com/vibecare-io/vibecare/backend => ../../backend
```

This yields `backend/pkg/proto/**` directly — no second codegen path, no
duplicated contract, no drift. Binary output: `bin/vibecare`.

### 4.2 Layering

Three layers with one rule between them: **the CLI and the TUI are both
thin frontends over `internal/vc`, and neither performs I/O of its own.**

```
internal/vc       transport + domain. The ONLY package that talks to core.
internal/cli      cobra commands + printers. Calls vc, formats, exits.
internal/tui      bubbletea models. Calls vc from cmds.go, nowhere else.
```

Two support packages have no VibeCare knowledge at all and are unit-testable
in isolation:

```
internal/logtail  follow a file across rotation; merge N sources
internal/notify   Notifier interface + per-platform implementations
```

This is what makes the tests cheap: `internal/vc` is exercised against an
in-process gRPC server over `bufconn` with fake `Shell` and `ScheduleService`
implementations, so the whole suite runs with no backend, no database, and
no plugins.

### 4.3 File layout

```
clients/cli/
  go.mod
  main.go                      # ~15 lines: cli.Execute()
  README.md
  internal/
    vc/
      types.go                 # domain structs; json tags ARE the contract
      session.go               # dial, Shell.Plugins stream, kernel origin+token
      plugins.go               # roster, kernel stats, restart
      schedules.go             # ScheduleService wrappers
      routines.go              # RoutineService wrappers
      actions.go               # ActionService wrappers
      alerts.go                # Shell.Intents stream
      logs.go                  # resolve log sources; hand off to logtail
      core.go                  # /version, /api/scheduler/status, reachability
      errors.go                # errors carrying exit codes
    logtail/
      tail.go                  # follow one file across truncation/rotation
      merge.go                 # merge N tailers into one prefixed stream
    notify/
      notify.go                # Notifier interface + noop default
      notify_darwin.go         # osascript
      notify_linux.go          # notify-send
    cli/
      root.go                  # cobra root, global flags, exit-code mapping
      status.go plugins.go logs.go schedules.go alerts.go routines.go actions.go
      output/
        printer.go             # Printer interface
        table.go
        json.go
    tui/
      app.go                   # root model: layout, focus, subject/tab routing
      msgs.go                  # every tea.Msg, in one place
      cmds.go                  # every tea.Cmd — the ONLY tui file importing vc
      sidebar.go
      tabs.go                  # tab strip + chip row
      transient.go             # the space popup, rendered from keymap
      footer.go
      help.go
      pane_overview.go
      pane_logs.go
      pane_events.go
      pane_alerts.go
      pane_schedules.go
      pane_routines.go
      pane_manifest.go
      keymap/keymap.go         # binding tables — single source of truth
      theme/theme.go           # lipgloss styles
```

Two organizing rules, both mechanically checkable:

1. **One pane per file**, named `pane_<name>.go`. A pane that outgrows its
   file is a pane doing too much.
2. **`cmds.go` is the only file in `internal/tui` that imports
   `internal/vc`.** Everything else is pure `Update(msg) → (model, cmd)`,
   which is why the TUI is testable without a terminal.

### 4.4 Session and discovery

`vc.Session` owns connection lifecycle:

```
Dial(addr) ──► gRPC :50051
               ├─ Shell.Plugins stream ──► PluginList{plugins, base_url, token}
               │                                       └► kernel HTTP origin
               └─ domain service clients
```

The roster is **pushed** by the stream, never polled. The kernel origin and
token are cached from the latest `PluginList` and refreshed when it changes.
Kernel HTTP stats are polled at 2 s, and only while a view needing them is
visible.

Target selection: `--addr`, else `$VIBECARE_ADDR`, else `127.0.0.1:50051`.

**Degraded mode is a first-class path, not an error path.** If the dial
fails:

- `vibecare status` prints `core: unreachable` with the dial error, exit 2.
- `vibecare logs` still works — it reads files, and a dead core is exactly
  when you need them.
- The TUI shows a red header, holds last-known values marked stale, retries
  with backoff, and recovers without a restart.

## 5. Command surface

Delivered in four phases. Each phase is independently shippable and leaves
the binary useful.

### Phase 1 — the debugging spine

```
vibecare status                       core reachability, version, scheduler,
                                      plugin tally by state
vibecare plugins                      id, name, state, pid, uptime, restarts,
                                      probe latency, events pub/del
vibecare plugins restart <id>
vibecare logs <id|core> [-f] [-n N]
vibecare logs --all [-f]              merged, source-prefixed
```

### Phase 2 — schedules

```
vibecare schedules ls [--routine R] [--enabled]
vibecare schedules show <id>          detail + linked actions + next execution
vibecare schedules pause <id>
vibecare schedules resume <id>
vibecare schedules pause --all
vibecare schedules resume --all
```

`ListSchedulesRequest` filters by `routine_id`, not profile — the flag
matches the RPC.

### Phase 3 — alerts

```
vibecare alerts [-f] [--notify]
```

Streams `Shell.Intents`. `--notify` additionally bridges to the platform
notifier.

### Phase 4 — routines & actions

```
vibecare routines ls|show <id>|run <id>|logs <id>
vibecare actions  ls|show <id>|run <id>|types
```

### Global flags and exit codes

`--json`, `--addr`, `--no-color`, `-v/--verbose` on every command.

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | general error |
| 2 | core unreachable |
| 3 | not found |
| 4 | invalid arguments |

### The `--json` contract

`--json` output is a **stable, versioned contract**, not best-effort
pretty-printing, because agents will depend on the field names.

- Every payload is a single JSON object with a `"v": 1` field.
- Field names are `snake_case` and match the kernel's existing
  `/_core/api/plugins` names wherever the data is the same, so a reader that
  knows one knows the other.
- Adding fields is allowed. Renaming or removing a field requires bumping
  `v`.
- Timestamps are RFC 3339 in UTC. Durations are integer seconds with an
  `_sec` suffix.
- Empty collections serialize as `[]`, never `null`.
- Errors also print as JSON under `--json`: `{"v":1,"error":{"code":2,
  "message":"..."}}`, on stderr, with the matching exit code.

Golden-file tests lock this down. Changing a golden file is the review
signal that a contract changed.

## 6. TUI

### 6.1 Layout

20 % sidebar, 80 % detail, with tabs inside the detail pane.

```
┌──────────────┬──────────────────────────────────────────────────────────┐
│ ▸ ALL        │  Overview │ Logs │ Events │ Manifest │ Stats   vibecheck  │
│   core       │            ─────                                         │
│ ◆ vibecheck  │  follow:●  tail:500                                      │
│   todo       │   all    core   vibecheck   todo                         │
│              │                                                          │
│              │  vibecheck │ 12:04:01  detector started                  │
│              │  core      │ 12:04:02  plugin spawned pid=40122          │
│              │  vibecheck │ 12:04:09  publish vibecheck.bfrb.detected   │
└──────────────┴──────────────────────────────────────────────────────────┘
 f:follow  t:tail  s:since  r:restart  ←/→:tab  /:search  n:next  z:full
 y:copy  Y:copy-all  space:actions  ?:help
```

**Sidebar selects the subject:** `ALL`, `core`, then one row per plugin. The
bullet carries state colour — `◆` up, `◇` degraded, `○` down/failed — so the
sidebar alone answers "is anything broken".

**Tabs are facets of the selected subject** and change with it:

| Subject | Tabs |
|---|---|
| `ALL` | Overview · Logs · Alerts · Schedules · Routines |
| `core` | Status · Logs · Schedules · Routines · Actions |
| `<plugin>` | Overview · Logs · Events · Manifest · Stats |

**The chip row holds the active tab's controls.** Logs: `follow:● tail:500`
plus per-source chips. Schedules: `all enabled paused`. Alerts:
`all info warn`.

Below ~90 columns the sidebar collapses to icons; `z` zooms the detail pane
to full width.

### 6.2 The `space` transient

`space` opens a which-key/magit-style popup whose contents depend on the
focused pane and the selected subject.

```
      ╭─ vibecheck ───────────────────────────────────╮
      │  Plugin            View            Logs       │
      │   r  restart        o  overview     f  follow │
      │   s  stop           l  logs         t  tail   │
      │   S  start          e  events       s  since  │
      │   d  data dir       m  manifest     w  wrap   │
      │                                               │
      │  Global                                       │
      │   /  search   g  goto   ?  help   q  quit     │
      ╰───────────────────── esc cancel ──────────────╯
```

`internal/tui/keymap` holds one table per (pane, subject-kind) as pure data.
The footer, the transient popup, and `?:help` all render from that same
table, so a binding is declared exactly once and the three surfaces can
never disagree. The tables are ordinary Go values, so they are table-tested
directly.

### 6.3 Concurrency

All I/O happens in `tea.Cmd`s defined in `cmds.go`; each source of change
has its own `tea.Msg` type in `msgs.go`. Streams (roster, alerts, log tails)
run as long-lived goroutines feeding a channel that a `tea.Cmd` drains. The
root model owns cancellation: switching subject or tab cancels the tails the
old view started, so a long session does not accumulate goroutines.

## 7. Testing

| Layer | Approach |
|---|---|
| `internal/vc` | in-process gRPC over `bufconn`, fake `Shell` + `ScheduleService`. No backend needed. Bulk of coverage. |
| `internal/logtail` | temp files; append, truncate, rotate, merge ordering |
| `internal/notify` | interface substitution; no OS calls in tests |
| `internal/cli/output` | golden files for both table and `--json` |
| `internal/tui` | `Update(msg) → (model, cmd)` tables; no terminal |
| `internal/tui/keymap` | assert no duplicate key within a context; every binding reachable |
| `backend/kernel` | rotation and spawn-writes-to-file table tests |

TDD throughout: test first, watch it fail, then implement.

## 8. Build integration

```
just cli-build     # -> bin/vibecare
just cli-run       # go run
just cli-test
just cli-install   # into PATH
```

`just test` gains the new module. `just build-plugins` is untouched.

## 9. Non-goals for v1

- Creating, editing, or deleting schedules, routines, or actions. These need
  form UI and RRule input; they deserve their own design.
- Profile management.
- Non-localhost targets, TLS, or auth beyond the kernel token.
- Replacing the Swift client. This is a debugging and scripting tool.
