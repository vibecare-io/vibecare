// Package cli is the cobra front end: it parses argv, calls internal/vc, and
// hands the result to a Printer. It performs no I/O of its own and holds no
// state — everything it shows comes from core or from a log file on disk.
//
// Two rules shape every file here. Command bodies go through run() so that
// dialling, printing and the exit-code mapping are written once; and nothing
// but a Printer writes to stdout, because `--json` is a contract a script
// parses, not decoration.
package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/vibecare-io/vibecare/clients/cli/internal/cli/output"
	"github.com/vibecare-io/vibecare/clients/cli/internal/tui"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

// Global flags. They are package vars rather than being read back out of the
// cobra command because every subcommand file needs them and none of them
// should have to walk up to the root to ask.
var (
	flagAddr    string
	flagWebAddr string
	flagJSON    bool
	flagNoColor bool
	flagVerbose bool
	flagWait    time.Duration
)

// devBuild records whether this binary was built with -tags dev. It is set
// by exactly one of rebuild_dev.go / rebuild_stub.go, so `vibecare --help`
// and `status` can say which kind of build the user is holding — a question
// that otherwise has no answer short of trying a command and seeing whether
// it exists.
var devBuild bool

// stdout and stderr are indirected so the tests can run the real cobra tree
// and read what the process would have printed. Nothing else may write to
// the streams directly.
var (
	stdout io.Writer = os.Stdout
	stderr io.Writer = os.Stderr
)

// Defaults duplicated from internal/vc, whose own copies are unexported.
// `vibecare status` has to name the target it failed to reach, and when the
// dial fails there is no Session left to ask.
const (
	defaultAddr    = "127.0.0.1:50051"
	defaultWebAddr = "127.0.0.1:8080"
)

var rootCmd = &cobra.Command{
	Use:   "vibecare",
	Short: "Inspect and drive a running VibeCare core",
	Long: "vibecare is a client. It owns no state, no database and no scheduling\n" +
		"logic: everything it shows comes from core over gRPC, from the kernel's\n" +
		"HTTP surface, or from log files on disk.\n\n" +
		"With no subcommand it opens the full-screen TUI.",
	Args: cobra.NoArgs,
	// Errors and usage are printed by this package, not by cobra: under
	// --json a failure has to leave as an error envelope on stderr, and
	// stdout must stay parseable as a single document.
	SilenceErrors: true,
	SilenceUsage:  true,
	// The TUI is entered through runOffline for the same reason the roster
	// pane exists: a dead core is a state to render, not a reason to refuse
	// to start. It gets a nil Session and dials again on its own.
	RunE: runOffline(func(ctx context.Context, s *vc.Session, _ error, p *output.Printer) error {
		if p.IsJSON() {
			return vc.Usagef("--json has no meaning for the interactive TUI")
		}
		// Dial is handed over so the TUI can reconnect on its own. Started
		// with core down, s is nil and stays nil unless the TUI can dial
		// again — which is the difference between a window that says "core
		// is down" forever and one that picks up a `just run` in another
		// pane a second later.
		return tui.Run(ctx, s, tui.Options{
			Addr: targetAddr(),
			Dial: func(ctx context.Context) (*vc.Session, error) {
				return vc.Dial(ctx, dialOptions())
			},
		})
	}),
}

func init() {
	f := rootCmd.PersistentFlags()
	f.StringVar(&flagAddr, "addr", "", "core gRPC address (default "+defaultAddr+", or $VIBECARE_ADDR)")
	f.StringVar(&flagWebAddr, "web-addr", "", "core HTTP address (default "+defaultWebAddr+", or $VIBECARE_WEB_ADDR)")
	f.BoolVar(&flagJSON, "json", false, "emit the versioned JSON contract instead of tables")
	f.BoolVar(&flagNoColor, "no-color", false, "disable colour")
	f.BoolVarP(&flagVerbose, "verbose", "v", false, "explain what the client is doing on stderr")
	f.DurationVar(&flagWait, "wait", 0, "retry the connection with backoff for this long before giving up (e.g. 30s)")
}

// addCommand registers a subcommand. Each command file calls this from its
// own init(), so adding a command means adding one file.
func addCommand(c *cobra.Command) { rootCmd.AddCommand(c) }

// Execute parses os.Args and returns the process exit code. It never calls
// os.Exit itself: main owns that, and the tests own execute().
func Execute() int {
	// Interrupt has to reach the command bodies rather than the runtime:
	// `logs -f` and `alerts -f` block on a stream, and Ctrl-C there means
	// "stop following", which is a success, not a crash.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return execute(ctx, os.Args[1:])
}

func execute(ctx context.Context, args []string) int {
	rootCmd.SetArgs(args)
	rootCmd.SetContext(ctx)
	// Help is the one thing cobra may print for us, and it goes to stdout
	// because the user asked for it — `vibecare --help | less` has to work.
	// Its error writer is discarded instead: cobra reports a bad flag or an
	// unknown command there, and this package prints those itself, in the
	// shape --json promises. ExecuteC hands back the command that failed,
	// which is how the usage text below reaches stderr and only stderr.
	rootCmd.SetOut(stdout)
	rootCmd.SetErr(io.Discard)

	cmd, err := rootCmd.ExecuteC()
	if err == nil {
		return vc.ExitOK
	}

	var ce *commandError
	if errors.As(err, &ce) {
		// Already reported by run(), in the shape the user asked for.
		return exitCode(err)
	}
	// Anything else surfaced before a command body ran: an unknown command,
	// an unparseable flag, the wrong number of arguments.
	printer().Err(vc.Usagef("%v", err))
	if cmd != nil {
		fmt.Fprint(stderr, cmd.UsageString())
	}
	return vc.ExitUsage
}

