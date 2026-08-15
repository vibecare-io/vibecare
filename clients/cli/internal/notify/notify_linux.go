//go:build linux

package notify

// notify-send ships with libnotify and is common but not guaranteed —
// headless boxes and minimal desktops lack it. cmdNotifier degrades to a
// noop after saying so once.
func newPlatform() Notifier {
	return &cmdNotifier{name: "notify-send", argv: notifySendArgs, run: execRun}
}
