package cli

import (
	"context"
	"time"

	"github.com/spf13/cobra"

	"github.com/vibecare-io/vibecare/clients/cli/internal/cli/output"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

var (
	flagScheduleRoutine string
	flagScheduleEnabled bool
	// One flag variable per verb rather than one shared between them: cobra
	// keeps a flag's value after Execute, and a `pause --all` that leaked into
	// the next `resume` would be the worst possible bug in this command.
	flagPauseAll  bool
	flagResumeAll bool
)

func init() {
	schedulesPauseCmd.Flags().BoolVar(&flagPauseAll, "all", false, "every schedule, in every profile")
	schedulesResumeCmd.Flags().BoolVar(&flagResumeAll, "all", false, "every schedule, in every profile")

	schedulesCmd.AddCommand(
		schedulesLsCmd,
		schedulesShowCmd,
		schedulesPauseCmd,
		schedulesResumeCmd,
	)
	addCommand(schedulesCmd)
}

// schedulesCmd lists, the way `plugins` does. The bare noun is the question
// people actually type, and `schedules ls` remains for the muscle memory that
// expects a verb.
var schedulesCmd = newSchedulesListCmd("schedules")

var schedulesLsCmd = newSchedulesListCmd("ls")

func newSchedulesListCmd(use string) *cobra.Command {
	c := &cobra.Command{
		Use:   use,
		Short: "List schedules with their next and last execution",
		Long: "schedules lists what the scheduler is holding: the recurrence rule, and\n" +
			"when each schedule last fired and next will.\n\n" +
			"A schedule that has never run shows " + dash + " rather than a date, and the\n" +
			"recurrence rule is cut to fit the terminal — `schedules show` and\n" +
			"--json both carry it in full.",
		Args: cobra.NoArgs,
		RunE: run(listSchedules),
	}
	f := c.Flags()
	// --routine, not --profile: ListSchedulesRequest filters by routine, and a
	// flag that quietly did nothing would be worse than no flag.
	f.StringVar(&flagScheduleRoutine, "routine", "", "only schedules belonging to this routine")
	f.BoolVar(&flagScheduleEnabled, "enabled", false, "only schedules that are enabled")
	return c
}

func listSchedules(ctx context.Context, s *vc.Session, p *output.Printer) error {
	schedules, err := s.ListSchedules(ctx, vc.ScheduleFilter{
		RoutineID:   flagScheduleRoutine,
		EnabledOnly: flagScheduleEnabled,
	})
	if err != nil {
		return err
	}
	if schedules == nil {
		// The contract promises [] rather than null for an empty list.
		schedules = []vc.Schedule{}
	}
	if err := p.JSON(schedules); err != nil {
		return err
	}

	rows := make([][]string, 0, len(schedules))
	for _, sc := range schedules {
		rows = append(rows, scheduleRow(sc))
	}
	p.Table([]string{"ID", "NAME", "ENABLED", "RRULE", "NEXT", "LAST"}, rows)
	return nil
}

var schedulesShowCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show one schedule with the actions it runs",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
			return showSchedule(ctx, s, p, args[0])
		})(cmd, args)
	},
}

func showSchedule(ctx context.Context, s *vc.Session, p *output.Printer, id string) error {
	sc, err := s.GetSchedule(ctx, id)
	if err != nil {
		return err
	}
	if err := p.JSON(sc); err != nil {
		return err
	}

	p.KV([][2]string{
		{"id", sc.ID},
		{"name", orDash(sc.Name)},
		{"enabled", yesNo(sc.Enabled)},
		{"type", orDash(sc.Type)},
		// Full, not truncated: this is the view the user came to for the rule.
		{"rrule", orDash(sc.RRule)},
		{"timezone", orDash(sc.Timezone)},
		{"routine", orDash(sc.RoutineID)},
		{"profile", orDash(sc.ProfileID)},
		{"dtstart", stamp(sc.DTStart)},
		{"next", stamp(sc.NextExecution)},
		{"last", stamp(sc.LastExecution)},
		{"notes", orDash(sc.Notes)},
	})
	p.Line("")
	p.Table(actionHeaders, actionRows(sc.Actions))
	return nil
}

var schedulesPauseCmd = &cobra.Command{
	Use:   "pause <id> | --all",
	Short: "Stop a schedule, or every schedule, from firing",
	Args:  scheduleTargetArgs(&flagPauseAll, "pause"),
	RunE: func(cmd *cobra.Command, args []string) error {
		return run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
			return setSchedulePaused(ctx, s, p, args, flagPauseAll, true)
		})(cmd, args)
	},
}

var schedulesResumeCmd = &cobra.Command{
	Use:   "resume <id> | --all",
	Short: "Let a schedule, or every schedule, fire again",
	Args:  scheduleTargetArgs(&flagResumeAll, "resume"),
	RunE: func(cmd *cobra.Command, args []string) error {
		return run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
			return setSchedulePaused(ctx, s, p, args, flagResumeAll, false)
		})(cmd, args)
	},
}

// scheduleTargetArgs rejects the two argv shapes that could only be resolved
// by guessing: an id alongside --all, and neither of them.
//
// It is an Args validator rather than a check inside the command body because
// argument validation must not depend on reaching core. `pause --all s1`
// against a dead backend is still a usage error, and answering "core
// unreachable" there would hide the mistake until the day core is up.
func scheduleTargetArgs(all *bool, verb string) cobra.PositionalArgs {
	return func(_ *cobra.Command, args []string) error {
		switch {
		case *all && len(args) > 0:
			return vc.Usagef("%s --all takes no schedule id (got %q)", verb, args[0])
		case !*all && len(args) == 0:
			return vc.Usagef("%s needs a schedule id, or --all", verb)
		case len(args) > 1:
			return vc.Usagef("%s takes one schedule id (got %d)", verb, len(args))
		}
		return nil
	}
}

// scheduleChange is the --json body of a pause or resume: a typed
// acknowledgement rather than a sentence a consumer would have to match on.
type scheduleChange struct {
	ID     string `json:"schedule_id,omitempty"`
	All    bool   `json:"all,omitempty"`
	Paused bool   `json:"paused"`
}

func setSchedulePaused(ctx context.Context, s *vc.Session, p *output.Printer, args []string, all, paused bool) error {
	verb := "resumed"
	if paused {
		verb = "paused"
	}

	if all {
		call := s.ResumeAllSchedules
		if paused {
			call = s.PauseAllSchedules
		}
		if err := call(ctx); err != nil {
			return err
		}
		p.Line("%s every schedule", verb)
		return p.JSON(scheduleChange{All: true, Paused: paused})
	}

	id := args[0]
	call := s.ResumeSchedule
	if paused {
		call = s.PauseSchedule
	}
	if err := call(ctx, id); err != nil {
		return err
	}
	p.Line("%s %s", verb, id)
	return p.JSON(scheduleChange{ID: id, Paused: paused})
}

// scheduleRow renders one list row. The At variant exists so the relative
// times are testable: "in 12m" is a function of now, and a test that reads
// the clock is a test that fails at midnight.
func scheduleRow(sc vc.Schedule) []string { return scheduleRowAt(sc, time.Now()) }

func scheduleRowAt(sc vc.Schedule, now time.Time) []string {
	return []string{
		sc.ID,
		orDash(truncate(sc.Name, nameWidth)),
		yesNo(sc.Enabled),
		rruleCell(sc.RRule),
		relTimeAt(sc.NextExecution, now),
		relTimeAt(sc.LastExecution, now),
	}
}
