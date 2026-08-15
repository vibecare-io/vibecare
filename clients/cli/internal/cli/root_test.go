package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/vibecare-io/vibecare/clients/cli/internal/cli/output"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// deadAddr is a port nothing listens on, so every test here exercises the
// no-backend path the suite is required to run in. Port 1 is privileged and
// refuses immediately, which keeps the dial from burning its timeout.
const deadAddr = "127.0.0.1:1"

// capture runs one argv through the real cobra tree with stdout and stderr
// redirected, and returns what the process would have printed and exited
// with. Flags are reset first: cobra keeps the value of a flag set by an
// earlier Execute, and a test that inherited --json from its neighbour is a
// test that proves nothing.
func capture(t *testing.T, args ...string) (stdoutText, stderrText string, code int) {
	t.Helper()

	var out, errOut bytes.Buffer
	prevOut, prevErr := stdout, stderr
	stdout, stderr = &out, &errOut
	resetFlags(rootCmd)
	t.Cleanup(func() {
		stdout, stderr = prevOut, prevErr
		resetFlags(rootCmd)
	})

	code = execute(context.Background(), args)
	return out.String(), errOut.String(), code
}

func resetFlags(c *cobra.Command) {
	c.Flags().VisitAll(func(f *pflag.Flag) { _ = f.Value.Set(f.DefValue) })
	for _, sub := range c.Commands() {
		resetFlags(sub)
	}
}

func TestExitCode(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want int
	}{
		{"success", nil, vc.ExitOK},
		{"command failure keeps its code", &commandError{vc.NotFound("plugin", "x")}, vc.ExitNotFound},
		{"unreachable", &commandError{vc.Unreachable(deadAddr, errors.New("refused"))}, vc.ExitUnreachable},
		{"plain command failure", &commandError{errors.New("boom")}, vc.ExitError},
		{"anything cobra returned is a usage error", errors.New("unknown command"), vc.ExitUsage},
	}
	for _, c := range cases {
		if got := exitCode(c.err); got != c.want {
			t.Errorf("%s: exitCode = %d, want %d", c.name, got, c.want)
		}
	}
}

func TestUnknownCommandIsUsageError(t *testing.T) {
	out, errOut, code := capture(t, "wibble")
	if code != vc.ExitUsage {
		t.Fatalf("exit = %d, want %d (stderr: %s)", code, vc.ExitUsage, errOut)
	}
	if !strings.Contains(errOut, "unknown command") {
		t.Errorf("stderr = %q, want it to name the unknown command", errOut)
	}
	if out != "" {
		t.Errorf("stdout = %q, want nothing: usage belongs on stderr", out)
	}
}

// Help was asked for, so it is the output the user wanted: it goes to stdout
// and exits 0. This is the one thing that reaches stdout without passing
// through a Printer, which is why it needs its own test — an earlier version
// discarded cobra's writer wholesale and silently printed nothing at all.
func TestHelpGoesToStdout(t *testing.T) {
	for _, args := range [][]string{
		{"--help"},
		{"help"},
		{"schedules", "--help"},
	} {
		out, errOut, code := capture(t, args...)
		if code != vc.ExitOK {
			t.Errorf("%v: exit = %d, want %d (stderr: %s)", args, code, vc.ExitOK, errOut)
		}
		if !strings.Contains(out, "Usage:") {
			t.Errorf("%v: stdout = %q, want usage text", args, out)
		}
	}
}

func TestMissingArgumentIsUsageError(t *testing.T) {
	_, errOut, code := capture(t, "plugins", "restart")
	if code != vc.ExitUsage {
		t.Fatalf("exit = %d, want %d (stderr: %s)", code, vc.ExitUsage, errOut)
	}
}

func TestGlobalFlagsParse(t *testing.T) {
	// deadAddr rather than an unroutable host: an unreachable target that
	// refuses immediately keeps this test fast, and the flag is parsed either
	// way.
	capture(t, "--addr", deadAddr, "--web-addr", "127.0.0.1:2", "--json", "--no-color", "-v", "status")
	if flagAddr != deadAddr || flagWebAddr != "127.0.0.1:2" {
		t.Errorf("addr = %q, web-addr = %q", flagAddr, flagWebAddr)
	}
	if !flagJSON || !flagNoColor || !flagVerbose {
		t.Errorf("json = %v, no-color = %v, verbose = %v", flagJSON, flagNoColor, flagVerbose)
	}
}

