package output

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// -update rewrites the golden files. Regenerating them is not a fix: the
// diff a regeneration produces IS the review signal that the output
// contract changed, so it belongs in the commit under human eyes.
var update = flag.Bool("update", false, "rewrite golden files")

func golden(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join("testdata", name)
	if *update {
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden (run with -update to create): %v", err)
	}
	if got != string(want) {
		t.Errorf("output does not match %s\n--- want ---\n%s\n--- got ---\n%s", path, want, got)
	}
}

// newTest builds a Printer over buffers with colour off, which is the only
// configuration golden files can be written against.
func newTest(f Format) (*Printer, *bytes.Buffer, *bytes.Buffer) {
	var out, errw bytes.Buffer
	return New(&out, &errw, f, false), &out, &errw
}

func TestTablePlugins(t *testing.T) {
	p, out, errw := newTest(Table)
	p.Table(
		[]string{"ID", "NAME", "STATE", "PID", "UPTIME", "RESTARTS"},
		[][]string{
			{"vibecheck", "VibeCheck", "UP", "40122", "2h14m", "0"},
			{"todo", "Todo", "DEGRADED", "40123", "11s", "3"},
			{"notes", "Notes", "FAILED", "-", "-", "5"},
		},
	)
	golden(t, "plugins_table.golden", out.String())
	if errw.Len() != 0 {
		t.Errorf("table wrote to stderr: %q", errw.String())
	}
}

func TestTableEmpty(t *testing.T) {
	p, out, _ := newTest(Table)
	p.Table([]string{"ID", "NAME", "STATE"}, nil)
	golden(t, "empty_table.golden", out.String())
}

// Column alignment must be computed in terminal cells, not bytes or runes:
// "日本語" is 9 bytes, 3 runes and 6 cells wide, and only the last is what
// the terminal draws.
func TestTableUnicodeWidth(t *testing.T) {
	p, out, _ := newTest(Table)
	p.Table(
		[]string{"ID", "NAME", "STATE"},
		[][]string{
			{"日本語", "Japanese", "UP"},
			{"emoji", "🎉 party", "DEGRADED"},
			{"café", "Café", "DOWN"},
		},
	)
	golden(t, "unicode_table.golden", out.String())
}

func TestKV(t *testing.T) {
	p, out, _ := newTest(Table)
	p.KV([][2]string{
		{"addr", "127.0.0.1:50051"},
		{"reachable", "true"},
		{"version", "0.4.2"},
		{"kernel", "http://127.0.0.1:53321"},
		{"scheduler", "running"},
	})
	golden(t, "kv.golden", out.String())
}

func TestJSONSuccess(t *testing.T) {
	p, out, errw := newTest(JSON)
	roster := vc.Roster{
		BaseURL: "http://127.0.0.1:53321",
		Plugins: []vc.Plugin{{
			ID:              "vibecheck",
			Name:            "VibeCheck",
			Icon:            "eye",
			Path:            "/Users/x/.vibecare/plugins-v2/vibecheck",
			UI:              "http",
			State:           vc.StateUp,
			Detail:          "probe ok",
			PID:             40122,
			UptimeSec:       8041,
			Restarts:        0,
			ProbeLatencyMS:  3,
			EventsPublished: 128,
			EventsDelivered: 127,
			LastEventUnix:   1786000000,
			LogPath:         "/Users/x/.vibecare/logs/vibecheck.log",
			Stats:           true,
		}},
	}
	if err := p.JSON(roster); err != nil {
		t.Fatalf("JSON: %v", err)
	}
	golden(t, "json_success.golden", out.String())
	if errw.Len() != 0 {
		t.Errorf("success payload leaked to stderr: %q", errw.String())
	}
}

func TestJSONError(t *testing.T) {
	p, out, errw := newTest(JSON)
	p.Err(vc.Unreachable("127.0.0.1:50051", errors.New("connection refused")))
	golden(t, "json_error.golden", errw.String())
	if out.Len() != 0 {
		t.Errorf("error leaked to stdout: %q", out.String())
	}
}

func TestErrTableMode(t *testing.T) {
	p, out, errw := newTest(Table)
	p.Err(vc.NotFound("schedule", "abc"))
	if got, want := errw.String(), "error: schedule \"abc\" not found\n"; got != want {
		t.Errorf("stderr = %q, want %q", got, want)
	}
	if out.Len() != 0 {
		t.Errorf("error leaked to stdout: %q", out.String())
	}
}

// The --json contract is "stdout is a single JSON object". Any human line a
// command emits alongside it would break every consumer, so the printer
// drops them rather than trusting each caller to remember.
func TestJSONModeSuppressesHumanOutput(t *testing.T) {
	p, out, errw := newTest(JSON)
	p.Table([]string{"ID"}, [][]string{{"todo"}})
	p.KV([][2]string{{"addr", "127.0.0.1:50051"}})
	p.Line("restarting %s", "todo")
	if out.Len() != 0 || errw.Len() != 0 {
		t.Errorf("human output emitted under --json: out=%q err=%q", out.String(), errw.String())
	}
}

func TestLine(t *testing.T) {
	p, out, _ := newTest(Table)
	p.Line("restarted %s (pid %d)", "todo", 40123)
	p.Line("already newline-terminated\n")
	if got, want := out.String(), "restarted todo (pid 40123)\nalready newline-terminated\n"; got != want {
		t.Errorf("stdout = %q, want %q", got, want)
	}
}

