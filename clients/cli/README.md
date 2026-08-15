# vibecare — terminal client

One Go binary that answers *"what is VibeCare doing right now, and why is it
broken"* without opening the Swift app.

It serves two audiences from one codebase:

- **A human debugging the stack.** `vibecare` with no arguments opens a
  full-screen TUI: plugin roster, live state, logs, alerts, schedules.
- **An agent or script.** Every read command takes `--json` against a stable,
  versioned schema, and every command exits with a meaningful code.

The binary is a **client**. It owns no state, no database and no scheduling
logic. Everything it shows comes from core over gRPC, from the kernel's HTTP
surface, or from log files on disk.

## Install

```bash
just cli-build      # -> bin/vibecare
just cli-install    # -> $GOBIN (or $GOPATH/bin)
just cli-run status # run without installing; arguments pass through
just cli-test
```

This directory is its own Go module, so `go build ./...` at the repo root does
not reach it. Build it from here, or use the recipes above.

## Connecting

| Target | Flag | Environment | Default |
|---|---|---|---|
| core gRPC | `--addr` | `VIBECARE_ADDR` | `127.0.0.1:50051` |
| core HTTP | `--web-addr` | `VIBECARE_WEB_ADDR` | `127.0.0.1:8080` |

The kernel's own HTTP port is **not** configurable and cannot be guessed — it
binds `127.0.0.1:0` on purpose. The client learns it from the `Shell.Plugins`
stream, which is the designed path.

**A dead core is a state, not an error.** `status` reports it and exits 2 but
still prints everything it could learn. `logs` reads files and keeps working —
which is exactly when a crashed plugin's last words are worth the most. The TUI
holds last-known values, marks them stale and reconnects on its own.

## Global flags

Available on every command:

```
--addr string       core gRPC address
--web-addr string   core HTTP address
--json              emit the versioned JSON contract instead of tables
--no-color          disable colour (NO_COLOR is honoured too)
-v, --verbose       explain what the client is doing, on stderr
```

## Commands

### status

Is core up, which build, is the scheduler running, how many plugins are
healthy. The first question, and the only command whose failure is still a
useful answer.

```console
$ vibecare status
addr       127.0.0.1:50051
core       reachable
version    0.4.1
kernel     http://127.0.0.1:53417
scheduler  running
plugins    3 total, 2 up, 1 failed
```

```console
$ vibecare status
addr       127.0.0.1:1
core       unreachable: connection failed
version    unknown
kernel     unknown
scheduler  unknown
plugins    none
error: core unreachable at 127.0.0.1:1: connection failed
$ echo $?
2
```

### plugins

The roster core streams, enriched with the kernel's own per-process numbers.

```console
$ vibecare plugins
ID         NAME       STATE  PID    UPTIME  RESTARTS  PROBE  EVENTS
todo       Todo       UP     40122  2h14m   0         3ms    18/18
vibecheck  VibeCheck  UP     40123  2h14m   1         7ms    204/204
```

When the kernel's HTTP surface is unreachable the roster still lists every
plugin and its state, but the numeric columns render as `—`. That is
deliberate: `0 restarts` and *we never measured* are different facts, and the
client will not fabricate the first.

```bash
vibecare plugins restart vibecheck
```

### logs

Reads files on disk, so it works with core down.

```bash
vibecare logs core                # last 200 lines of core's log
vibecare logs vibecheck -f        # follow one plugin
vibecare logs todo -n 2000        # more history; -n -1 means the whole file
vibecare logs --all -f            # every source, merged and id-prefixed
```

```console
$ vibecare logs --all -f
core       starting kernel on 127.0.0.1:53417
core       plugin spawned id=vibecheck pid=40123
vibecheck  detector started
vibecheck  publish vibecheck.bfrb.detected
```

Only `--all` prefixes: with a single source the id would be noise on every
line. Output is column-padded with two spaces and never boxed, so it survives
being piped into `awk` and `cut`.

Core's log is `~/.vibecare/logs/server.log`. A plugin's path comes from the
kernel's `log_path` field, never reconstructed from a convention — so the
convention can change without breaking this client.

### schedules

```bash
vibecare schedules ls
vibecare schedules ls --routine <routine-id> --enabled
vibecare schedules show <id>          # detail plus the actions it runs
vibecare schedules pause <id>
vibecare schedules resume <id>
vibecare schedules pause --all        # every schedule, in every profile
vibecare schedules resume --all
```

```console
$ vibecare schedules ls
ID        NAME             ENABLED  RRULE                 NEXT    LAST
sch_9f2a  Morning stretch  yes      FREQ=DAILY;BYHOUR=8   in 12m  22h ago
sch_1c04  Weekly review    no       FREQ=WEEKLY;BYDAY=FR  —       —
```

