# VibeCare CLI & TUI — design

**Date:** 2026-08-14
**Status:** built. Updated 2026-08-15 to describe what exists rather than
what was proposed; §10 records where the two diverged and why.

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

Originally scoped as "persist plugin output, make the path discoverable,
**no new endpoints**". Two of those three held. The third did not survive
the Watch view (§6.4), which needs something no existing surface could
provide; §3.4 covers what was added and why it is on the kernel's
diagnostic plane rather than the client contract.

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
- `PluginStat` gains `LogPath`, `Dir` and `Build`.
- `statusPluginJSON` gains `log_path`, `dir` and `build`.

The client reads these from the JSON rather than reconstructing them. The
conventions are documented but never hard-coded in the client, so changing
one later does not break it.

`Dir` and `Build` exist for `plugins rebuild` (§5, dev builds only).
`Manifest` gains an optional `build:` — the argv that rebuilds that plugin.
It is **declared rather than inferred**, and that is not ceremony: inferring
it is wrong in exactly the case that matters. `vibecheck` is Swift, embeds
`Info.plist` through `-sectcreate` linker flags, and must be codesigned
before macOS will show a camera prompt. A guessed `swift build` produces a
binary that starts and then silently has no camera — a multi-hour debugging
session caused by the tool meant to prevent them. Nothing in the kernel ever
executes this field.

### 3.3 Bus tap and the event stream

`Bus.Tap()` returns a channel carrying **every** published event, whether or
not any plugin subscribed to it. That difference is the whole point:
`Subscribe` answers "what am I meant to receive", `Tap` answers "what is
actually happening" — including a plugin publishing into a topic nobody
listens to, which from outside is indistinguishable from a broken plugin.

Taps are bounded and drop when full, on the same reasoning as `subChanCap`:
a diagnostic that can stall the system it observes is worse than none.
Sends happen under `b.mu` for the reason `deliver` documents — a
select-with-default guards a full channel, not a closed one.

`GET /_core/api/events` streams them as server-sent events: one-directional,
no negotiation, and no end (so not a JSON array). Payloads are forwarded as
opaque strings truncated at 2 KiB — core has no schema for them, and
decoding here would be core inventing meaning it does not have. An idle
stream is kept open by a comment heartbeat, because events are bursty and a
connection that dies during the quiet is one that is always dead exactly
when someone starts watching.

**This is deliberately not on the `Shell` gRPC contract.** Shell is frozen at
two RPCs so that clients contain no plugin-specific code, and a firehose of
arbitrary plugin topics is precisely what that freeze exists to keep out.
`/_core/*` is core's own diagnostic plane — it already serves the plugins
JSON and restart — and that is where a debugging surface belongs.

### 3.4 Tests

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
      events.go                # WatchEvents: the /_core/api/events SSE stream
      pluginurl.go             # authenticated plugin UI URL; PluginBuild
      wait.go                  # Backoff + DialWait, shared by both frontends
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
    browser/
      browser.go               # open a URL; argv per platform, never a shell
    plugbuild/
      plugbuild.go             # run a plugin's declared build argv (dev only)
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
      actionlog.go             # the "what have I done" strip
      rebuild_dev.go           # -tags dev: rebuild command seam
      rebuild_stub.go          # !dev: the same seam, doing nothing
      pane_overview.go
      pane_watch.go            # the bus firehose
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
vibecare plugins url <id>             authenticated URL of the plugin's UI
vibecare plugins open <id>            the same URL, handed to the browser
vibecare logs <id|core> [-f] [-n N]
vibecare logs --all [-f]              merged, source-prefixed
```

### Dev builds only

```
vibecare plugins rebuild <id> [--no-restart]
```

Runs the `build:` argv from the plugin's manifest in the plugin's own
directory, then restarts it and reports the state it **settled into** —
"restarted" is not the same as "running", and a plugin that builds cleanly
then dies on spawn would otherwise be reported as a success.

Compiled only under `-tags dev`, via a `rebuild_dev.go` / `rebuild_stub.go`
pair. A build tag rather than a hidden flag because the command runs a
program named by a file on disk, and the honest way to promise a shipped
client cannot do that is for the code not to be in it. `vibecare status`
reports which kind of binary you are holding.

The runner uses **argv, not a shell**: both real build commands are plain
argv, so `sh -c` buys nothing and costs the property worth having — a
manifest cannot become a pipeline or a `;rm -rf`.

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
| `ALL` | Overview · **Watch** · Logs · Alerts · Schedules · Routines |
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

### 6.4 Watch

`ALL → Watch` is the bus firehose (§3.4): every event any plugin publishes,
as it happens, including ones nothing subscribed to. It answers what the
logs pane cannot — a log says what a plugin chose to write down, this says
what it actually put on the wire.

Each row is `time · plugin · topic · payload`, and the topic is coloured by
a **hash of its name**, so one topic is the same colour in every session. A
palette handed out in arrival order would look identical and mean nothing;
the point is locking onto one topic in a fast stream without reading it.

Nothing is stored: core retains no events, so the view starts from the
moment it opens. That is deliberate rather than a gap — a replay buffer is
always the wrong size, and "make it happen again" is an honest instruction
for a debugging tool.

### 6.5 Focus

The layout has two halves and the keyboard drives one of them at a time.
Focus is a real dimension of the keymap rather than a special case in the
handlers, because the same key has to mean different things on each side:

| | Sidebar focused | Panel focused |
|---|---|---|
| `j` `k` `↓` `↑` | move subject | scroll the pane |
| `h` `←` / `l` `→` | — / enter panel | prev / next tab |
| `tab` | enter panel | back to the list |
| `esc` | — | back to the list |
| `[` `]` | prev / next subject | prev / next subject |

`keymap.Lookup/For/Footer` all take a `Focus`, so the footer, the transient
and `?` help always show the keys that work *right now*. `esc` keeps one
action deliberately — it closes whatever is open first and only then means
"leave the panel"; binding it twice would make it ambiguous exactly when
someone reaches for it to escape something.

The selected sidebar row is a solid full-width block (dark on bright), not
coloured text: a block is found by the eye without being read. It dims when
the panel has focus rather than disappearing, because losing your place is
worse than a slightly louder sidebar. A rule separates the two halves,
drawn from the sidebar's own width budget so the pane starts on the same
column whether or not it is there.

### 6.6 Action log

A strip above the footer records what this session has **done** — restarts,
opens, rebuilds — as opposed to what it has seen. Core's log says a plugin
restarted; only this says you are the one who restarted it, and when. `a`
expands it. It hangs off `NoticeMsg`, which is how every action already
reports itself, so a new action is recorded for free.

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
just cli-build      # -> bin/vibecare
just cli-build-dev  # same, with -tags dev (adds `plugins rebuild`)
just cli-run ARGS   # go run, arguments passed through
just tui            # build and open the TUI
just tui-dev        # build with -tags dev and open the TUI
just cli-test       # runs the suite twice, with and without -tags dev
just cli-install    # into $GOBIN
```

