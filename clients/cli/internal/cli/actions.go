package cli

import (
	"context"
	"sort"

	"github.com/spf13/cobra"

	"github.com/vibecare-io/vibecare/clients/cli/internal/cli/output"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

var flagActionProfile string

func init() {
	actionsCmd.AddCommand(
		actionsLsCmd,
		actionsShowCmd,
		actionsRunCmd,
		actionsTypesCmd,
	)
	addCommand(actionsCmd)
}

var actionsCmd = newActionsListCmd("actions")

var actionsLsCmd = newActionsListCmd("ls")

func newActionsListCmd(use string) *cobra.Command {
	c := &cobra.Command{
		Use:   use,
		Short: "List actions",
		Long: "actions are the individual units of work a routine performs. There is\n" +
			"deliberately no --type filter: the list is small, grep is better at\n" +
			"filtering, and the legal values live in a .proto the user cannot see.\n" +
			"`actions types` prints them instead.",
		Args: cobra.NoArgs,
		RunE: run(listActions),
	}
	c.Flags().StringVar(&flagActionProfile, "profile", "", "list actions of this profile (default: the server's)")
	return c
}

func listActions(ctx context.Context, s *vc.Session, p *output.Printer) error {
	actions, err := s.ListActions(ctx, flagActionProfile)
	if err != nil {
		return err
	}
	if actions == nil {
		actions = []vc.Action{}
	}
	if err := p.JSON(actions); err != nil {
		return err
	}

	rows := make([][]string, 0, len(actions))
	for _, a := range actions {
		rows = append(rows, []string{
			a.ID,
			orDash(truncate(a.Name, nameWidth)),
			orDash(a.Type),
			yesNo(a.Enabled),
			orDash(truncate(a.Notes, notesWidth)),
		})
	}
	p.Table([]string{"ID", "NAME", "TYPE", "ENABLED", "NOTES"}, rows)
	return nil
}

var actionsShowCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show one action with its parameters",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
			a, err := s.GetAction(ctx, args[0])
			if err != nil {
				return err
			}
			if err := p.JSON(a); err != nil {
				return err
			}
			p.KV([][2]string{
				{"id", a.ID},
				{"name", orDash(a.Name)},
				{"type", orDash(a.Type)},
				{"enabled", yesNo(a.Enabled)},
				{"profile", orDash(a.ProfileID)},
				{"notes", orDash(a.Notes)},
			})
			if len(a.Params) > 0 {
				p.Line("")
				p.Table([]string{"PARAMETER", "VALUE"}, paramRows(a.Params))
			}
			return nil
		})(cmd, args)
	},
}

var actionsRunCmd = &cobra.Command{
	Use:   "run <id>",
	Short: "Execute one action now",
	Long: "run executes the action on its own, outside any routine.\n\n" +
		"An action that reports failure exits non-zero even though the RPC\n" +
		"succeeded: a notification that never fired is not a success, and a\n" +
		"script must not have to parse the result string to find that out.",
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
			result, err := s.RunAction(ctx, args[0])
			if err != nil {
				return err
			}
			if err := p.JSON(actionRun{ID: args[0], Result: result}); err != nil {
				return err
			}
			p.Line("ran %s", args[0])
			if result != "" {
				p.Line("%s", result)
			}
			return nil
		})(cmd, args)
	},
}

// actionRun is the --json body of a run: the id the caller passed plus
// whatever the action returned, as named fields rather than a bare string.
type actionRun struct {
	ID     string `json:"action_id"`
	Result string `json:"result,omitempty"`
}

var actionsTypesCmd = &cobra.Command{
	Use:   "types",
	Short: "List the action types core accepts",
	Long: "types prints the identifiers, not the human names: the identifier is\n" +
		"what an action carries and what a caller passes back in.",
	Args: cobra.NoArgs,
	RunE: run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
		types, err := s.ActionTypes(ctx)
		if err != nil {
			return err
		}
		if types == nil {
			types = []string{}
		}
		if err := p.JSON(types); err != nil {
			return err
		}

		rows := make([][]string, 0, len(types))
		for _, t := range types {
			rows = append(rows, []string{t})
		}
		p.Table([]string{"TYPE"}, rows)
		return nil
	}),
}

// paramRows renders an action's parameters in key order. Go randomises map
// iteration, and a detail view that reorders itself between runs is one
// nobody can diff.
func paramRows(params map[string]string) [][]string {
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	rows := make([][]string, 0, len(keys))
	for _, k := range keys {
		rows = append(rows, []string{k, params[k]})
	}
	return rows
}