A schedule that has never run shows `—`, not a date near the epoch. The
recurrence rule is cut to fit the terminal; `schedules show` and `--json` both
carry it in full.

### alerts

Follows the UI intents plugins push through core. They are transient — core
stores none of them — so this shows what arrives while it is running, and
nothing from before.

```bash
vibecare alerts             # what is in flight, then exit
vibecare alerts -f          # stream until interrupted
vibecare alerts -f --notify # also raise a desktop notification
```

```console
$ vibecare alerts -f
12:04:09  vibecheck  warn  Nail biting detected — 4th time this hour
12:31:47  todo  info  3 tasks due today [Open]
```

One greppable line each: local wall-clock time, plugin, level, title, then
`— body` and any action labels. Wall-clock and not a relative offset, because
alerts arrive while you are watching — the question is *when*, not *how long
ago*. An action's URL is plugin-relative and meaningless without the kernel's
ephemeral origin, so only the label is shown; `--json` carries the URL.

`-f` reconnects on its own across a core restart. Under `--json` each alert
leaves as its own envelope, one per line: a stream has no end, so there is no
array for a consumer to wait on.

### routines and actions

```bash
vibecare routines ls [--profile <id>]
vibecare routines show <id>       # the actions, in the order they run
vibecare routines run <id>        # execute now
vibecare routines logs <id>       # recent executions

vibecare actions ls [--profile <id>]
vibecare actions show <id>        # with its parameters
vibecare actions run <id>
vibecare actions types            # the action types core accepts
```

There is deliberately no `--type` filter on `actions ls`: the list is small,
`grep` filters better, and the legal values live in a `.proto` the user cannot
see. `actions types` prints them instead.

Creating, editing and deleting schedules, routines and actions is out of scope
for v1 — those need form UI and RRule input.

## The `--json` contract

`--json` is a **stable, versioned contract**, not best-effort pretty-printing,
because agents depend on the field names.

Every payload is a single object carrying a version:

```console
$ vibecare status --json
{
  "v": 1,
  "data": {
    "addr": "127.0.0.1:50051",
    "reachable": true,
    "version": "0.4.1",
    "kernel_base_url": "http://127.0.0.1:53417",
    "scheduler": { "running": true },
    "plugins": { "total": 3, "up": 2, "degraded": 0, "down": 0, "failed": 1, "starting": 0 }
  }
}
```

Errors are JSON too — on **stderr**, with the exit code repeated in the body,
so a consumer never has to parse the exit status out of prose:

```console
$ vibecare status --json 2>&1 >/dev/null
{
  "v": 1,
  "error": {
    "code": 2,
    "message": "core unreachable at 127.0.0.1:1: connection failed"
  }
}
```

### Stability rules

- Every payload is one JSON object with a `"v"` field. It is `1` today.
- **Adding** a field is always allowed and is not a breaking change. Consumers
  must ignore fields they do not know.
- **Renaming or removing** a field requires bumping `"v"`.
- Field names are `snake_case` and match the kernel's existing
  `/_core/api/plugins` names wherever the data is the same, so a reader that
  knows one knows the other.
- Timestamps are RFC 3339 in UTC. Durations are integer seconds with an `_sec`
  suffix.
- Empty collections serialize as `[]`, never `null`.
- A timestamp core never set is **absent**, never a zero date.
- Numeric plugin stats are meaningful only when `"stats": true`. When it is
  false the kernel's HTTP surface was unreachable and every number is a zero
  value, not a measurement.

The contract lives in `internal/vc/types.go` — the struct tags *are* the
schema. Golden-file tests lock it down, so changing a golden file is the review
signal that a contract changed.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | general error |
| 2 | core unreachable |
| 3 | not found |
| 4 | invalid arguments |

```bash
if ! vibecare status --json >/tmp/s.json 2>/tmp/e.json; then
  case $? in
    2) echo "core is down" ;;
    *) jq -r .error.message /tmp/e.json ;;
  esac
fi
```

## TUI

Running `vibecare` with no subcommand opens the full-screen client. (`--json`
is rejected there — it has no meaning for an interactive program.)

```
┌──────────────┬──────────────────────────────────────────────────────────┐
│ ▸ ALL        │  Overview │ Logs │ Events │ Manifest │ Stats   vibecheck  │
│   core       │            ─────                                         │
│ ◆ vibecheck  │  follow:●  tail:500                                      │
│   todo       │   all    core   vibecheck   todo                         │
│              │                                                          │
│              │  vibecheck │ 12:04:01  detector started                  │
│              │  core      │ 12:04:02  plugin spawned pid=40122          │
└──────────────┴──────────────────────────────────────────────────────────┘
```

