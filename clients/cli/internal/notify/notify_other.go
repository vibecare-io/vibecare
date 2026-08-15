//go:build !darwin && !linux

package notify

// No portable notifier worth shelling out to. --notify is accepted and
// silently does nothing rather than failing the command.
func newPlatform() Notifier { return Noop() }
