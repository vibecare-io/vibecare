package cli

import (
	"context"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	"github.com/vibecare-io/vibecare/clients/cli/internal/cli/output"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

func init() {
	pluginsCmd.AddCommand(pluginsRestartCmd)
	addCommand(pluginsCmd)
}

var pluginsCmd = &cobra.Command{
	Use:   "plugins",
	Short: "List the plugin roster with per-process stats",
	Long: "plugins shows the roster core is streaming, enriched with the kernel's\n" +
		"own numbers: pid, uptime, restart count, probe latency and event\n" +
		"counters.\n\n" +
		"When the kernel's HTTP surface cannot be reached the roster still\n" +
		"lists every plugin and its state; the numeric columns render as " + dash + "\n" +
		"because no measurement was taken.",
	Args: cobra.NoArgs,
	RunE: run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
		r, err := s.Roster(ctx)
		if err != nil {
			return err
		}
		if r.Plugins == nil {
			// The contract promises [] rather than null for an empty list,
			// and encoding/json cannot tell the difference for us.
			r.Plugins = []vc.Plugin{}
		}

		if err := p.JSON(r); err != nil {
			return err
		}

		rows := make([][]string, 0, len(r.Plugins))
		for _, pl := range r.Plugins {
			rows = append(rows, pluginRow(p, pl))
		}
		p.Table([]string{"ID", "NAME", "STATE", "PID", "UPTIME", "RESTARTS", "PROBE", "EVENTS"}, rows)
		return nil
	}),
}

var pluginsRestartCmd = &cobra.Command{
	Use:   "restart <id>",
	Short: "Ask the kernel to respawn a plugin",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
			if err := s.RestartPlugin(ctx, args[0]); err != nil {
				return err
			}
			p.Line("restarted %s", args[0])
			return p.JSON(restarted{ID: args[0], Restarted: true})
		})(cmd, args)
	},
}

// restarted is the --json body of a restart. It exists so the acknowledgement
// is a typed object with named fields rather than a bare string a consumer
// would have to pattern-match.
type restarted struct {
	ID        string `json:"id"`
	Restarted bool   `json:"restarted"`
}

// pluginRow renders one roster row. Every numeric column is guarded: a value
// that was never measured prints as a dash, never as zero.
func pluginRow(p *output.Printer, pl vc.Plugin) []string {
	if !pl.Stats {
		return []string{pl.ID, pl.Name, p.State(pl.State), dash, dash, dash, dash, dash}
	}
	return []string{
		pl.ID,
		pl.Name,
		p.State(pl.State),
		// A stopped plugin has no pid, and 0 is not one.
		numOrDash(pl.PID),
		humanDuration(time.Duration(pl.UptimeSec) * time.Second),
		fmt.Sprintf("%d", pl.Restarts),
		fmt.Sprintf("%dms", pl.ProbeLatencyMS),
		fmt.Sprintf("%d/%d", pl.EventsPublished, pl.EventsDelivered),
	}
}

func numOrDash(n int) string {
	if n == 0 {
		return dash
	}
	return fmt.Sprintf("%d", n)
}
