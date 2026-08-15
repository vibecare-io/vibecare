package logtail

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// TestMain shrinks the poll interval for every test in the package. The
// 200ms production value is a battery-life choice, not a correctness one.
func TestMain(m *testing.M) {
	pollInterval = 5 * time.Millisecond
	os.Exit(m.Run())
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func appendTo(t *testing.T, path, content string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o600)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	if _, err := f.WriteString(content); err != nil {
		t.Fatalf("append %s: %v", path, err)
	}
	f.Close()
}

// recvLine waits for one line, failing rather than hanging the suite.
func recvLine(t *testing.T, ch <-chan Line) Line {
	t.Helper()
	select {
	case ln, ok := <-ch:
		if !ok {
			t.Fatal("channel closed while waiting for a line")
		}
		return ln
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for a line")
		return Line{}
	}
}

// drainClosed collects every line until the channel closes.
func drainClosed(t *testing.T, ch <-chan Line) []Line {
	t.Helper()
	var got []Line
	deadline := time.After(2 * time.Second)
	for {
		select {
		case ln, ok := <-ch:
			if !ok {
				return got
			}
			got = append(got, ln)
		case <-deadline:
			t.Fatalf("timed out waiting for close; got %v", texts(got))
			return nil
		}
	}
}

func texts(lines []Line) []string {
	out := make([]string, len(lines))
	for i, ln := range lines {
		out[i] = ln.Text
	}
	return out
}

func expectTexts(t *testing.T, ch <-chan Line, want ...string) {
	t.Helper()
	got := texts(drainClosed(t, ch))
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("lines = %q; want %q", got, want)
	}
}

func TestTailLastNLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.log")
	write(t, path, "one\ntwo\nthree\nfour\nfive\n")

	ch, err := Tail(context.Background(), "a", path, Options{Tail: 2})
	if err != nil {
		t.Fatalf("Tail: %v", err)
	}
	expectTexts(t, ch, "four", "five")
}

func TestTailZeroLinesEmitsNothing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.log")
	write(t, path, "one\ntwo\n")

	ch, err := Tail(context.Background(), "a", path, Options{Tail: 0})
	if err != nil {
		t.Fatalf("Tail: %v", err)
	}
	expectTexts(t, ch)
}

func TestTailNegativeEmitsWholeFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.log")
	write(t, path, "one\ntwo\nthree\n")

	ch, err := Tail(context.Background(), "a", path, Options{Tail: -1})
	if err != nil {
		t.Fatalf("Tail: %v", err)
	}
	expectTexts(t, ch, "one", "two", "three")
}

func TestTailNLargerThanFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.log")
	write(t, path, "one\ntwo\n")

	ch, err := Tail(context.Background(), "a", path, Options{Tail: 100})
	if err != nil {
		t.Fatalf("Tail: %v", err)
	}
	expectTexts(t, ch, "one", "two")
}

func TestTailEmptyFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.log")
	write(t, path, "")

	ch, err := Tail(context.Background(), "a", path, Options{Tail: 10})
	if err != nil {
		t.Fatalf("Tail: %v", err)
	}
	expectTexts(t, ch)
}

// A crashed writer leaves a final line with no newline. Reading the file once
// must still surface it — those are exactly the last words worth having.
func TestTailUnterminatedFinalLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.log")
	write(t, path, "one\ntwo")

	ch, err := Tail(context.Background(), "a", path, Options{Tail: -1})
	if err != nil {
		t.Fatalf("Tail: %v", err)
	}
	expectTexts(t, ch, "one", "two")
}

func TestTailCarriesSourceAndTime(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.log")
	write(t, path, "hello\n")

	ch, err := Tail(context.Background(), "vibecheck", path, Options{Tail: 1})
	if err != nil {
		t.Fatalf("Tail: %v", err)
	}
	ln := recvLine(t, ch)
	if ln.Source != "vibecheck" {
		t.Fatalf("Source = %q; want %q", ln.Source, "vibecheck")
	}
	if ln.At.IsZero() {
		t.Fatal("At is zero")
	}
}

func TestTailMissingFileWithoutFollowErrors(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nope.log")

	if _, err := Tail(context.Background(), "a", path, Options{Tail: 10}); err == nil {
		t.Fatal("Tail on a missing file = nil error; want an error")
	}
}

func TestFollowEmitsAppendedLines(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	path := filepath.Join(t.TempDir(), "a.log")
	write(t, path, "first\n")

	ch, err := Tail(ctx, "a", path, Options{Follow: true, Tail: 1})
	if err != nil {
		t.Fatalf("Tail: %v", err)
	}
	if ln := recvLine(t, ch); ln.Text != "first" {
		t.Fatalf("line = %q; want %q", ln.Text, "first")
	}

	appendTo(t, path, "second\nthird\n")
	if ln := recvLine(t, ch); ln.Text != "second" {
		t.Fatalf("line = %q; want %q", ln.Text, "second")
	}
	if ln := recvLine(t, ch); ln.Text != "third" {
		t.Fatalf("line = %q; want %q", ln.Text, "third")
	}

	cancel()
	drainClosed(t, ch)
}

