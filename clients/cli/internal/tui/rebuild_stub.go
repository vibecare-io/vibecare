//go:build !dev

package tui

import tea "github.com/charmbracelet/bubbletea"

// rebuildCmd does nothing in a release build: no key is bound to the rebuild
// action, so nothing can reach this. It exists only so app.go's handler
// compiles without a build tag of its own — keeping the tag at the edges
// rather than sprinkled through the switch that dispatches every action.
func (m model) rebuildCmd(string) tea.Cmd { return nil }
