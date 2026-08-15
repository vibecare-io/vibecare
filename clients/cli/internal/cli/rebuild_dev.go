//go:build dev

package cli

import (
	"context"
	"time"

	"github.com/spf13/cobra"

	"github.com/vibecare-io/vibecare/clients/cli/internal/cli/output"
	"github.com/vibecare-io/vibecare/clients/cli/internal/plugbuild"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// Rebuild exists only in a dev build (`-tags dev`). It is not a flag that
// hides the command, it is a file the release binary never compiles: the
// command runs a program named by a file on disk, and the honest way to
// promise a shipped client cannot do that is for the code not to be in it.
//
// This mirrors what plugins/todo already does with its live-reload UI.
func init() {
	pluginsCmd.AddCommand(pluginsRebuildCmd)
	devBuild = true
}

var flagNoRestart bool

var pluginsRebuildCmd = &cobra.Command{
	Use:   "rebuild <id>",
	Short: "Run a plugin's declared build command, then restart it (dev builds only)",
	Long: "rebuild runs the build: command from the plugin's manifest.yaml in the\n" +
		"plugin's own directory, then asks the kernel to respawn it — the two\n" +
		"halves of the edit/see-it loop, without leaving the client.\n\n" +
		"The command comes from the manifest rather than being inferred from the\n" +
		"source tree, and that is not ceremony: vibecheck is Swift, embeds an\n" +
		"Info.plist through linker flags, and must be codesigned before macOS\n" +
		"will show a camera prompt. A guessed `swift build` produces a binary\n" +
		"that starts and then silently has no camera.\n\n" +
		"A plugin with no build: line has nothing to rebuild from and says so.\n" +
		"Only argv is supported — no shell — so a build needing a pipeline\n" +
		"should name a script.",
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
			return rebuild(ctx, s, p, args[0])
		})(cmd, args)
	},
}

func init() {
	pluginsRebuildCmd.Flags().BoolVar(&flagNoRestart, "no-restart", false,
		"build but leave the running process alone")
}

func rebuild(ctx context.Context, s *vc.Session, p *output.Printer, id string) error {
	pl, err := s.PluginBuild(ctx, id)
	if err != nil {
		return err
	}

	p.Line("building %s: %s", id, pl.Build)
	res, buildErr := plugbuild.Run(ctx, pl.Dir, pl.Build)
	if buildErr != nil {
		// The build output is the whole point of a failure, so it goes to
		// the human before the error envelope does.
		if !p.IsJSON() && res.Output != "" {
			p.Line("%s", res.Output)
		}
		return vc.Wrap(buildErr, "rebuild %s", id)
	}
	p.Line("built in %s", res.Duration.Round(time.Millisecond))

	out := rebuilt{ID: id, Command: pl.Build, BuiltMS: res.Duration.Milliseconds(), Output: res.Output}
	if flagNoRestart {
		p.Line("left %s running; the new binary starts on its next restart", id)
		return p.JSON(out)
	}

	if err := s.RestartPlugin(ctx, id); err != nil {
		// The build DID succeed, and saying otherwise would send the reader
		// back to their code instead of to the kernel.
		return vc.Wrap(err, "%s built, but restarting it", id)
	}
	out.Restarted = true

	// "Restarted" is not the same as "running". A plugin that builds
	// cleanly and then dies on spawn — a bad signature, a missing runtime
	// permission — would otherwise be reported as a success, which is the
	// most misleading thing this command could say. Wait for the kernel's
	// verdict and report that instead.
	state, detail := settle(ctx, s, id)
	out.State, out.Detail = string(state), detail

	if state == vc.StateUp {
		p.Line("restarted %s — %s", id, state)
		return p.JSON(out)
	}
	if err := p.JSON(out); err != nil {
		return err
	}
	if detail != "" {
		return vc.Errorf("%s built, but came back %s: %s", id, state, detail)
	}
	return vc.Errorf("%s built, but came back %s", id, state)
}

// settleWindow bounds how long to wait for a restarted plugin to reach a
// steady state: long enough for a spawn plus the kernel's first probe, short
// enough that a wedged plugin does not hold the command open.
const settleWindow = 5 * time.Second

// settle polls until the plugin leaves STARTING and reports what it settled
// into. One still starting when the window closes is reported as starting
// rather than guessed at.
func settle(ctx context.Context, s *vc.Session, id string) (vc.State, string) {
	deadline := time.Now().Add(settleWindow)
	last := vc.StateUnknown
	var detail string

	for {
		r, err := s.Roster(ctx)
		if err != nil {
			return last, detail
		}
		for _, pl := range r.Plugins {
			if pl.ID == id {
				last, detail = pl.State, pl.Detail
			}
		}
		if last != vc.StateStarting && last != vc.StateUnknown {
			return last, detail
		}
		if time.Now().After(deadline) {
			return last, detail
		}
		select {
		case <-ctx.Done():
			return last, detail
		case <-time.After(250 * time.Millisecond):
		}
	}
}

type rebuilt struct {
	ID        string `json:"id"`
	Command   string `json:"build"`
	BuiltMS   int64  `json:"built_ms"`
	Restarted bool   `json:"restarted"`
	// State is what the plugin settled into after the restart, and Detail
	// is the kernel's reason when that is not UP.
	State  string `json:"state,omitempty"`
	Detail string `json:"detail,omitempty"`
	// Output is the build's own stdout+stderr. Kept even on success: a
	// build that warns is worth seeing, and a consumer that does not care
	// simply ignores the field.
	Output string `json:"output,omitempty"`
}
