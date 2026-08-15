//go:build !dev

package cli

// The release binary registers no rebuild command. This file exists so the
// distinction is visible from the package rather than only from a build
// invocation somewhere else — reading internal/cli should tell you that
// `plugins rebuild` is a dev-only surface.
func init() { devBuild = false }
