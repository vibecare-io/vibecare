package logtail

import (
	"context"
	"path/filepath"
	"sort"
	"testing"
	"time"
)

// bySource groups received lines by the source that produced them. Merge makes
// no promise about interleaving, so tests assert per-source order only.
func bySource(lines []Line) map[string][]string {
	out := map[string][]string{}
	for _, ln := range lines {
		out[ln.Source] = append(out[ln.Source], ln.Text)
	}
	return out
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestMergeFansInWithSources(t *testing.T) {
	dir := t.TempDir()
	core := filepath.Join(dir, "core.log")
	todo := filepath.Join(dir, "todo.log")
	write(t, core, "core-1\ncore-2\n")
	write(t, todo, "todo-1\n")

	ch, err := Merge(context.Background(), []Source{
		{ID: "core", Path: core},
		{ID: "todo", Path: todo},
	}, Options{Tail: -1})
	if err != nil {
		t.Fatalf("Merge: %v", err)
	}

	got := bySource(drainClosed(t, ch))
	if !equal(got["core"], []string{"core-1", "core-2"}) {
		t.Fatalf("core lines = %q", got["core"])
	}
	if !equal(got["todo"], []string{"todo-1"}) {
		t.Fatalf("todo lines = %q", got["todo"])
	}
}

func TestMergeFollowsEverySource(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	dir := t.TempDir()
	a := filepath.Join(dir, "a.log")
	b := filepath.Join(dir, "b.log")
	write(t, a, "")
	write(t, b, "")

	ch, err := Merge(ctx, []Source{{ID: "a", Path: a}, {ID: "b", Path: b}}, Options{Follow: true})
	if err != nil {
		t.Fatalf("Merge: %v", err)
	}

	appendTo(t, a, "from-a\n")
	appendTo(t, b, "from-b\n")

	var seen []string
	for range 2 {
		ln := recvLine(t, ch)
		seen = append(seen, ln.Source+":"+ln.Text)
	}
	sort.Strings(seen)
	if !equal(seen, []string{"a:from-a", "b:from-b"}) {
		t.Fatalf("seen = %q", seen)
	}
}

// A plugin that has never run has no log file. `logs --all` must show the
// sources that do exist rather than failing outright.
func TestMergeSkipsUnreadableSources(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good.log")
	write(t, good, "here\n")

	ch, err := Merge(context.Background(), []Source{
		{ID: "ghost", Path: filepath.Join(dir, "ghost.log")},
		{ID: "good", Path: good},
	}, Options{Tail: -1})
	if err != nil {
		t.Fatalf("Merge: %v", err)
	}
	expectTexts(t, ch, "here")
}

// Nothing readable at all is a real failure, and the caller deserves to know
// why rather than watching an empty stream.
func TestMergeFailsWhenNoSourceOpens(t *testing.T) {
	dir := t.TempDir()
	_, err := Merge(context.Background(), []Source{
		{ID: "ghost", Path: filepath.Join(dir, "ghost.log")},
	}, Options{Tail: -1})
	if err == nil {
		t.Fatal("Merge with only missing sources = nil error; want an error")
	}
}

func TestMergeWithNoSourcesClosesImmediately(t *testing.T) {
	ch, err := Merge(context.Background(), nil, Options{Tail: -1})
	if err != nil {
		t.Fatalf("Merge: %v", err)
	}
	expectTexts(t, ch)
}

func TestMergeClosesChannelOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	dir := t.TempDir()
	a := filepath.Join(dir, "a.log")
	write(t, a, "x\n")

	ch, err := Merge(ctx, []Source{{ID: "a", Path: a}}, Options{Follow: true, Tail: 1})
	if err != nil {
		t.Fatalf("Merge: %v", err)
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
