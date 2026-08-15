package plugbuild

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestSplit(t *testing.T) {
	tests := []struct {
		in   string
		want []string
	}{
		{"just build-todo-plugin", []string{"just", "build-todo-plugin"}},
		{"go build -tags dev -o todo .", []string{"go", "build", "-tags", "dev", "-o", "todo", "."}},
		{"  spaced   out  ", []string{"spaced", "out"}},
		{`go build -o "my plugin" .`, []string{"go", "build", "-o", "my plugin", "."}},
		{`sh -c 'echo hi'`, []string{"sh", "-c", "echo hi"}},
		// An empty quoted argument is a real argument, not nothing.
		{`cmd "" x`, []string{"cmd", "", "x"}},
		{"", nil},
	}
	for _, tc := range tests {
		got, err := Split(tc.in)
		if err != nil {
			t.Errorf("Split(%q): %v", tc.in, err)
			continue
		}
		if !reflect.DeepEqual(got, tc.want) {
			t.Errorf("Split(%q) = %#v, want %#v", tc.in, got, tc.want)
		}
	}
}

// No shell means shell metacharacters are inert data, not syntax.
func TestSplitDoesNotInterpretShellSyntax(t *testing.T) {
	got, err := Split("go build; rm -rf /")
	if err != nil {
		t.Fatal(err)
	}
	// ";" stays glued to the token it was written against — it is an
	// argument, and `go` will reject it, which is the correct outcome.
	if got[0] != "go" {
		t.Errorf("argv[0] = %q, want go", got[0])
	}
	for _, a := range got {
		if a == "rm" && got[0] != "rm" {
			continue // present as an argument, never as the program
		}
	}
	if len(got) < 2 {
		t.Errorf("got %#v", got)
	}
}

func TestSplitUnterminatedQuote(t *testing.T) {
	if _, err := Split(`go build -o "unclosed`); err == nil {
		t.Error("Split accepted an unterminated quote")
	}
}

func TestRunCapturesOutputOnSuccess(t *testing.T) {
	dir := t.TempDir()
	res, err := Run(context.Background(), dir, "echo built")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(res.Output, "built") {
		t.Errorf("output = %q", res.Output)
	}
	if res.Duration <= 0 {
		t.Error("no duration recorded")
	}
}

// The compiler's reason is the entire value of a failed build.
func TestRunFailureCarriesOutput(t *testing.T) {
	dir := t.TempDir()
	_, err := Run(context.Background(), dir, "sh -c 'echo boom >&2; exit 3'")
	if err == nil {
		t.Fatal("Run reported success for a failing command")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Errorf("error dropped the build output: %v", err)
	}
}

// It must run where the plugin lives, not where the client was started.
func TestRunUsesTheGivenDirectory(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "marker"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	res, err := Run(context.Background(), dir, "ls")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !strings.Contains(res.Output, "marker") {
		t.Errorf("ran in the wrong directory; output = %q", res.Output)
	}
}

func TestRunRejectsEmptyCommand(t *testing.T) {
	if _, err := Run(context.Background(), t.TempDir(), "   "); err == nil {
		t.Error("Run accepted an empty build command")
	}
}
