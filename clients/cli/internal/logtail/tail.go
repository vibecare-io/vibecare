// Package logtail follows plain text files the way `tail -F` does: last N
// lines first, then appended lines, across truncation and rotation.
//
// It knows nothing about VibeCare. Plugin output is "diagnostic only; never
// parsed" (backend/kernel/supervisor.go), so nothing here inspects a line
// beyond finding its newline.
package logtail

import (
	"bytes"
	"context"
	"io"
	"os"
	"time"
)

// pollInterval is how often a followed file is restatted. It is a var purely
// so tests can shrink it; polling is deliberate — fsnotify would add a
// dependency and a second set of platform behaviours to reason about, to save
// a stat every fifth of a second.
var pollInterval = 200 * time.Millisecond

// chunkSize bounds every read. The kernel caps a plugin log at 8 MiB per
// generation, so neither the backwards scan for the last N lines nor a catch-up
// read may size its buffer from the file.
const chunkSize = 64 << 10

// lineBuffer is how many lines may queue ahead of a slow consumer. A stalled
// TUI pane must not stall the goroutine reading the file, but it must not
// accumulate the file in memory either.
const lineBuffer = 256

// Line is one line of one source, with the time it was read. At is a receive
// timestamp, never a timestamp parsed out of the text.
type Line struct {
	Source string
	Text   string
	At     time.Time
}

// Options controls what Tail emits. Tail is the number of trailing lines to
// emit before following: 0 emits none, negative emits the whole file.
type Options struct {
	Follow bool
	Tail   int
}

// Tail streams path as source. Without Follow it emits the last Options.Tail
// lines and closes; a missing path is then an error, because there is nothing
// to wait for.
//
// With Follow it never closes until ctx is cancelled, and a missing path is
// not an error — a plugin that has never run has no log file, and the caller
// wants to see the first line it writes, not a failure.
func Tail(ctx context.Context, source, path string, o Options) (<-chan Line, error) {
	t := &tailer{source: source, path: path, out: make(chan Line, lineBuffer)}

	if !o.Follow {
		f, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		go func() {
			defer close(t.out)
			defer f.Close()
			t.f = f
			st, err := f.Stat()
			if err != nil {
				return
			}
			off, err := startOffset(f, st.Size(), o.Tail)
			if err != nil {
				return
			}
			t.off = off
			// flush: a one-shot read has no later chance to emit a final line
			// left unterminated by a crashed writer.
			_ = t.drain(ctx, st.Size(), true)
		}()
		return t.out, nil
	}

	// Attach before returning so the caller has a guarantee worth having:
	// anything written after Tail returns will be seen. Deferring the first
	// open to the polling goroutine would make Options.Tail race with the
	// writer over lines written in that window.
	t.open(o.Tail)
	go t.follow(ctx, o.Tail)
	return t.out, nil
}

type tailer struct {
	source string
	path   string
	out    chan Line

	f   *os.File
	off int64
	// opened records whether the first successful open already happened.
	opened bool
}

// open attaches to the path, reporting whether it succeeded. Options.Tail
// positions the offset on the first successful open only: a file opened after
// a rotation is read whole, since skipping its start would drop lines the
// caller never saw.
func (t *tailer) open(tailN int) bool {
	f, err := os.Open(t.path)
	if err != nil {
		return false
	}
	t.f = f
	t.off = 0
	if !t.opened {
		t.opened = true
		if st, err := f.Stat(); err == nil {
			if off, err := startOffset(f, st.Size(), tailN); err == nil {
				t.off = off
			}
		}
	}
	return true
}

