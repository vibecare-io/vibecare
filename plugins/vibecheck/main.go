// Command plugin-vibecheck is the VibeCheck analytics plugin: it stores
// BFRB (body-focused repetitive behavior) detection events reported by the
// native detection engine (see docs/../.superpowers/sdd for the detector
// design) and renders simple stats in the Plugins sidebar.
//
// This is the Task 9 scaffold: a minimal render-only plugin that proves the
// build/install spine end-to-end. The record_detection action handler and
// real stats view arrive in Task 10.
//
// Like every plugin built with pluginsdk, this process must never write to
// stdout — the SDK owns the single "host:port" handshake line printed by
// Run. Any diagnostic output here goes through the standard log package,
// which defaults to stderr.
package main

import (
	"log"

	"github.com/vibecare-io/vibecare/backend/pkg/pluginsdk"
)

func main() {
	p := pluginsdk.New()

	p.OnRender("main", func(c pluginsdk.Ctx) pluginsdk.View {
		return pluginsdk.List(
			pluginsdk.Row(pluginsdk.Text("No detections yet.")),
		)
	})

	log.Fatal(p.Run())
}
