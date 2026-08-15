package cli

import (
	"context"

	"github.com/spf13/cobra"

	"github.com/vibecare-io/vibecare/clients/cli/internal/browser"
	"github.com/vibecare-io/vibecare/clients/cli/internal/cli/output"
	"github.com/vibecare-io/vibecare/clients/cli/internal/vc"
)

func init() {
	pluginsCmd.AddCommand(pluginsURLCmd, pluginsOpenCmd)
}

// tokenWarning is repeated in both commands' help on purpose. The URL is not
// a plain address — it carries a live session token — and the one place a
// user is guaranteed to look before pasting it somewhere is the help for the
// command that printed it.
const tokenWarning = "The URL carries a one-time session token as ?vc=<token>. Core swaps it for\n" +
	"an HttpOnly cookie on first load and redirects it out of the address bar,\n" +
	"so it is safe in a browser and worth not pasting anywhere public. It is\n" +
	"minted fresh every time core starts, so a saved URL stops working."

var pluginsURLCmd = &cobra.Command{
	Use:   "url <id>",
	Short: "Print the authenticated URL of a plugin's UI",
	Long: "url resolves the address that opens a plugin's own page: the kernel's\n" +
		"ephemeral origin, the plugin's proxied path, and the session token.\n" +
		"None of the three are guessable, which is why this exists.\n\n" +
		tokenWarning + "\n\n" +
		"Printing rather than opening is the scriptable half: pipe it to a\n" +
		"browser, a curl, or read it in an agent. `plugins open` is the same\n" +
		"URL handed straight to the desktop.",
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
			u, err := s.PluginURL(ctx, args[0])
			if err != nil {
				return err
			}
			p.Line("%s", u)
			return p.JSON(pluginURL{ID: args[0], URL: u})
		})(cmd, args)
	},
}

var pluginsOpenCmd = &cobra.Command{
	Use:   "open <id>",
	Short: "Open a plugin's UI in the default browser",
	Long: "open resolves the same URL as `plugins url` and hands it to the\n" +
		"desktop's opener — open(1) on macOS, xdg-open on Linux.\n\n" +
		tokenWarning + "\n\n" +
		"It returns as soon as the opener has the URL, not when a page has\n" +
		"rendered: there is no portable way to observe the latter, and waiting\n" +
		"on the browser process would block for as long as the browser lives.",
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return run(func(ctx context.Context, s *vc.Session, p *output.Printer) error {
			u, err := s.PluginURL(ctx, args[0])
			if err != nil {
				return err
			}
			if err := browser.Open(ctx, u); err != nil {
				return vc.Wrap(err, "open %s in a browser", args[0])
			}
			p.Line("opened %s", args[0])
			return p.JSON(pluginOpened{ID: args[0], URL: u, Opened: true})
		})(cmd, args)
	},
}

// pluginURL and pluginOpened are typed --json bodies rather than bare
// strings, so a consumer reads a named field instead of pattern-matching a
// sentence. Neither is folded into `plugins --json`: that command is run
// constantly and dumping a live token into every roster listing would put
// the secret in far more logs than anyone intended.
type pluginURL struct {
	ID  string `json:"id"`
	URL string `json:"url"`
}

type pluginOpened struct {
	ID     string `json:"id"`
	URL    string `json:"url"`
	Opened bool   `json:"opened"`
}