func (t *tailer) follow(ctx context.Context, tailN int) {
	defer close(t.out)
	defer func() {
		if t.f != nil {
			t.f.Close()
		}
	}()

	tick := time.NewTicker(pollInterval)
	defer tick.Stop()
	for {
		if err := t.step(ctx, tailN); err != nil {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

// step catches up with the file, reopening it if it was rotated or truncated.
// The only error it reports is a cancelled context: a log that cannot be read
// right now is a condition to keep polling through, not to give up on.
func (t *tailer) step(ctx context.Context, tailN int) error {
	// Bounded rather than recursive: a writer rotating faster than we read
	// would otherwise keep us in this call indefinitely, and the next tick is
	// only a poll away.
	for range 4 {
		if t.f == nil && !t.open(tailN) {
			return nil // not there yet, or not readable yet
		}

		fst, err := t.f.Stat()
		if err != nil {
			return nil
		}
		if fst.Size() < t.off {
			// Truncated in place: same inode, fewer bytes. Whatever we had not
			// read is gone; start over rather than read from a stale offset.
			t.off = 0
		}
		if err := t.drain(ctx, fst.Size(), false); err != nil {
			return err
		}

		pst, err := os.Stat(t.path)
		if err != nil {
			// Renamed away with no replacement yet. Hold the open handle so
			// the old file's tail is still reachable next tick.
			return nil
		}
		if os.SameFile(fst, pst) {
			return nil
		}
		// Rotation: our handle now names <path>.1, which we just drained, so
		// switching to the fresh file loses nothing. Loop instead of waiting
		// for the next tick — the new file may already have content.
		t.f.Close()
		t.f = nil
	}
	return nil
}

// drain emits every complete line between t.off and size. A trailing fragment
// is left unread so a line still being written is not split in two; flush
// overrides that for a final read, where there will be no later chance.
func (t *tailer) drain(ctx context.Context, size int64, flush bool) error {
	buf := make([]byte, chunkSize)
	for t.off < size {
		n := size - t.off
		if n > chunkSize {
			n = chunkSize
		}
		// A short read or an error with bytes in hand is still progress; only
		// a zero-byte read means there is nothing to do until the next tick.
		r, _ := t.f.ReadAt(buf[:n], t.off)
		if r == 0 {
			return nil
		}
		chunk := buf[:r]

		if cut := bytes.LastIndexByte(chunk, '\n'); cut >= 0 {
			if err := t.emitBlock(ctx, chunk[:cut]); err != nil {
				return err
			}
			t.off += int64(cut) + 1
			continue
		}
		if int64(r) < chunkSize && !flush {
			return nil // an incomplete line; wait for its newline
		}
		// Either a final unterminated line, or one longer than a chunk —
		// emitting a fragment beats stalling the tail forever.
		if err := t.emitLine(ctx, string(chunk)); err != nil {
			return err
		}
		t.off += int64(r)
	}
	return nil
}

// emitBlock emits a run of newline-terminated lines, the newlines already
// stripped by the caller's slice bounds.
func (t *tailer) emitBlock(ctx context.Context, block []byte) error {
	for _, ln := range bytes.Split(block, []byte{'\n'}) {
		if err := t.emitLine(ctx, string(ln)); err != nil {
			return err
		}
	}
	return nil
}

func (t *tailer) emitLine(ctx context.Context, text string) error {
	select {
	case t.out <- Line{Source: t.source, Text: text, At: time.Now()}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// startOffset returns the byte offset at which the last n lines of a size-byte
// file begin: size for n == 0, 0 for n < 0. It scans backwards in chunks, so
// asking for three lines of an 8 MiB log reads a few kilobytes.
func startOffset(r io.ReaderAt, size int64, n int) (int64, error) {
	if n < 0 || size == 0 {
		return 0, nil
	}
	if n == 0 {
		return size, nil
	}

	end := size
	last := make([]byte, 1)
	if _, err := r.ReadAt(last, end-1); err != nil && err != io.EOF {
		return 0, err
	}
	if last[0] == '\n' {
		// The final newline terminates the last line rather than starting a
		// new empty one.
		end--
	}

	buf := make([]byte, chunkSize)
	found := 0
	for pos := end; pos > 0; {
		want := int64(chunkSize)
		if pos < want {
			want = pos
		}
		off := pos - want
		if _, err := r.ReadAt(buf[:want], off); err != nil && err != io.EOF {
			return 0, err
		}
		for i := int(want) - 1; i >= 0; i-- {
			if buf[i] != '\n' {
				continue
			}
			if found++; found == n {
				return off + int64(i) + 1, nil
			}
		}
		pos = off
	}
	return 0, nil
}
