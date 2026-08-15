//go:build dev

package tui

// devTUI lets one test assert both sides of the build gate, so the release
// expectation and the dev expectation are written next to each other.
const devTUI = true
