package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/vibecare-io/vibecare/clients/cli/internal/cli/output"
	"github.com/vibecare-io/vibecare/clients/cli/internal/logtail"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

func TestPrefixWidth(t *testing.T) {
	cases := []struct {
		name string
		in   []logtail.Source
		want int
	}{
		{"single source needs no prefix", []logtail.Source{{ID: "core"}}, 0},
		{"widest id wins", []logtail.Source{{ID: "core"}, {ID: "vibecheck"}, {ID: "todo"}}, len("vibecheck")},
		{"none", nil, 0},
	}
	for _, c := range cases {
		if got := prefixWidth(c.in); got != c.want {
			t.Errorf("%s: prefixWidth = %d, want %d", c.name, got, c.want)
		}
	}
}

func TestStreamLinesPrefixesAndAligns(t *testing.T) {
	var out bytes.Buffer
	p := output.New(&out, io.Discard, output.Table, false)

	ch := make(chan logtail.Line, 3)
	ch <- logtail.Line{Source: "core", Text: "plugin spawned pid=40122"}
	ch <- logtail.Line{Source: "vibecheck", Text: "detector started"}
	// A line carrying a percent verb must survive verbatim: log text is never
	// a format string.
	ch <- logtail.Line{Source: "todo", Text: "cpu 100%d busy"}
	close(ch)

	if err := streamLines(context.Background(), p, ch, prefixWidth([]logtail.Source{{ID: "core"}, {ID: "vibecheck"}, {ID: "todo"}})); err != nil {
		t.Fatalf("streamLines: %v", err)
	}

	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	want := []string{
		"core       plugin spawned pid=40122",
		"vibecheck  detector started",
		"todo       cpu 100%d busy",
	}
	if len(lines) != len(want) {
		t.Fatalf("got %d lines, want %d:\n%s", len(lines), len(want), out.String())
	}
	for i := range want {
		if lines[i] != want[i] {
			t.Errorf("line %d = %q, want %q", i, lines[i], want[i])
		}
	}
}

func TestStreamLinesSingleSourceHasNoPrefix(t *testing.T) {
	var out bytes.Buffer
	p := output.New(&out, io.Discard, output.Table, false)

	ch := make(chan logtail.Line, 1)
	ch <- logtail.Line{Source: "core", Text: "listening on :50051"}
	close(ch)

	if err := streamLines(context.Background(), p, ch, 0); err != nil {
		t.Fatalf("streamLines: %v", err)
	}
	if got := out.String(); got != "listening on :50051\n" {
		t.Errorf("out = %q, want the bare line", got)
	}
}

// A follow stream has no end, so --json emits one envelope per line rather
// than one array that would never be closed.
func TestStreamLinesJSONEmitsOneEnvelopePerLine(t *testing.T) {
	var out bytes.Buffer
	p := output.New(&out, io.Discard, output.JSON, false)

	at := time.Date(2026, 8, 14, 12, 4, 1, 0, time.UTC)
	ch := make(chan logtail.Line, 2)
	ch <- logtail.Line{Source: "core", Text: "one", At: at}
	ch <- logtail.Line{Source: "vibecheck", Text: "two", At: at}
	close(ch)

	if err := streamLines(context.Background(), p, ch, 9); err != nil {
		t.Fatalf("streamLines: %v", err)
	}

	dec := json.NewDecoder(strings.NewReader(out.String()))
	var got []vc.LogLine
	for {
		var env struct {
			V    int        `json:"v"`
			Data vc.LogLine `json:"data"`
		}
		err := dec.Decode(&env)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("decode: %v\n%s", err, out.String())
		}
		if env.V != vc.ContractVersion {
			t.Errorf("v = %d, want %d", env.V, vc.ContractVersion)
		}
		got = append(got, env.Data)
	}

	if len(got) != 2 {
		t.Fatalf("got %d envelopes, want 2:\n%s", len(got), out.String())
	}
	if got[0].Source != "core" || got[0].Text != "one" || !got[0].At.Equal(at) {
		t.Errorf("first line = %+v", got[0])
	}
	if got[1].Source != "vibecheck" || got[1].Text != "two" {
		t.Errorf("second line = %+v", got[1])
	}
	// The prefix is a table-mode affordance; it must never leak into the
	// machine contract.
	if strings.Contains(out.String(), "vibecheck  ") {
		t.Errorf("json output carries a table prefix:\n%s", out.String())
	}
}

func TestLogsNeedsASourceOrAll(t *testing.T) {
	_, _, code := capture(t, "--addr", deadAddr, "logs")
	if code != vc.ExitUsage {
		t.Fatalf("exit = %d, want %d", code, vc.ExitUsage)
	}
	_, _, code = capture(t, "--addr", deadAddr, "logs", "--all", "core")
	if code != vc.ExitUsage {
		t.Fatalf("exit with both an id and --all = %d, want %d", code, vc.ExitUsage)
	}
}

// Reading core's log is the one thing that must keep working when core is
// the thing that is broken.
func TestLogsCoreWithCoreDown(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	logDir := filepath.Join(home, ".vibecare", "logs")
	if err := os.MkdirAll(logDir, 0o700); err != nil {
		t.Fatal(err)
	}
	body := "first\nsecond\nthird\n"
	if err := os.WriteFile(filepath.Join(logDir, "server.log"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}

	out, errOut, code := capture(t, "--addr", deadAddr, "logs", "core", "-n", "2")
	if code != vc.ExitOK {
		t.Fatalf("exit = %d, want 0 (stderr: %s)", code, errOut)
	}
	if out != "second\nthird\n" {
		t.Errorf("out = %q, want the last two lines", out)
	}
}

func TestLogsUnknownPluginWithCoreDownReportsUnreachable(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	_, _, code := capture(t, "--addr", deadAddr, "logs", "nosuch")
	if code != vc.ExitUnreachable {
		t.Fatalf("exit = %d, want %d", code, vc.ExitUnreachable)
	}
}
