//go:build dev

package keymap

// ActionPluginRebuild is a dev-only verb: it runs the build command a
// plugin's manifest declares. The binding is added here rather than sitting
// in the main table behind a flag, so a release build genuinely does not
// have it — the transient cannot offer a key that the binary has no handler
// for, which is the invariant the popup tests enforce.
const ActionPluginRebuild = "plugin.rebuild"

// devTables records that the tables carry dev-only bindings, so the README
// check knows it is looking at a superset of the shipped surface.
const devTables = true

func init() {
	g := subjectGroups[SubjectPlugin]
	g.Bindings = append(g.Bindings, Binding{
		Key: "b", Desc: "rebuild", Action: ActionPluginRebuild,
		Help: "run the manifest's build command, then restart",
	})
	subjectGroups[SubjectPlugin] = g
}
