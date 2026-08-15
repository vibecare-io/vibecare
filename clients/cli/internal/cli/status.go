package cli

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/vibecare-io/vibecare/clients/cli/internal/cli/output"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

func init() { addCommand(statusCmd) }

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Report core reachability, version, scheduler and plugin tally",
	Long: "status is the first question: is core up, which build is it, is the\n" +
		"scheduler running, and how many plugins are healthy.\n\n" +
		"An unreachable core exits 2 but still prints everything that could be\n" +
		"learned — a status command that refuses to answer is useless exactly\n" +
		"when it is needed.",
	Args: cobra.NoArgs,
	RunE: runOffline(func(ctx context.Context, s *vc.Session, dialErr error, p *output.Printer) error {
		st := vc.Status{Addr: targetAddr()}
		if s != nil {
			st, _ = s.Status(ctx)
		} else {
			st.Error = dialErr.Error()
		}

		if err := p.JSON(st); err != nil {
			return err
		}
		printStatus(p, st)

		if st.Reachable {
			return nil
		}
		if dialErr != nil {
			return dialErr
		}
		// gRPC answered at dial time and has since dropped, so there is no
		// dial error to reuse; the connection state is the explanation.
		return vc.Unreachable(st.Addr, errors.New(st.Error))
	}),
}

func printStatus(p *output.Printer, st vc.Status) {
	p.KV([][2]string{
		{"addr", st.Addr},
		{"core", coreLine(st)},
		{"version", orUnknown(st.Version)},
		{"kernel", orUnknown(st.Kernel)},
		{"scheduler", schedulerLine(st.Scheduler)},
		{"plugins", tallyLine(st.Plugins)},
		{"client", clientLine()},
	})
}

// clientLine names which kind of client this is. A dev build carries
// `plugins rebuild`, which runs a program named by a file on disk; a release
// build does not compile that code at all. Which one you are holding is
// otherwise unanswerable short of trying the command and seeing whether it
// exists, so status says it outright.
func clientLine() string {
	if devBuild {
		return "dev build — plugins rebuild available"
	}
	return "release build"
}

// coreLine renders reachability plus its cause.
//
// Status.Error is written for the JSON contract, where it has to stand alone
// and therefore repeats the address. In the KV block the address is already
// the line above, so that prefix is dropped rather than printed twice.
func coreLine(st vc.Status) string {
	if st.Reachable {
		return "reachable"
	}
	cause := strings.TrimPrefix(st.Error, fmt.Sprintf("core unreachable at %s: ", st.Addr))
	if cause == "" {
		return "unreachable"
	}
	return "unreachable: " + cause
}

// orUnknown distinguishes "core did not tell us" from an empty string. Every
// field on Status is independently optional because core can be half up.
func orUnknown(s string) string {
	if s == "" {
		return "unknown"
	}
	return s
}

func schedulerLine(s *vc.Scheduler) string {
	if s == nil {
		return "unknown"
	}
	if !s.Running {
		return "stopped"
	}
	return "running"
}

// tallyLine names only the states that have members. Printing "0 failed" on
// a healthy system trains the reader to skip the line that matters.
func tallyLine(t vc.Tally) string {
	if t.Total == 0 {
		return "none"
	}
	parts := []string{fmt.Sprintf("%d total", t.Total)}
	for _, c := range []struct {
		n     int
		label string
	}{
		{t.Up, "up"},
		{t.Starting, "starting"},
		{t.Degraded, "degraded"},
		{t.Down, "down"},
		{t.Failed, "failed"},
	} {
		if c.n > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", c.n, c.label))
		}
	}
	return strings.Join(parts, ", ")
}