// commandError marks a failure that came out of a command body and has
// already been printed. Cobra returns argument and flag errors as plain
// errors, so this wrapper is what tells the two apart.
type commandError struct{ err error }

func (e *commandError) Error() string { return e.err.Error() }
func (e *commandError) Unwrap() error { return e.err }

func exitCode(err error) int {
	if err == nil {
		return vc.ExitOK
	}
	var ce *commandError
	if errors.As(err, &ce) {
		return vc.ExitCode(ce.err)
	}
	return vc.ExitUsage
}

// report prints err and marks it as already-reported. Every command body
// returns through here.
func report(p *output.Printer, err error) error {
	if err == nil {
		return nil
	}
	p.Err(err)
	// Hints are for humans only. Under --json the error stream is part of
	// the contract, and a consumer parsing it must find one envelope there
	// and nothing else.
	if !p.IsJSON() && vc.ExitCode(err) == vc.ExitUnreachable {
		fmt.Fprint(stderr, unreachableHints())
	}
	return &commandError{err}
}

// unreachableHints turns "connection refused" into something the user can
// act on. Core being down is by far the most common failure this tool
// reports, and the three useful responses are always the same: start it,
// find out why it stopped, or wait for it to finish starting.
func unreachableHints() string {
	var b strings.Builder
	b.WriteString("\n  is core running?  just run\n")
	fmt.Fprintf(&b, "  check the log     %s\n", coreLogPath())
	// Suggesting --wait to someone who just used it implies a fix they have
	// not tried, when in fact they tried the right one and it still failed.
	if flagWait <= 0 {
		b.WriteString("  wait for it       re-run with --wait 30s\n")
	}
	return b.String()
}

// coreLogPath resolves the real path rather than printing a tilde, so the
// hint can be copied straight into an editor or a tail.
func coreLogPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return "~/.vibecare/logs/server.log"
	}
	return filepath.Join(home, ".vibecare", "logs", "server.log")
}

// printer builds the Printer the global flags describe. NO_COLOR is honoured
// alongside --no-color because it is the convention every other tool in a
// user's pipeline already follows.
func printer() *output.Printer {
	format := output.Table
	if flagJSON {
		format = output.JSON
	}
	color := !flagNoColor && os.Getenv("NO_COLOR") == ""
	return output.New(stdout, stderr, format, color)
}

// dialOptions resolves the target: the flag, else the environment, else the
// loopback default that vc fills in.
func dialOptions() vc.Options {
	return vc.Options{
		Addr:    firstNonEmpty(flagAddr, os.Getenv("VIBECARE_ADDR")),
		WebAddr: firstNonEmpty(flagWebAddr, os.Getenv("VIBECARE_WEB_ADDR")),
	}
}

// targetAddr is dialOptions().Addr with the default made explicit, for the
// places that must name the target in text.
func targetAddr() string {
	return firstNonEmpty(dialOptions().Addr, defaultAddr)
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

// session dials core using the global flags.
//
// The default is fail-fast, which is a deliberate choice for the agent case:
// `vibecare status --json` has to answer now, and a command that silently
// blocks for thirty seconds is worse than one that says core is down. --wait
// is how a human who just ran `just run` in another pane opts into patience.
func session(ctx context.Context) (*vc.Session, error) {
	if flagWait > 0 {
		verbosef("waiting up to %s for %s", flagWait, targetAddr())
		return vc.DialWait(ctx, dialOptions(), flagWait)
	}
	return vc.Dial(ctx, dialOptions())
}

// run wraps a command body: it dials, builds the printer, runs fn, and routes
// whatever comes back through the printer and the exit-code mapping.
//
// fn does not receive the command's arguments. A command that needs them
// closes over them at the call site:
//
//	RunE: func(cmd *cobra.Command, args []string) error {
//		return run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
//			return doThing(ctx, s, p, args[0])
//		})(cmd, args)
//	}
//
// which keeps this signature free of the argument-shape guesswork that every
// command would otherwise have to repeat.
func run(fn func(ctx context.Context, s *vc.Session, p *output.Printer) error) func(*cobra.Command, []string) error {
	return runOffline(func(ctx context.Context, s *vc.Session, dialErr error, p *output.Printer) error {
		if dialErr != nil {
			return dialErr
		}
		return fn(ctx, s, p)
	})
}

// runOffline is run() for the two commands that still have something true to
// say when core is down: `status`, whose job is to report exactly that, and
// `logs`, which reads files and is needed most when core has died. fn gets a
// nil Session and the dial error instead of never being called.
func runOffline(fn func(ctx context.Context, s *vc.Session, dialErr error, p *output.Printer) error) func(*cobra.Command, []string) error {
	return func(cmd *cobra.Command, _ []string) error {
		p := printer()
		ctx := cmd.Context()
		if ctx == nil {
			ctx = context.Background()
		}

		s, dialErr := session(ctx)
		if dialErr != nil {
			verbosef("dial %s: %v", targetAddr(), dialErr)
		} else {
			defer s.Close()
		}
		return report(p, fn(ctx, s, dialErr, p))
	}
}

// verbosef traces on stderr under -v. It bypasses the Printer deliberately:
// this is a diagnostic aside, never part of either output contract.
func verbosef(format string, a ...any) {
	if !flagVerbose {
		return
	}
	fmt.Fprintf(stderr, "» "+strings.TrimRight(format, "\n")+"\n", a...)
}