func TestStatusUnreachableStillPrints(t *testing.T) {
	out, _, code := capture(t, "--addr", deadAddr, "status")
	if code != vc.ExitUnreachable {
		t.Fatalf("exit = %d, want %d", code, vc.ExitUnreachable)
	}
	for _, want := range []string{"addr", deadAddr, "unreachable"} {
		if !strings.Contains(out, want) {
			t.Errorf("stdout missing %q:\n%s", want, out)
		}
	}
}

func TestStatusJSONUnreachable(t *testing.T) {
	out, errOut, code := capture(t, "--addr", deadAddr, "--json", "status")
	if code != vc.ExitUnreachable {
		t.Fatalf("exit = %d, want %d", code, vc.ExitUnreachable)
	}

	var env struct {
		V    int       `json:"v"`
		Data vc.Status `json:"data"`
	}
	if err := json.Unmarshal([]byte(out), &env); err != nil {
		t.Fatalf("stdout is not the payload envelope: %v\n%s", err, out)
	}
	if env.V != vc.ContractVersion {
		t.Errorf("v = %d, want %d", env.V, vc.ContractVersion)
	}
	if env.Data.Reachable || env.Data.Addr != deadAddr || env.Data.Error == "" {
		t.Errorf("status payload = %+v, want unreachable with an explanation", env.Data)
	}

	var errEnv vc.Envelope
	if err := json.Unmarshal([]byte(errOut), &errEnv); err != nil {
		t.Fatalf("stderr is not an error envelope: %v\n%s", err, errOut)
	}
	if errEnv.Err == nil || errEnv.Err.Code != vc.ExitUnreachable {
		t.Errorf("error envelope = %+v, want code %d", errEnv.Err, vc.ExitUnreachable)
	}
}

func TestCoreLine(t *testing.T) {
	cases := []struct {
		name string
		st   vc.Status
		want string
	}{
		{"up", vc.Status{Addr: deadAddr, Reachable: true}, "reachable"},
		{
			"the address is not repeated below itself",
			vc.Status{Addr: deadAddr, Error: "core unreachable at " + deadAddr + ": connection failed"},
			"unreachable: connection failed",
		},
		{"no cause", vc.Status{Addr: deadAddr}, "unreachable"},
		{"connected then dropped", vc.Status{Addr: deadAddr, Error: "grpc connection IDLE"}, "unreachable: grpc connection IDLE"},
	}
	for _, c := range cases {
		if got := coreLine(c.st); got != c.want {
			t.Errorf("%s: coreLine = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestPluginRowWithoutStatsRendersDashes(t *testing.T) {
	p := output.New(&bytes.Buffer{}, &bytes.Buffer{}, output.Table, false)
	row := pluginRow(p, vc.Plugin{ID: "todo", Name: "Todo", State: vc.StateUp})

	want := []string{"todo", "Todo", "UP", dash, dash, dash, dash, dash}
	if len(row) != len(want) {
		t.Fatalf("row has %d columns, want %d: %q", len(row), len(want), row)
	}
	for i := range want {
		if row[i] != want[i] {
			t.Errorf("column %d = %q, want %q", i, row[i], want[i])
		}
	}
}

func TestPluginRowWithStats(t *testing.T) {
	p := output.New(&bytes.Buffer{}, &bytes.Buffer{}, output.Table, false)
	row := pluginRow(p, vc.Plugin{
		ID: "vibecheck", Name: "VibeCheck", State: vc.StateDegraded,
		PID: 40122, UptimeSec: 3*3600 + 4*60, Restarts: 2,
		ProbeLatencyMS: 7, EventsPublished: 12, EventsDelivered: 9,
		Stats: true,
	})

	want := []string{"vibecheck", "VibeCheck", "DEGRADED", "40122", "3h4m", "2", "7ms", "12/9"}
	for i := range want {
		if row[i] != want[i] {
			t.Errorf("column %d = %q, want %q", i, row[i], want[i])
		}
	}
}

// A plugin that is not running has no pid, and 0 is not a pid. The rule is
// the same one that governs Stats=false: never render a number that was
// never measured.
func TestPluginRowZeroPIDRendersDash(t *testing.T) {
	p := output.New(&bytes.Buffer{}, &bytes.Buffer{}, output.Table, false)
	row := pluginRow(p, vc.Plugin{ID: "todo", State: vc.StateFailed, Restarts: 3, Stats: true})
	if row[3] != dash {
		t.Errorf("pid column = %q, want %q", row[3], dash)
	}
	if row[5] != "3" {
		t.Errorf("restarts column = %q, want %q", row[5], "3")
	}
}
