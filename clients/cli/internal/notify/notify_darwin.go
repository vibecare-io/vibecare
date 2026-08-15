//go:build darwin

package notify

// osascript is present on every macOS install, so there is nothing to
// probe for at construction time; a missing binary is handled the same way
// as on any other platform, once, at the first Notify.
func newPlatform() Notifier {
	return &cmdNotifier{name: "osascript", argv: osascriptArgs, run: execRun}
}