// A half-written line must not be emitted twice, once as a fragment and once
// whole.
func TestFollowWaitsForCompleteLine(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	path := filepath.Join(t.TempDir(), "a.log")
	write(t, path, "")

	ch, err := Tail(ctx, "a", path, Options{Follow: true})
	if err != nil {
		t.Fatalf("Tail: %v", err)
	}

	appendTo(t, path, "par")
	select {
	case ln := <-ch:
		t.Fatalf("emitted fragment %q", ln.Text)
	case <-time.After(50 * time.Millisecond):
	}

	appendTo(t, path, "tial\n")
	if ln := recvLine(t, ch); ln.Text != "partial" {
		t.Fatalf("line = %q; want %q", ln.Text, "partial")
	}
}

func TestFollowSurvivesTruncation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	path := filepath.Join(t.TempDir(), "a.log")
	write(t, path, "before-a\nbefore-b\n")

	ch, err := Tail(ctx, "a", path, Options{Follow: true, Tail: -1})
	if err != nil {
		t.Fatalf("Tail: %v", err)
	}
	recvLine(t, ch)
	recvLine(t, ch)

	write(t, path, "after\n")
	if ln := recvLine(t, ch); ln.Text != "after" {
		t.Fatalf("line = %q; want %q", ln.Text, "after")
	}
}

// The kernel renames <id>.log to <id>.log.1 and opens a fresh <id>.log. The
// last lines written before the rename must still arrive.
func TestFollowSurvivesRotation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	dir := t.TempDir()
	path := filepath.Join(dir, "a.log")
	write(t, path, "old-first\n")

	ch, err := Tail(ctx, "a", path, Options{Follow: true, Tail: -1})
	if err != nil {
		t.Fatalf("Tail: %v", err)
	}
	if ln := recvLine(t, ch); ln.Text != "old-first" {
		t.Fatalf("line = %q; want %q", ln.Text, "old-first")
	}

	appendTo(t, path, "old-last\n")
	if err := os.Rename(path, path+".1"); err != nil {
		t.Fatalf("rename: %v", err)
	}
	write(t, path, "new-first\n")

	for _, want := range []string{"old-last", "new-first"} {
		if ln := recvLine(t, ch); ln.Text != want {
			t.Fatalf("line = %q; want %q", ln.Text, want)
		}
	}

	appendTo(t, path, "new-second\n")
	if ln := recvLine(t, ch); ln.Text != "new-second" {
		t.Fatalf("line = %q; want %q", ln.Text, "new-second")
	}
}

// A plugin that has never run has no log file. Following it is a wait, not an
// error.
func TestFollowWaitsForFileToAppear(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	path := filepath.Join(t.TempDir(), "later.log")

	ch, err := Tail(ctx, "a", path, Options{Follow: true, Tail: -1})
	if err != nil {
		t.Fatalf("Tail on a missing path with Follow = %v; want nil", err)
	}

	write(t, path, "born\n")
	if ln := recvLine(t, ch); ln.Text != "born" {
		t.Fatalf("line = %q; want %q", ln.Text, "born")
	}
}

func TestFollowClosesChannelOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	path := filepath.Join(t.TempDir(), "a.log")
	write(t, path, "x\n")

	ch, err := Tail(ctx, "a", path, Options{Follow: true, Tail: 1})
	if err != nil {
		t.Fatalf("Tail: %v", err)
	}
	recvLine(t, ch)
	cancel()

	select {
	case _, ok := <-ch:
		if ok {
			t.Fatal("received a line after cancel")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("channel not closed after cancel")
	}
}

// countingReaderAt reports how much of a file the last-N scan actually touched.
type countingReaderAt struct {
	r    io.ReaderAt
	read atomic.Int64
}

func (c *countingReaderAt) ReadAt(p []byte, off int64) (int, error) {
	n, err := c.r.ReadAt(p, off)
	c.read.Add(int64(n))
	return n, err
}

// The kernel caps a plugin's log at 8 MiB per generation. Reading its last few
// lines must not pull the whole thing through memory.
func TestStartOffsetReadsOnlyTheTail(t *testing.T) {
	var b bytes.Buffer
	for b.Len() < 2<<20 {
		b.WriteString("a line of plausible log output\n")
	}
	data := b.Bytes()
	c := &countingReaderAt{r: bytes.NewReader(data)}

	off, err := startOffset(c, int64(len(data)), 3)
	if err != nil {
		t.Fatalf("startOffset: %v", err)
	}
	tail := string(data[off:])
	if want := 3; strings.Count(tail, "\n") != want {
		t.Fatalf("tail has %d newlines; want %d", strings.Count(tail, "\n"), want)
	}
	if n := c.read.Load(); n > 256<<10 {
		t.Fatalf("read %d bytes to find the last 3 lines of a %d byte file", n, len(data))
	}
}

func TestStartOffsetEdges(t *testing.T) {
	data := []byte("one\ntwo\nthree\n")
	size := int64(len(data))
	r := bytes.NewReader(data)

	for _, tc := range []struct {
		name string
		n    int
		want string
	}{
		{"all", -1, "one\ntwo\nthree\n"},
		{"none", 0, ""},
		{"one", 1, "three\n"},
		{"more than there are", 9, "one\ntwo\nthree\n"},
	} {
		off, err := startOffset(r, size, tc.n)
		if err != nil {
			t.Fatalf("%s: startOffset: %v", tc.name, err)
		}
		if got := string(data[off:]); got != tc.want {
			t.Fatalf("%s: tail = %q; want %q", tc.name, got, tc.want)
		}
	}
}
