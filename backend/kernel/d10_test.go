package kernel

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// D10: core contains zero product semantics. No file in kernel/ may name a
// specific plugin or the domain it models — the kernel is a supervisor, a
// bus, a proxy, and a dashboard, all of which are generic infrastructure.
//
// The spec says this is "checkable by grep". This is that grep, run in CI.
func TestKernelContainsNoProductNouns(t *testing.T) {
	forbidden := []string{
		"posture", "nailbiting", "nail-biting", "todo",
		"vibecheck", "detection", "behavior", "behaviour",
	}

	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") {
			continue
		}
		// This file necessarily contains the words it forbids.
		if e.Name() == "d10_test.go" {
			continue
		}
		b, err := os.ReadFile(filepath.Join(".", e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		lower := strings.ToLower(string(b))
		for _, word := range forbidden {
			if strings.Contains(lower, word) {
				t.Errorf("%s contains product noun %q — the kernel must stay generic (D10)", e.Name(), word)
			}
		}
	}
}
