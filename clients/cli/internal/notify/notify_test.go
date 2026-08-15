package notify

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"testing"
)

func TestNewDisabledIsNoop(t *testing.T) {
	n := New(false)
	if _, ok := n.(noopNotifier); !ok {
		t.Fatalf("New(false) = %T, want noopNotifier", n)
	}
	if err := n.Notify(context.Background(), Notification{Title: "x"}); err != nil {
		t.Fatalf("noop Notify: %v", err)
	}
}

func TestNoopIsNoop(t *testing.T) {
	if _, ok := Noop().(noopNotifier); !ok {
		t.Fatal("Noop() is not a noopNotifier")
	}
}

func TestEscapeAppleScript(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{"plain", "hello world", "hello world"},
		{"quote", `say "hi"`, `say \"hi\"`},
		{"backslash", `a\b`, `a\\b`},
		// A trailing backslash must not escape the closing quote of the
		// literal it is embedded in.
		{"trailing backslash", `path\`, `path\\`},
		{"newline", "one\ntwo", `one\ntwo`},
		{"carriage return", "one\rtwo", `one\rtwo`},
		{"tab", "a\tb", `a\tb`},
		{"other control bytes dropped", "a\x00\x07b", "ab"},
		{"unicode kept", "café ☕", "café ☕"},
		{
			// The whole point: closing the literal and appending another
			// AppleScript statement must be impossible.
			"injection attempt",
			`x" with title "y"
do shell script "rm -rf /`,
			`x\" with title \"y\"\ndo shell script \"rm -rf /`,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := escapeAppleScript(tc.in); got != tc.want {
				t.Errorf("escapeAppleScript(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestOsascriptArgsIsSingleScriptArgument(t *testing.T) {
	args := osascriptArgs(Notification{Title: `t"itle`, Body: `bo\dy`})
	if len(args) != 2 || args[0] != "-e" {
		t.Fatalf("osascriptArgs = %q, want [-e <script>]", args)
	}
	want := `display notification "bo\\dy" with title "t\"itle"`
	if args[1] != want {
		t.Errorf("script = %q, want %q", args[1], want)
	}
}

func TestOsascriptArgsHostileInputStaysOneStatement(t *testing.T) {
	args := osascriptArgs(Notification{
		Title: `a" & (do shell script "touch /tmp/pwned") & "`,
		Body:  "b",
	})
	script := args[1]
	// One `display notification`, and every quote after the opening one is
	// either escaped or a delimiter we placed ourselves.
	if strings.Count(script, "display notification") != 1 {
		t.Fatalf("script grew a second statement: %q", script)
	}
	if strings.Contains(script, `") & "`) {
		t.Fatalf("unescaped literal break in %q", script)
	}
}

func TestNotifySendArgsUrgency(t *testing.T) {
	tests := []struct {
		level string
		want  string
	}{
		{"warn", "critical"},
		{"info", "normal"},
		{"", "normal"},
		{"WARN", "normal"}, // levels are lower-case on the wire; no guessing
	}
	for _, tc := range tests {
		args := notifySendArgs(Notification{Title: "t", Body: "b", Level: tc.level})
		got := argValue(args, "-u")
		if got != tc.want {
			t.Errorf("level %q -> urgency %q, want %q", tc.level, got, tc.want)
		}
	}
}

func TestNotifySendArgsSeparatesOptionsFromText(t *testing.T) {
	args := notifySendArgs(Notification{Title: "-not-a-flag", Body: "body"})
	i := indexOf(args, "--")
	if i < 0 {
		t.Fatalf("no -- terminator in %q", args)
	}
	rest := args[i+1:]
	if len(rest) != 2 || rest[0] != "-not-a-flag" || rest[1] != "body" {
		t.Errorf("text args = %q, want [-not-a-flag body]", rest)
	}
}

func TestNotifySendArgsOmitsEmptyBody(t *testing.T) {
	args := notifySendArgs(Notification{Title: "t"})
	rest := args[indexOf(args, "--")+1:]
	if len(rest) != 1 || rest[0] != "t" {
		t.Errorf("text args = %q, want [t]", rest)
	}
}

// A missing notifier binary must be reported once and then forgotten. A
// debug tool that prints the same error on every alert is worse than one
// that prints none.
func TestMissingBinaryReportsOnceThenDegrades(t *testing.T) {
	calls := 0
	n := &cmdNotifier{
		name: "notify-send",
		argv: notifySendArgs,
		run: func(context.Context, string, ...string) error {
			calls++
			return &exec.Error{Name: "notify-send", Err: exec.ErrNotFound}
		},
	}

	err := n.Notify(context.Background(), Notification{Title: "first"})
	if err == nil {
		t.Fatal("first Notify with missing binary returned nil, want an error")
	}
	if !strings.Contains(err.Error(), "notify-send") {
		t.Errorf("error %q does not name the missing binary", err)
	}

	for i := 0; i < 3; i++ {
		if err := n.Notify(context.Background(), Notification{Title: "later"}); err != nil {
			t.Fatalf("Notify #%d after degrade: %v", i+2, err)
		}
	}
	if calls != 1 {
		t.Errorf("runner called %d times, want 1 (degraded to noop)", calls)
	}
}

// Ordinary failures are transient — a busy notification daemon today may
// work in a second — so they must not disable the bridge.
func TestOtherErrorsDoNotDegrade(t *testing.T) {
	calls := 0
	boom := errors.New("exit status 1")
	n := &cmdNotifier{
		name: "osascript",
		argv: osascriptArgs,
		run: func(context.Context, string, ...string) error {
			calls++
			return boom
		},
	}
	for i := 0; i < 3; i++ {
		if err := n.Notify(context.Background(), Notification{Title: "t"}); !errors.Is(err, boom) {
			t.Fatalf("Notify #%d = %v, want %v", i+1, err, boom)
		}
	}
	if calls != 3 {
		t.Errorf("runner called %d times, want 3", calls)
	}
}

func TestNotifyPassesNameAndArgsThrough(t *testing.T) {
	var gotName string
	var gotArgs []string
	n := &cmdNotifier{
		name: "osascript",
		argv: osascriptArgs,
		run: func(_ context.Context, name string, args ...string) error {
			gotName, gotArgs = name, args
			return nil
		},
	}
	if err := n.Notify(context.Background(), Notification{Title: "t", Body: "b"}); err != nil {
		t.Fatalf("Notify: %v", err)
	}
	if gotName != "osascript" {
		t.Errorf("name = %q, want osascript", gotName)
	}
	if len(gotArgs) != 2 || gotArgs[0] != "-e" {
		t.Errorf("args = %q", gotArgs)
	}
}

func TestNotifyRespectsCancelledContext(t *testing.T) {
	calls := 0
	n := &cmdNotifier{
		name: "osascript",
		argv: osascriptArgs,
		run: func(context.Context, string, ...string) error {
			calls++
			return nil
		},
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := n.Notify(ctx, Notification{Title: "t"}); !errors.Is(err, context.Canceled) {
		t.Errorf("Notify with cancelled ctx = %v, want context.Canceled", err)
	}
	if calls != 0 {
		t.Errorf("runner called %d times on a cancelled ctx, want 0", calls)
	}
}

func TestNotifyBoundsItsOwnRuntime(t *testing.T) {
	var deadlineSet bool
	n := &cmdNotifier{
		name: "osascript",
		argv: osascriptArgs,
		run: func(ctx context.Context, _ string, _ ...string) error {
			_, deadlineSet = ctx.Deadline()
			return nil
		},
	}
	if err := n.Notify(context.Background(), Notification{Title: "t"}); err != nil {
		t.Fatalf("Notify: %v", err)
	}
	if !deadlineSet {
		t.Error("runner got a ctx with no deadline; a wedged notifier would block the caller forever")
	}
}

func indexOf(ss []string, want string) int {
	for i, s := range ss {
		if s == want {
			return i
		}
	}
	return -1
}

func argValue(args []string, flag string) string {
	i := indexOf(args, flag)
	if i < 0 || i+1 >= len(args) {
		return ""
	}
	return args[i+1]
}