func TestIsJSON(t *testing.T) {
	if j, _, _ := newTest(JSON); !j.IsJSON() {
		t.Error("JSON format reports IsJSON false")
	}
	if tb, _, _ := newTest(Table); tb.IsJSON() {
		t.Error("Table format reports IsJSON true")
	}
}

func TestStatePlainWithoutColour(t *testing.T) {
	p, _, _ := newTest(Table)
	for _, s := range []vc.State{
		vc.StateStarting, vc.StateUp, vc.StateDegraded,
		vc.StateDown, vc.StateFailed, vc.StateUnknown,
	} {
		if got := p.State(s); got != string(s) {
			t.Errorf("State(%s) = %q, want unstyled %q", s, got, s)
		}
	}
	// A state the kernel gains before this client knows about it must still
	// print, not vanish.
	if got := p.State(vc.State("REHOMING")); got != "REHOMING" {
		t.Errorf("unknown state = %q", got)
	}
}

// Colour on plus a non-terminal writer must still yield plain bytes: that is
// lipgloss's own detection, and relying on it is what keeps piped output
// (`vibecare plugins | grep`) clean without every caller passing --no-color.
func TestStatePlainOnNonTTYEvenWithColour(t *testing.T) {
	var out, errw bytes.Buffer
	p := New(&out, &errw, Table, true)
	if got := p.State(vc.StateUp); got != "UP" {
		t.Errorf("State(UP) on non-tty = %q, want plain %q", got, "UP")
	}
	p.Table([]string{"ID"}, [][]string{{"todo"}})
	if got, want := out.String(), "ID\ntodo\n"; got != want {
		t.Errorf("table on non-tty = %q, want %q", got, want)
	}
}

// "Empty collections serialize as [], never null" is a contract clause, and
// it is a property of the value the caller hands over, not of the encoder.
// This pins both halves: an allocated empty slice is [], and the nil the
// caller must never pass is null.
func TestEmptySlicesSerializeAsArray(t *testing.T) {
	p, out, _ := newTest(JSON)
	if err := p.JSON(vc.Roster{Plugins: []vc.Plugin{}}); err != nil {
		t.Fatalf("JSON: %v", err)
	}
	if !strings.Contains(out.String(), `"plugins": []`) {
		t.Errorf("empty slice did not serialize as []:\n%s", out.String())
	}

	p2, out2, _ := newTest(JSON)
	if err := p2.JSON(vc.Roster{Plugins: nil}); err != nil {
		t.Fatalf("JSON: %v", err)
	}
	if !strings.Contains(out2.String(), `"plugins": null`) {
		t.Errorf("nil slice was expected to serialize as null (callers must not pass nil):\n%s", out2.String())
	}
}

// Every slice-bearing type on the contract behaves the same way, so the rule
// callers follow is one rule, not a per-type lookup.
func TestContractTypesRoundTripEmptySlices(t *testing.T) {
	cases := []struct {
		name  string
		value any
		field string
	}{
		{"roster", vc.Roster{Plugins: []vc.Plugin{}}, "plugins"},
		{"schedule_actions", vc.Schedule{ID: "s1", Actions: []vc.Action{}}, "actions"},
		{"routine_actions", vc.Routine{ID: "r1", Actions: []vc.Action{}}, "actions"},
		{"alert_actions", vc.Alert{Plugin: "todo", Actions: []vc.AlertAction{}}, "actions"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p, out, _ := newTest(JSON)
			if err := p.JSON(tc.value); err != nil {
				t.Fatalf("JSON: %v", err)
			}
			var env struct {
				V    int                        `json:"v"`
				Data map[string]json.RawMessage `json:"data"`
			}
			if err := json.Unmarshal(out.Bytes(), &env); err != nil {
				t.Fatalf("decode: %v", err)
			}
			if env.V != vc.ContractVersion {
				t.Errorf("v = %d, want %d", env.V, vc.ContractVersion)
			}
			// omitempty drops an empty slice entirely on some of these; what
			// must never happen is it surfacing as null.
			if raw, ok := env.Data[tc.field]; ok && string(raw) != "[]" {
				t.Errorf("%s = %s, want []", tc.field, raw)
			}
		})
	}
}

// Err must accept a plain error, not just *vc.Error, because anything the
// cobra layer catches gets funnelled here.
func TestErrJSONNonVCError(t *testing.T) {
	p, _, errw := newTest(JSON)
	p.Err(errors.New("boom"))
	var env vc.Envelope
	if err := json.Unmarshal(errw.Bytes(), &env); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if env.Err == nil {
		t.Fatal("no error body")
	}
	if env.Err.Code != vc.ExitError || env.Err.Message != "boom" {
		t.Errorf("error body = %+v", *env.Err)
	}
	if env.Data != nil {
		t.Errorf("data set on an error envelope: %v", env.Data)
	}
}

// Envelopes end in a newline so a terminal prompt lands on its own line and
// line-oriented consumers see a complete record.
func TestJSONEndsWithNewline(t *testing.T) {
	p, out, _ := newTest(JSON)
	if err := p.JSON(vc.Tally{Total: 1, Up: 1}); err != nil {
		t.Fatalf("JSON: %v", err)
	}
	if !strings.HasSuffix(out.String(), "}\n") {
		t.Errorf("payload does not end with a newline: %q", out.String())
	}
}
