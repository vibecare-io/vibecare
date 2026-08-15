package cli

import (
	"context"
	"sort"
	"strconv"

	"github.com/spf13/cobra"

	"github.com/vibecare-io/vibecare/clients/cli/internal/cli/output"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// flagRoutineProfile is empty by default, which the server reads as its own
// default profile. This client does not invent one.
var flagRoutineProfile string

func init() {
	routinesCmd.AddCommand(
		routinesLsCmd,
		routinesShowCmd,
		routinesRunCmd,
		routinesLogsCmd,
	)
	addCommand(routinesCmd)
}

var routinesCmd = newRoutinesListCmd("routines")

var routinesLsCmd = newRoutinesListCmd("ls")

func newRoutinesListCmd(use string) *cobra.Command {
	c := &cobra.Command{
		Use:   use,
		Short: "List routines",
		Long: "routines are the named groups of actions a schedule fires. Listing them\n" +
			"shows what exists and whether it is enabled; `routines show` adds the\n" +
			"actions, in the order they run.",
		Args: cobra.NoArgs,
		RunE: run(listRoutines),
	}
	c.Flags().StringVar(&flagRoutineProfile, "profile", "", "list routines of this profile (default: the server's)")
	return c
}

func listRoutines(ctx context.Context, s *vc.Session, p *output.Printer) error {
	routines, err := s.ListRoutines(ctx, flagRoutineProfile)
	if err != nil {
		return err
	}
	if routines == nil {
		routines = []vc.Routine{}
	}
	if err := p.JSON(routines); err != nil {
		return err
	}

	rows := make([][]string, 0, len(routines))
	for _, r := range routines {
		rows = append(rows, []string{
			r.ID,
			orDash(truncate(r.Name, nameWidth)),
			yesNo(r.Enabled),
			relTime(r.UpdatedAt),
			orDash(truncate(r.Notes, notesWidth)),
		})
	}
	p.Table([]string{"ID", "NAME", "ENABLED", "UPDATED", "NOTES"}, rows)
	return nil
}

var routinesShowCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show one routine and the actions it runs",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
			r, err := s.GetRoutine(ctx, args[0])
			if err != nil {
				return err
			}
			if err := p.JSON(r); err != nil {
				return err
			}
			p.KV([][2]string{
				{"id", r.ID},
				{"name", orDash(r.Name)},
				{"enabled", yesNo(r.Enabled)},
				{"profile", orDash(r.ProfileID)},
				{"created", stamp(r.CreatedAt)},
				{"updated", stamp(r.UpdatedAt)},
				{"notes", orDash(r.Notes)},
			})
			p.Line("")
			p.Table(actionHeaders, actionRows(r.Actions))
			return nil
		})(cmd, args)
	},
}

var routinesRunCmd = &cobra.Command{
	Use:   "run <id>",
	Short: "Execute a routine now",
	Long: "run executes the routine immediately, whether or not it is due: a human\n" +
		"who typed it has already decided.\n\n" +
		"The exit code reports the RPC, and the per-action results report the\n" +
		"work — a routine can complete with an action that failed.",
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
			log, err := s.RunRoutine(ctx, args[0])
			if err != nil {
				return err
			}
			if err := p.JSON(log); err != nil {
				return err
			}
			p.KV([][2]string{
				{"routine", orDash(log.RoutineID)},
				{"log", logIDCell(log.LogID)},
				{"at", stamp(log.Timestamp)},
				{"completed", yesNo(log.Completed)},
				{"notes", orDash(log.Notes)},
			})
			if len(log.Results) > 0 {
				p.Line("")
				p.Table([]string{"ACTION", "RESULT"}, resultRows(log.Results))
			}
			return nil
		})(cmd, args)
	},
}

var routinesLogsCmd = &cobra.Command{
	Use:   "logs <id>",
	Short: "Show recent executions of a routine",
	Long: "logs here means execution history, not text: it is the scheduler's\n" +
		"record of when this routine ran and whether it finished. For a\n" +
		"process's output, use `vibecare logs`.",
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
			logs, err := s.RoutineLogs(ctx, args[0])
			if err != nil {
				return err
			}
			if logs == nil {
				logs = []vc.ExecutionLog{}
			}
			if err := p.JSON(logs); err != nil {
				return err
			}

			rows := make([][]string, 0, len(logs))
			for _, l := range logs {
				rows = append(rows, []string{
					logIDCell(l.LogID),
					relTime(l.Timestamp),
					yesNo(l.Completed),
					orDash(truncate(l.Notes, notesWidth)),
				})
			}
			p.Table([]string{"LOG", "WHEN", "COMPLETED", "NOTES"}, rows)
			return nil
		})(cmd, args)
	},
}

// logIDCell renders an execution log id, treating 0 as absent — the backend
// assigns ids from 1, so a zero means the field was never set.
func logIDCell(id int64) string {
	if id == 0 {
		return dash
	}
	return strconv.FormatInt(id, 10)
}

// resultRows renders the per-action results of one execution, sorted so two
// runs of the same routine produce comparable output. Go map iteration order
// is randomised, and a diffable result is worth the sort.
func resultRows(results map[string]string) [][]string {
	ids := make([]string, 0, len(results))
	for id := range results {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	rows := make([][]string, 0, len(ids))
	for _, id := range ids {
		rows = append(rows, []string{id, orDash(results[id])})
	}
	return rows
}
