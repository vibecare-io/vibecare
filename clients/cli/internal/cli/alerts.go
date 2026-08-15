package cli

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/vibecare-io/vibecare/clients/cli/internal/cli/output"
	"github.com/vibecare-io/vibecare/clients/cli/internal/notify"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

var (
	flagAlertsFollow bool
	flagAlertsNotify bool
)

func init() {
	f := alertsCmd.Flags()
	f.BoolVarP(&flagAlertsFollow, "follow", "f", false, "keep streaming as alerts arrive")
	f.BoolVar(&flagAlertsNotify, "notify", false, "also raise a desktop notification for each alert")
	addCommand(alertsCmd)
}

// alertSettle bounds how long a non-following run waits for the stream to
// hand over what it already has.
//
// Alerts are transient — core retains nothing — so "already queued" means
// "in flight between core and this process", and that arrives in microseconds
// on loopback. The window exists so a script gets the alerts rather than
// racing the stream setup, and it is short because the command's contract is
// that it returns.
const alertSettle = 250 * time.Millisecond

var alertsCmd = &cobra.Command{
	Use:   "alerts",
	Short: "Print alerts plugins push through core",
	Long: "alerts follows the UI intents plugins send core. They are transient —\n" +
		"core stores none of them — so this shows what arrives while it is\n" +
		"running, and nothing from before.\n\n" +
		"Without -f it prints whatever is already in flight and exits. With -f\n" +
		"it runs until interrupted, reconnecting on its own across a core\n" +
		"restart. Under --json each alert leaves as its own envelope: a stream\n" +
		"has no end, so there is no array for a consumer to wait on.",
	Args: cobra.NoArgs,
	RunE: run(watchAlerts),
}

func watchAlerts(ctx context.Context, s *vc.Session, p *output.Printer) error {
	alerts, err := s.WatchAlerts(ctx)
	if err != nil {
		return err
	}
	return emitAlerts(ctx, p, notify.New(flagAlertsNotify), alerts, flagAlertsFollow)
}

// emitAlerts drains alerts until the stream ends, the context is cancelled,
// or — when not following — the settle window closes.
//
// Cancellation is a success: Ctrl-C out of `alerts -f` means "stop watching",
// and exiting non-zero there would break every pipeline ending in one.
func emitAlerts(ctx context.Context, p *output.Printer, n notify.Notifier, alerts <-chan vc.Alert, follow bool) error {
	// A nil channel blocks forever, which is exactly the follow behaviour;
	// only the bounded case arms a timer.
	var settled <-chan time.Time
	if !follow {
		settled = time.After(alertSettle)
	}

	for {
		select {
		case <-ctx.Done():
			return nil
		case <-settled:
			return nil
		case a, ok := <-alerts:
			if !ok {
				return nil
			}
			if err := printAlert(p, a); err != nil {
				return err
			}
			notifyAlert(ctx, n, a)
		}
	}
}

func printAlert(p *output.Printer, a vc.Alert) error {
	if p.IsJSON() {
		return p.JSON(a)
	}
	// "%s" and never the line itself: alert text is plugin-supplied, and a
	// stray %d in a title must not be read as a verb.
	p.Line("%s", alertLine(a))
	return nil
}

// alertLine renders one alert as a single greppable line. Wall-clock time and
// not a relative offset: alerts arrive while the user is watching, so the
// useful question is "when", not "how long ago".
func alertLine(a vc.Alert) string {
	received := a.Received
	if received.IsZero() {
		received = time.Now()
	}

	parts := []string{
		received.Local().Format("15:04:05"),
		orDash(a.Plugin),
		orDash(level(a)),
		orDash(a.Title),
	}
	line := strings.Join(parts, "  ")
	if a.Body != "" {
		line += " — " + a.Body
	}
	for _, act := range a.Actions {
		// The label alone: the URL is plugin-relative and means nothing
		// without the kernel's ephemeral origin, which belongs in --json.
		line += " [" + act.Label + "]"
	}
	return line
}

// level defaults to info. The wire carries "info" or "warn", but a plugin
// that sends neither should still render as an alert rather than as a gap.
func level(a vc.Alert) string {
	if a.Level == "" {
		return "info"
	}
	return a.Level
}

// notifyAlert bridges to the desktop, when asked. A notifier that cannot draw
// is not a reason to stop printing alerts, so the failure leaves on stderr as
// an aside — never through the Printer, because a diagnostic that changed the
// --json contract or implied a non-zero exit would be a lie.
func notifyAlert(ctx context.Context, n notify.Notifier, a vc.Alert) {
	title := a.Title
	if a.Plugin != "" {
		title = a.Plugin + ": " + a.Title
	}
	err := n.Notify(ctx, notify.Notification{Title: title, Body: a.Body, Level: a.Level})
	if err != nil && ctx.Err() == nil {
		fmt.Fprintf(stderr, "notify: %v\n", err)
	}
}
