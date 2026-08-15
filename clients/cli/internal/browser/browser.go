// Package browser opens a URL in the user's default browser.
//
// It knows nothing about VibeCare. The only thing it is careful about is
// that a URL is untrusted input as far as the shell is concerned: every
// implementation execs a binary with the URL as a single argv element, and
// none of them build a command string. A plugin id ends up in these URLs,
// and a shell string would make that id executable.
package browser

import (
	"context"
	"fmt"
	"os/exec"
	"runtime"
)

// runner is the seam the tests substitute so the suite never launches a
// browser on the machine running it.
type runner func(ctx context.Context, name string, args ...string) error

var run runner = func(ctx context.Context, name string, args ...string) error {
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	if err != nil {
		if len(out) > 0 {
			return fmt.Errorf("%s: %w: %s", name, err, out)
		}
		return fmt.Errorf("%s: %w", name, err)
	}
	return nil
}

// Open asks the desktop to open url. It returns once the opener has been
// handed the URL, not once a page has rendered — there is no portable way to
// learn the latter, and waiting on the browser process would block for as
// long as the browser lives.
func Open(ctx context.Context, url string) error {
	if url == "" {
		return fmt.Errorf("no URL to open")
	}
	name, args, err := command(url)
	if err != nil {
		return err
	}
	return run(ctx, name, args...)
}

// command picks the platform opener. Kept separate from Open so the choice
// is a pure function and can be asserted without executing anything.
func command(url string) (string, []string, error) {
	switch runtime.GOOS {
	case "darwin":
		return "open", []string{url}, nil
	case "windows":
		// rundll32 rather than `cmd /c start`, which treats & in a URL as a
		// command separator.
		return "rundll32", []string{"url.dll,FileProtocolHandler", url}, nil
	default:
		return "xdg-open", []string{url}, nil
	}
}
