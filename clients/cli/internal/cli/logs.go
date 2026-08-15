package cli

import (
	"context"
	"fmt"

	"github.com/spf13/cobra"

	"github.com/vibecare-io/vibecare/clients/cli/internal/cli/output"
	"github.com/vibecare-io/vibecare/clients/cli/internal/logtail"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

var (
	flagLogsFollow bool
	flagLogsTail   int
	flagLogsAll    bool
)

func init() {
	f := logsCmd.Flags()
	f.BoolVarP(&flagLogsFollow, "follow", "f", false, "keep streaming as lines are written")
	f.IntVarP(&flagLogsTail, "tail", "n", defaultTail, "lines of history to show first; negative means the whole file")
	f.BoolVar(&flagLogsAll, "all", false, "merge every source, prefixed with its id")
	addCommand(logsCmd)
}

// defaultTail is deep enough to hold a crash and its stack, shallow enough
// that `vibecare logs core` is still one screenful of context.
const defaultTail = 200

var logsCmd = &cobra.Command{
	Use:   "logs [core|<plugin-id>]",
	Short: "Show core or plugin logs",
	Long: "logs reads files on disk, so it keeps working when core does not —\n" +
		"which is when a crashed plugin's last words are worth the most.\n\n" +
		"Paths are never reconstructed from a convention: a plugin's log path\n" +
		"comes from the kernel, and core's is the one location this client\n" +
		"knows. With core down, only core's own log can be resolved.",
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return runOffline(func(ctx context.Context, s *vc.Session, dialErr error, p *output.Printer) error {
			return showLogs(ctx, s, dialErr, p, args)
		})(cmd, args)
	},
}

func showLogs(ctx context.Context, s *vc.Session, dialErr error, p *output.Printer, args []string) error {
	switch {
	case flagLogsAll && len(args) > 0:
		return vc.Usagef("--all takes no argument (got %q)", args[0])
	case !flagLogsAll && len(args) == 0:
		return vc.Usagef("name a source (%q or a plugin id), or pass --all", vc.CoreLogID)
	}

	sources, err := logSources(ctx, s, dialErr, args)
	if err != nil {
		return err
	}
	for _, src := range sources {
		verbosef("tailing %s from %s", src.ID, src.Path)
	}

	lines, err := logtail.Merge(ctx, sources, logtail.Options{Follow: flagLogsFollow, Tail: flagLogsTail})
	if err != nil {
		return vc.Errorf("no readable log file: %v", err)
	}
	return streamLines(ctx, p, lines, prefixWidth(sources))
}

// logSources resolves what to tail. With no session it degrades to core's own
// log rather than failing: that file is on disk and is the reason the user
// reached for this command.
func logSources(ctx context.Context, s *vc.Session, dialErr error, args []string) ([]logtail.Source, error) {
	if flagLogsAll {
		if s == nil {
			verbosef("core unreachable; --all covers core's own log only")
			return []logtail.Source{sourceOf(vc.CoreLogSource())}, nil
		}
		found, err := s.LogSources(ctx)
		if err != nil {
			return nil, err
		}
		out := make([]logtail.Source, 0, len(found))
		for _, src := range found {
			out = append(out, sourceOf(src))
		}
		return out, nil
	}

	id := args[0]
	if s == nil {
		if id == vc.CoreLogID {
			return []logtail.Source{sourceOf(vc.CoreLogSource())}, nil
		}
		// The kernel publishes plugin log paths precisely so this client
		// never guesses one; with core down there is nothing to ask.
		return nil, vc.Wrap(dialErr, "cannot resolve the log path for %q", id)
	}
	src, err := s.LogSource(ctx, id)
	if err != nil {
		return nil, err
	}
	return []logtail.Source{sourceOf(src)}, nil
}

func sourceOf(src vc.LogSource) logtail.Source {
	return logtail.Source{ID: src.ID, Path: src.Path}
}

// prefixWidth is the column the source ids are padded to, or 0 when there is
// only one source and a prefix would be noise on every line.
func prefixWidth(sources []logtail.Source) int {
	if len(sources) < 2 {
		return 0
	}
	w := 0
	for _, s := range sources {
		if n := len(s.ID); n > w {
			w = n
		}
	}
	return w
}

// streamLines drains the tail until it ends or ctx is cancelled. Cancellation
// is a success: Ctrl-C out of `logs -f` means "stop following", and exiting
// non-zero there would break every shell pipeline that ends in one.
//
// Under --json each line leaves as its own envelope. A follow stream has no
// end, so there is no array to close and no consumer that could wait for one.
func streamLines(ctx context.Context, p *output.Printer, lines <-chan logtail.Line, width int) error {
	for {
		select {
		case <-ctx.Done():
			return nil
		case ln, ok := <-lines:
			if !ok {
				return nil
			}
			if p.IsJSON() {
				if err := p.JSON(vc.LogLine{Source: ln.Source, Text: ln.Text, At: ln.At}); err != nil {
					return err
				}
				continue
			}
			// "%s" and never the text itself: a log line is data, and a
			// stray %d in it must not be read as a verb.
			p.Line("%s", prefixed(ln, width))
		}
	}
}

func prefixed(ln logtail.Line, width int) string {
	if width == 0 {
		return ln.Text
	}
	return fmt.Sprintf("%-*s  %s", width, ln.Source, ln.Text)
}
