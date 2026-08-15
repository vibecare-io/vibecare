package keymap

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"testing"
)

// The README's key reference is generated from the tables in this file rather
// than written by hand, for the same reason the footer and the transient are:
// a binding declared once cannot disagree with itself. This test regenerates
// the reference and fails if the committed README has drifted.
//
//	go test ./internal/tui/keymap -update
//
// rewrites the block in place. Without the flag it is a plain assertion, so a
// rebind that forgets the docs is caught in CI rather than by a reader who
// pressed a key that no longer does anything.
var update = flag.Bool("update", false, "rewrite the README key reference from these tables")

// readmePath is relative to this package directory, which is where `go test`
// runs.
const readmePath = "../../../README.md"

// Markers delimit the generated region. Everything between them is owned by
// this test; everything outside it is prose a human wrote.
const (
	beginMarker = "<!-- BEGIN GENERATED KEYS -->"
	endMarker   = "<!-- END GENERATED KEYS -->"
)

func TestREADMEKeyReferenceMatchesTables(t *testing.T) {
	if devTables {
		// The README documents the client people are given, and a dev build
		// binds keys that binary does not have. Regenerating from here would
		// write a reference to a command half its readers cannot run.
		t.Skip("dev build: the key reference documents the release surface")
	}
	want := keyReference()

	raw, err := os.ReadFile(readmePath)
	if err != nil {
		t.Fatalf("read README: %v", err)
	}
	readme := string(raw)

	before, rest, ok := strings.Cut(readme, beginMarker)
	if !ok {
		t.Fatalf("README is missing %s", beginMarker)
	}
	_, after, ok := strings.Cut(rest, endMarker)
	if !ok {
		t.Fatalf("README is missing %s", endMarker)
	}

	block := beginMarker + "\n\n" + want + "\n" + endMarker
	updated := before + block + after
	if updated == readme {
		return
	}
	if *update {
		if err := os.WriteFile(readmePath, []byte(updated), 0o644); err != nil {
			t.Fatalf("write README: %v", err)
		}
		t.Log("README key reference regenerated")
		return
	}
	t.Errorf("README key reference is stale; run: go test ./internal/tui/keymap -update")
}

// keyReference renders every table in this package as markdown. Grouped the
// way the user meets them: the keys that always work, then movement, then the
// ones that depend on what the sidebar has selected, then per pane.
func keyReference() string {
	var b strings.Builder

	b.WriteString("#### Always available\n\n")
	writeTable(&b, globalFor(FocusDetail).Bindings)

	// Movement is documented per focus because it genuinely differs: the
	// same key drives the subject list on the left and the tab strip and
	// pane on the right. One merged table would have to lie about half of
	// it.
	b.WriteString("\n#### Movement — subject list focused\n\n")
	b.WriteString("`tab` crosses into the panel; `esc` comes back.\n\n")
	writeTable(&b, navFor(FocusSidebar).Bindings)

	b.WriteString("\n#### Movement — panel focused\n\n")
	writeTable(&b, navFor(FocusDetail).Bindings)

	b.WriteString("\n#### Acting on the selected subject\n\n")
	b.WriteString("| Subject | Key | Action |\n|---|---|---|\n")
	for _, k := range allKinds {
		for _, bind := range subjectGroups[k].Bindings {
			fmt.Fprintf(&b, "| %s | `%s` | %s |\n", k, escape(bind.Key), bind.Desc)
		}
	}

	b.WriteString("\n#### Tabs\n\n")
	b.WriteString("Digits jump straight to a tab; the strip changes with the subject.\n\n")
	b.WriteString("| Subject | Tabs |\n|---|---|\n")
	for _, k := range allKinds {
		labels := make([]string, 0, len(tabs[k]))
		for i, tb := range tabs[k] {
			labels = append(labels, fmt.Sprintf("`%d` %s", i+1, tb.Name))
		}
		fmt.Fprintf(&b, "| %s | %s |\n", k, strings.Join(labels, " · "))
	}

	b.WriteString("\n#### Pane controls\n\n")
	b.WriteString("| Pane | Key | Action |\n|---|---|---|\n")
	for _, c := range allCtx {
		for _, bind := range ctxGroups[c].Bindings {
			fmt.Fprintf(&b, "| %s | `%s` | %s |\n", c, escape(bind.Key), bind.Desc)
		}
	}

	return b.String()
}

func writeTable(b *strings.Builder, bindings []Binding) {
	b.WriteString("| Key | Action |\n|---|---|\n")
	for _, bind := range bindings {
		fmt.Fprintf(b, "| `%s` | %s |\n", escape(bind.Key), bind.Desc)
	}
}

// escape guards the one display key that is also markdown table syntax.
func escape(k string) string { return strings.ReplaceAll(k, "|", `\|`) }
