// Command plugin-vibecheck is the VibeCheck analytics plugin: it stores
// BFRB (body-focused repetitive behavior) detection events reported by the
// native detection engine (see docs/../.superpowers/sdd for the detector
// design) and renders simple stats in the Plugins sidebar.
//
// record_detection stores {behavior, ts} under the "detections" collection
// via Host.Store; the "main" view queries that collection back and renders
// per-behavior counts plus a recent-history list.
//
// Like every plugin built with pluginsdk, this process must never write to
// stdout — the SDK owns the single "host:port" handshake line printed by
// Run. Any diagnostic output here goes through the standard log package,
// which defaults to stderr.
package main

import (
	"fmt"
	"log"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/vibecare-io/vibecare/backend/pkg/pluginsdk"
)

// host is the subset of *pluginsdk.HostClient this plugin depends on.
// Declaring it locally (rather than depending on *pluginsdk.HostClient
// directly) lets tests substitute a fake in-memory implementation built
// only from pluginsdk's exported API — *pluginsdk.HostClient satisfies
// this interface structurally, no adapter needed.
type host interface {
	Store(collection, key string, v any) error
	Query(collection string) ([]pluginsdk.Record, error)
}

// recordDetection stores a single BFRB detection event under the
// "detections" collection, keyed by a fresh UUID. A missing/empty behavior
// is treated as a malformed report and silently ignored rather than
// stored. A missing ts defaults to now (UTC, RFC3339).
func recordDetection(h host, in map[string]string) error {
	behavior := in["behavior"]
	if behavior == "" {
		return nil
	}
	ts := in["ts"]
	if ts == "" {
		ts = time.Now().UTC().Format(time.RFC3339)
	}
	return h.Store("detections", uuid.New().String(), map[string]any{
		"behavior": behavior,
		"ts":       ts,
	})
}

// statsNodes builds the "main" view's rows: a header, one "behavior: N"
// count row per distinct behavior (sorted for determinism), then a recent
// -history row per stored detection. Records come back from Query in
// unspecified order (map iteration under the hood), so history rows are
// not guaranteed to be in any particular order — only the last 10 seen are
// shown.
func statsNodes(h host) []pluginsdk.Node {
	recs, _ := h.Query("detections")

	counts := map[string]int{}
	type row struct{ behavior, ts string }
	var recent []row
	for _, r := range recs {
		m, err := r.AsMap()
		if err != nil {
			continue
		}
		b, _ := m["behavior"].(string)
		ts, _ := m["ts"].(string)
		counts[b]++
		recent = append(recent, row{b, ts})
	}

	nodes := []pluginsdk.Node{pluginsdk.Row(pluginsdk.Text("Detections"))}

	behaviors := make([]string, 0, len(counts))
	for b := range counts {
		behaviors = append(behaviors, b)
	}
	sort.Strings(behaviors)
	for _, b := range behaviors {
		nodes = append(nodes, pluginsdk.Row(pluginsdk.Text(fmt.Sprintf("%s: %d", b, counts[b]))))
	}

	// Recent history, newest last (records are unordered; show last 10 seen).
	start := 0
	if len(recent) > 10 {
		start = len(recent) - 10
	}
	for _, r := range recent[start:] {
		nodes = append(nodes, pluginsdk.Row(pluginsdk.Text(fmt.Sprintf("%s  %s", r.ts, r.behavior))))
	}

	return nodes
}

func main() {
	p := pluginsdk.New()

	p.OnAction("record_detection", func(c pluginsdk.Ctx, in map[string]string) error {
		return recordDetection(c.Host, in)
	})

	p.OnRender("main", func(c pluginsdk.Ctx) pluginsdk.View {
		return pluginsdk.List(statsNodes(c.Host)...)
	})

	log.Fatal(p.Run())
}
