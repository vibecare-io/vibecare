package output

import (
	"encoding/json"
	"io"

	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// JSON writes v wrapped in the versioned envelope. It is a no-op in table
// mode so a command can call JSON and the table calls unconditionally and
// let the printer pick.
//
// Callers must hand over allocated slices, never nil: the contract promises
// empty collections serialize as [], and encoding/json renders a nil slice
// as null. The printer cannot fix that without reflecting over every value
// it is given, so the rule lives with the caller and is pinned by tests.
func (p *Printer) JSON(v any) error {
	if !p.IsJSON() {
		return nil
	}
	return encode(p.out, vc.Envelope{V: vc.ContractVersion, Data: v})
}

// encode writes one envelope followed by a newline.
//
// Two-space indent because this output has two audiences — a jq pipeline and
// a human reading a terminal — and only one of them can reformat. HTML
// escaping is off so URLs and log text survive as typed rather than arriving
// as &; the result is still valid JSON.
func encode(w io.Writer, env vc.Envelope) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	return enc.Encode(env)
}