The **sidebar selects the subject**: `ALL`, `core`, then one row per plugin.
The bullet carries state colour — `◆` up, `◇` degraded, `○` down or failed — so
the sidebar alone answers "is anything broken".

**Tabs are facets of the selected subject** and change with it. The chip row
below them holds the active tab's controls.

`space` opens a which-key popup whose contents depend on the focused pane and
the selected subject. The footer, that popup and `?` all render from the same
tables in `internal/tui/keymap`, so a binding is declared exactly once and the
three surfaces cannot disagree.

### Key reference

The tables below are generated from `internal/tui/keymap`. To regenerate after
a rebind:

```bash
go test ./internal/tui/keymap -update
```

<!-- BEGIN GENERATED KEYS -->

#### Always available

| Key | Action |
|---|---|
| `/` | search |
| `n` | next match |
| `g` | goto subject |
| `a` | action log |
| `space` | actions |
| `?` | help |
| `esc` | back to list |
| `q` | quit |

#### Movement — subject list focused

`tab` crosses into the panel; `esc` comes back.

| Key | Action |
|---|---|
| `j/↓` | next subject |
| `k/↑` | prev subject |
| `[` | prev subject |
| `]` | next subject |
| `tab/l/→` | focus panel |
| `z` | zoom |

#### Movement — panel focused

| Key | Action |
|---|---|
| `h/←` | prev tab |
| `l/→` | next tab |
| `j/↓` | down |
| `k/↑` | up |
| `[` | prev subject |
| `]` | next subject |
| `tab` | focus list |
| `z` | zoom |

#### Acting on the selected subject

| Subject | Key | Action |
|---|---|---|
| all | `r` | refresh |
| core | `r` | refresh |
| core | `v` | version |
| plugin | `r` | restart |
| plugin | `d` | data dir |
| plugin | `u` | open ui |

#### Tabs

Digits jump straight to a tab; the strip changes with the subject.

| Subject | Tabs |
|---|---|
| all | `1` Overview · `2` Watch · `3` Logs · `4` Alerts · `5` Schedules · `6` Routines |
| core | `1` Status · `2` Logs · `3` Schedules · `4` Routines · `5` Actions |
| plugin | `1` Overview · `2` Logs · `3` Events · `4` Manifest · `5` Stats |

#### Pane controls

| Pane | Key | Action |
|---|---|---|
| overview | `⏎` | open |
| overview | `y` | copy |
| status | `y` | copy |
| logs | `f` | follow |
| logs | `t` | tail |
| logs | `s` | since |
| logs | `w` | wrap |
| logs | `c` | clear |
| logs | `y` | copy line |
| logs | `Y` | copy all |
| events | `f` | follow |
| events | `c` | clear |
| events | `y` | copy |
| alerts | `f` | follow |
| alerts | `c` | clear |
| alerts | `m` | mute desktop |
| alerts | `y` | copy |
| schedules | `⏎` | show |
| schedules | `p` | pause |
| schedules | `P` | pause all |
| schedules | `e` | resume |
| schedules | `E` | resume all |
| routines | `⏎` | show |
| routines | `x` | run |
| routines | `e` | run log |
| actions | `⏎` | show |
| actions | `x` | run |
| actions | `t` | types |
| manifest | `y` | copy |
| manifest | `o` | open file |
| stats | `y` | copy |

<!-- END GENERATED KEYS -->

## Layout

```
internal/vc       transport + domain. The ONLY package that talks to core.
internal/cli      cobra commands + printers. Calls vc, formats, exits.
internal/tui      bubbletea models. Calls vc from cmds.go, nowhere else.
internal/logtail  follow a file across rotation; merge N sources
internal/notify   Notifier interface + per-platform implementations
```

Two rules hold it together, both mechanically checkable:

1. **One pane per file**, named `pane_<name>.go`. A pane that outgrows its file
   is a pane doing too much.
2. **`cmds.go` is the only file in `internal/tui` that imports `internal/vc`.**
   Everything else is pure `Update(msg) → (model, cmd)`, which is why the TUI
   is testable without a terminal.

## Tests

```bash
just cli-test    # or: go test ./...
```

The whole suite runs with **no backend, no database and no plugins**:
`internal/vc` is exercised against an in-process gRPC server over `bufconn`
with fake `Shell` and `ScheduleService` implementations.

See [`docs/superpowers/specs/2026-08-14-vibecare-cli-design.md`](../../docs/superpowers/specs/2026-08-14-vibecare-cli-design.md)
for the full design.