`just test` gains the new module. `just build-plugins` is untouched.

## 9. Non-goals for v1

- Creating, editing, or deleting schedules, routines, or actions. These need
  form UI and RRule input; they deserve their own design.
- Profile management.
- Non-localhost targets, TLS, or auth beyond the kernel token.
- Replacing the Swift client. This is a debugging and scripting tool.

## 10. Changes since the original design

Recorded because each of these was a belief that survived review and then
turned out to be false in practice. The corrections are worth more than the
original text was.

**"A roster arriving means core answered."** It does not. `vc.WatchRoster`
replays its cached roster to every new subscriber, so every reconnect
attempt receives one whether or not core is reachable. The model treated
that as recovery: it cleared the unreachable banner and reset the retry
counter roughly every two seconds while core was down, and the TUI spent
outages claiming a recovery it had never observed. Reachability now has
exactly one source of truth — `Status.Reachable` — and a roster is treated
as data, not liveness. A test asserted the old belief and had to be
inverted.

**"No new endpoints."** True for logs, false overall. The Watch view needs
events, no existing surface carries them, and `Shell` is frozen at two RPCs
by design. Resolving that tension is what put the firehose on `/_core/*`
rather than in the client contract (§3.4), which is a better answer than the
original constraint would have produced.

**"A dead core is a startup failure."** The TUI was handed a nil session and
came up completely inert — not crashing, just never issuing a command and
never noticing core arrive. It now dials on its own with exponential
backoff and recovers without a restart, which makes `just tui` in one pane
and `just run` in another a working order.

**The retry chain fired exactly once.** `RetryMsg` armed nothing, and
`lost()` would not re-arm because it saw `retrying` already true, so
reconnection silently fell back to a fixed 2 s poll with no backoff
anywhere. The backoff policy now lives in `vc.Backoff` and is shared by the
TUI's reconnect and the CLI's `--wait`, so the delay shown to the user is
the delay actually used.

**The transient was a key reference.** Filling it with movement and global
keys made it taller than the terminal, and it silently clipped the group
that mattered. It is now an *actions* menu: `keymap.For` is what the popup
offers, `keymap.All` is everything bound. A test asserts the popup is a
subset — it may decline to advertise a key, never offer one that does
nothing.

**A pane built mid-session started by lying.** Its zero `vc.Status` has
`Reachable: false`, so a freshly built pane did not stay quiet — it actively
reported core was down for up to a full poll interval. `retune` now seeds a
new pane with what the model already knows, guarded so it never replays a
zero status and recreates the bug.

**`u` (open plugin UI) was bound and never implemented.** It sat in the
tables from the start doing nothing — the failure a single source of truth
for keys exists to prevent, appearing on the handler side instead. There is
now a source-level test that every subject verb the transient advertises is
handled.

**Two things the kernel's own tests caught.** `TestKernelContainsNoProductNouns`
rejected product vocabulary in the new tap tests (rewritten with generic
ids), and the layering test in `internal/tui` rejected a `*vc.Session` field
on a message type in `msgs.go` (moved to `cmds.go`, which owns session
access). Both boundaries held without anyone having to remember them.

**Go version.** `go.mod` resolved to `go 1.25.0`, not the `1.23.0` the
backend uses — `go get` chose it and the charm dependencies want it. Worth
knowing if this is ever built on an older toolchain.
