package browser

import (
	"context"
	"runtime"
	"strings"
	"testing"
)

// The URL must arrive as one argv element. If it were ever concatenated into
// a shell string, a plugin id containing a shell metacharacter would become
// executable — and plugin ids come from manifests on disk.
func TestURLIsASingleArgument(t *testing.T) {
	var gotName string
	var gotArgs []string
	restore := run
	run = func(_ context.Context, name string, args ...string) error {
		gotName, gotArgs = name, args
		return nil
	}
	t.Cleanup(func() { run = restore })

	const url = "http://127.0.0.1:51234/p/todo/?vc=abc&x=1;rm -rf /"
	if err := Open(context.Background(), url); err != nil {
		t.Fatalf("Open: %v", err)
	}

	if gotName == "" {
		t.Fatal("Open ran nothing")
	}
	var found bool
	for _, a := range gotArgs {
		if a == url {
			found = true
		}
		if strings.Contains(a, "&&") || strings.Contains(a, "|") {
			t.Errorf("argument %q looks like a shell fragment", a)
		}
	}
	if !found {
		t.Errorf("the URL was not passed intact as one argument: %q", gotArgs)
	}
}

func TestEmptyURLIsAnError(t *testing.T) {
	restore := run
	run = func(context.Context, string, ...string) error {
		t.Error("Open executed something for an empty URL")
		return nil
	}
	t.Cleanup(func() { run = restore })

	if err := Open(context.Background(), ""); err == nil {
		t.Error("Open accepted an empty URL")
	}
}

func TestPlatformOpener(t *testing.T) {
	name, args, err := command("http://x/")
	if err != nil {
		t.Fatalf("command: %v", err)
	}
	want := map[string]string{"darwin": "open", "windows": "rundll32"}[runtime.GOOS]
	if want == "" {
		want = "xdg-open"
	}
	if name != want {
		t.Errorf("opener = %q, want %q on %s", name, want, runtime.GOOS)
	}
	if len(args) == 0 {
		t.Error("opener got no arguments")
	}
}
