//go:build !dev

package keymap

// ActionPluginRebuild is declared in both builds so handlers can switch on
// it without their own build tags; only the dev build ever binds a key to
// it, so in a release binary nothing can produce it.
const ActionPluginRebuild = "plugin.rebuild"

const devTables = false
