package output

import (
	"fmt"
	"strings"

	"github.com/mattn/go-runewidth"
)

// colSep is the gap between columns. Two spaces, not a box border: the
// output is meant to survive being piped into awk and cut.
const colSep = "  "

// Table writes headers and rows column-aligned to stdout, or nothing under
// --json.
//
// With no rows it prints a dim "none" and no header. An empty table with
// column titles reads as "the query failed"; "none" reads as "the answer is
// zero", which is what it means.
func (p *Printer) Table(headers []string, rows [][]string) {
	if p.IsJSON() {
		return
	}
	if len(rows) == 0 {
		fmt.Fprintln(p.out, p.style(p.dim, "none"))
		return
	}

	widths := columnWidths(headers, rows)
	if len(headers) > 0 {
		fmt.Fprintln(p.out, p.style(p.dim, joinRow(headers, widths)))
	}
	for _, row := range rows {
		fmt.Fprintln(p.out, joinRow(row, widths))
	}
}

// KV writes an aligned key/value block, the detail-view counterpart to
// Table. Silent under --json.
func (p *Printer) KV(pairs [][2]string) {
	if p.IsJSON() {
		return
	}
	keyWidth := 0
	for _, kv := range pairs {
		if w := runewidth.StringWidth(kv[0]); w > keyWidth {
			keyWidth = w
		}
	}
	for _, kv := range pairs {
		key := p.style(p.dim, runewidth.FillRight(kv[0], keyWidth))
		fmt.Fprintln(p.out, key+colSep+kv[1])
	}
}

// columnWidths measures each column in terminal cells.
//
// Cells, not bytes and not runes: "日本語" occupies 9 bytes and 3 runes but
// draws 6 columns wide, and a plugin id or an alert title can carry CJK or
// emoji. Aligning on len() would visibly skew every row after the first
// wide one.
func columnWidths(headers []string, rows [][]string) []int {
	n := len(headers)
	for _, row := range rows {
		if len(row) > n {
			n = len(row)
		}
	}
	widths := make([]int, n)
	measure := func(cells []string) {
		for i, c := range cells {
			if w := runewidth.StringWidth(c); w > widths[i] {
				widths[i] = w
			}
		}
	}
	measure(headers)
	for _, row := range rows {
		measure(row)
	}
	return widths
}

// joinRow pads every cell but the last. The final column is left ragged so
// no line carries trailing whitespace — it keeps diffs and golden files
// honest, and stops a copied line from dragging invisible spaces along.
func joinRow(cells []string, widths []int) string {
	var b strings.Builder
	for i, c := range cells {
		if i > 0 {
			b.WriteString(colSep)
		}
		if i == len(cells)-1 {
			b.WriteString(c)
			continue
		}
		b.WriteString(runewidth.FillRight(c, widths[i]))
	}
	return b.String()
}
