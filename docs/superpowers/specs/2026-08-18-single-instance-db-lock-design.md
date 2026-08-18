# One Server Per Database

**Status:** design, approved for implementation
**Date:** 2026-08-18
**Motivated by:** a scheduler bug that was fixed, then kept coming back

---

## 1. What this builds

An advisory lock on the database file, taken by `vibecare-server` at startup. A second
server pointed at the same database refuses to start, names the process holding it, and
exits non-zero.

Roughly sixty lines in `backend/internal/storage/`, eight in `cmd/server/main.go`.

---

## 2. The incident

A `FREQ=MINUTELY;INTERVAL=20` schedule reported its next run 1h54m out. The cause was
found and fixed, the fix merged, the server restarted — and the schedule went back to
firing once a day.

The fix was working. Four backends were running:

| PID | Built | Ports | Has the fix |
|---|---|---|---|
| 97529 | Aug 16 | 50051 / 8080 | yes |
| 4399 | Aug 14 | 50152 / 8099 | no |
| 11873 | Aug 14 | 50199 / 8097 | no |
| 61817 | Aug 14 | 50161 / 8096 | no |

All four had `~/.vibecare/vibecare.db` open. All four ran a scheduler loop on a ten-second
tick. `next_execution` is rewritten by whichever process dispatches first, so the column
was decided by a race between four processes running two different versions of the
calculation. The log shows the fixed server holding a clean twenty-minute cadence
(22:09, 22:29, 22:49, 23:09) until a stale one won a tick and wrote a value a day out.

The three stale servers were started by hand during unrelated plugin work, on spare ports
so they would not collide with the real one. Their parent shells exited; they were
reparented to launchd and ran for four days.

---

## 3. Why nothing caught it

`main.go` fatals if `net.Listen` on the gRPC port fails, so a second server on the
**default** port dies immediately. That is the only singleton guard in the process, and
`--port` walks straight past it — which is exactly what the stale servers were given.

The database imposes no guard of its own. It is opened `_journal_mode=WAL` with
`_busy_timeout=5000`, so SQLite serialises writers per transaction and lets any number of
processes share the file without an error. Correct for its purpose; silent for ours.

The guard belongs on the resource being contended. That resource is the database, not the
port.

---

## 4. Mechanism

`flock(2)` with `LOCK_EX|LOCK_NB` on a sidecar file, `<dbPath>.lock`.

**The kernel releases it when the process dies** — including `kill -9`, a panic, or a
crash — so there is no stale lock to detect, expire, or clean up. That property decides
the design. The processes in §2 had been orphaned for four days; any scheme that records
a PID and asks "is that still alive?" has to answer for reused PIDs and for the window
between a crash and the next startup. flock has no such window.

After acquiring, the holder truncates the file and writes its own PID. That content is
advisory — used only to name the holder in an error message, never to decide whether the
lock is held. The lock is the kernel's; the PID is a courtesy to whoever reads the error.

Alternatives considered:

| Approach | Rejected because |
|---|---|
| PID file with liveness check | Stale PIDs after a crash; PID reuse; races between check and write |
| `BEGIN EXCLUSIVE` held open | Blocks every other writer including `just inspect-db`, and fights WAL |
| Bind a second sentinel port | Same flaw as today: a flag moves the port and the guard evaporates |
| Lock the database file itself | SQLite owns that file's locking; a second scheme on it invites deadlock |

---

## 5. Contract

```go
// storage/dblock.go
func AcquireDBLock(dbPath string) (*DBLock, error)
func (l *DBLock) Release() error

type ErrLocked struct {
    Path      string
    HolderPID int  // 0 when the holder's PID could not be read
}
```

`AcquireDBLock` returns `*ErrLocked` when another process holds the lock, and an ordinary
error if the lock file cannot be created or locked for any other reason. `Release` is
idempotent and safe to `defer`.

**Placement.** `cmd/server/main.go`, immediately *before* `storage.New(*dbPath)`. Taking
it first also stops two servers from running goose migrations concurrently.

Deliberately **not** inside `storage.New`. Tests construct databases constantly, and a
future read-only tool should not have to defeat a lock meant for the scheduler. The
server owns the singleton, so the server takes the lock.

**On conflict**, `logger.Fatal` with a message that says what to do:

```
another vibecare-server (pid 4399) already has /Users/x/.vibecare/vibecare.db open
 - stop it, or run with --db <other path>
```

**Lock file lifecycle.** Created `0644` beside the database, never deleted. Deleting it on
release would race: a second process can be holding the deleted inode's lock while a third
creates a fresh file and locks that instead. A zero-cost empty file is the cheaper answer.

Relative paths, `..`, and symlinks need no normalisation — `flock` locks an inode, and
every spelling of the same path resolves to the same one. Two *hardlinks* to one database
would evade the lock; that is a known limit, not worth code.

---

## 6. What stays unguarded, on purpose

- **Readers.** `just inspect-db`, `sqlite3`, litecli. They never take the lock and are
  never refused.
- **Tests.** `storage.New` is untouched, so every test that builds a database in a temp
  directory behaves exactly as before.
- **A deliberate second instance.** `--db /tmp/scratch.db` locks its own path and starts
  normally. That is the supported way to run a server beside a live one, and it is what
  the stale servers in §2 should have been given.

No override flag. An `--allow-multiple-instances` escape hatch would be pasted into a
script once and reproduce this incident with the guard still nominally in place.

---

## 7. Portability

`dblock_unix.go` (`//go:build !windows`) carries the real implementation.
`dblock_windows.go` is a documented no-op that always succeeds — the backend has no
Windows build today, and a stub keeps the package compiling if one appears. When Windows
becomes real, `LockFileEx` is the equivalent and this is the only file that changes.

---

## 8. Testing

`backend/internal/storage/dblock_test.go`:

| Test | Proves |
|---|---|
| Second acquire on the same path fails with `*ErrLocked` | The guard guards |
| The error carries the holder's PID | The message can name a process to kill |
| Acquire, release, acquire again | Release actually releases |
| Two different paths | Per-database, not global |
| **A child process holds it; the parent is refused** | It works across processes, which is the whole point |
| **`kill -9` the child, then acquire** | A crashed holder leaves nothing behind |

The last two spawn a real subprocess via the `TestHelperProcess` re-exec pattern. They are
the tests that matter: the in-process cases would also pass under a POSIX `fcntl` lock,
which silently grants the second acquire to the same process and would have been useless
here.

---

## 9. What this does not fix

Two servers on two *different* databases still both run schedulers, and both still fire
notifications. Nothing in this design addresses that, and nothing needs to: they are not
racing over shared rows.

The orphaning itself is also untouched — killing a `go run` parent still leaves the child
running. This design makes the consequence loud rather than preventing the cause.
