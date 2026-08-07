// Tests for the record_detection action and stats rendering logic.
//
// Why not the plugin-todos subprocess-harness style: that harness
// (backend/cmd/plugin-todos/main_test.go) imports backend/internal/*
// packages and reaches pluginsdk's unexported newPlugin/start seams from
// inside package pluginsdk itself. plugins/vibecheck is a SEPARATE Go
// module (see go.mod's replace directive) and, as package main, can do
// neither: Go's internal-package rule blocks importing backend/internal/*
// from outside the backend module, and newPlugin/start are unexported so
// only pluginsdk's own test file can reach them.
//
// Instead, recordDetection and statsNodes in main.go are written against a
// small local `host` interface that *pluginsdk.HostClient satisfies
// structurally. That lets this file substitute a hand-rolled fakeHost —
// built only from pluginsdk's exported API (Record, Record.AsMap, Node,
// Kind/Text/Children) — without touching any unexported SDK internals.
package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"testing"

	"github.com/vibecare-io/vibecare/backend/pkg/pluginsdk"
)

// fakeHost is an in-memory stand-in for *pluginsdk.HostClient, satisfying
// the local `host` interface declared in main.go. It mirrors HostClient's
// own JSON-marshal-on-Store behavior exactly so records round-trip through
// Record.AsMap the same way they would against the real host.
type fakeHost struct {
	store map[string]string // key -> value_json
}

func newFakeHost() *fakeHost {
	return &fakeHost{store: make(map[string]string)}
}

func (f *fakeHost) Store(_ string, key string, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	f.store[key] = string(data)
	return nil
}

func (f *fakeHost) Query(_ string) ([]pluginsdk.Record, error) {
	recs := make([]pluginsdk.Record, 0, len(f.store))
	for k, v := range f.store {
		recs = append(recs, pluginsdk.Record{Key: k, ValueJSON: v})
	}
	return recs, nil
}

func TestRecordDetectionStoresBehaviorAndTimestamp(t *testing.T) {
	h := newFakeHost()

	if err := recordDetection(h, map[string]string{"behavior": "nose_picking"}); err != nil {
		t.Fatalf("recordDetection #1 failed: %v", err)
	}
	if err := recordDetection(h, map[string]string{"behavior": "nose_picking"}); err != nil {
		t.Fatalf("recordDetection #2 failed: %v", err)
	}
	if err := recordDetection(h, map[string]string{"behavior": "nail_biting"}); err != nil {
		t.Fatalf("recordDetection #3 failed: %v", err)
	}

	if len(h.store) != 3 {
		t.Fatalf("len(h.store) = %d, want 3", len(h.store))
	}

	counts := map[string]int{}
	for key, valueJSON := range h.store {
		rec := pluginsdk.Record{Key: key, ValueJSON: valueJSON}
		m, err := rec.AsMap()
		if err != nil {
			t.Fatalf("record %s did not decode: %v", key, err)
		}
		behavior, _ := m["behavior"].(string)
		if behavior == "" {
			t.Errorf("record %s missing behavior: %v", key, m)
		}
		ts, _ := m["ts"].(string)
		if ts == "" {
			t.Errorf("record %s missing/blank ts (default-to-now should have filled it): %v", key, m)
		}
		counts[behavior]++
	}

	if counts["nose_picking"] != 2 {
		t.Errorf("nose_picking count = %d, want 2", counts["nose_picking"])
	}
	if counts["nail_biting"] != 1 {
		t.Errorf("nail_biting count = %d, want 1", counts["nail_biting"])
	}
}

func TestRecordDetectionUsesProvidedTimestamp(t *testing.T) {
	h := newFakeHost()

	if err := recordDetection(h, map[string]string{"behavior": "nose_picking", "ts": "2026-01-01T00:00:00Z"}); err != nil {
		t.Fatalf("recordDetection failed: %v", err)
	}

	var valueJSON string
	for _, v := range h.store {
		valueJSON = v
	}
	rec := pluginsdk.Record{ValueJSON: valueJSON}
	m, err := rec.AsMap()
	if err != nil {
		t.Fatalf("record did not decode: %v", err)
	}
	if ts, _ := m["ts"].(string); ts != "2026-01-01T00:00:00Z" {
		t.Errorf("ts = %q, want the explicitly provided timestamp to be preserved", ts)
	}
}

func TestRecordDetectionIgnoresEmptyBehavior(t *testing.T) {
	h := newFakeHost()

	if err := recordDetection(h, map[string]string{"behavior": ""}); err != nil {
		t.Fatalf("recordDetection with empty behavior returned error: %v", err)
	}
	if err := recordDetection(h, map[string]string{}); err != nil {
		t.Fatalf("recordDetection with missing behavior key returned error: %v", err)
	}

	if len(h.store) != 0 {
		t.Errorf("len(h.store) = %d, want 0 — empty/missing behavior must not be stored", len(h.store))
	}
}

// countRowRE matches a stats "behavior: N" count row's text, e.g.
// "nose_picking: 2".
var countRowRE = regexp.MustCompile(`^(\S+): (\d+)$`)

func TestStatsNodesShowsPerBehaviorCounts(t *testing.T) {
	h := newFakeHost()
	for _, behavior := range []string{"nose_picking", "nose_picking", "nail_biting"} {
		if err := recordDetection(h, map[string]string{"behavior": behavior}); err != nil {
			t.Fatalf("recordDetection(%s) failed: %v", behavior, err)
		}
	}

	nodes := statsNodes(h)

	counts := map[string]int{}
	historyRows := 0
	for _, n := range nodes {
		if n.Kind != "row" || len(n.Children) != 1 || n.Children[0].Kind != "text" {
			t.Fatalf("unexpected node shape in statsNodes output: %+v", n)
		}
		text := n.Children[0].Text
		if text == "Detections" {
			continue // header row
		}
		if m := countRowRE.FindStringSubmatch(text); m != nil {
			var c int
			if _, err := fmt.Sscanf(m[2], "%d", &c); err != nil {
				t.Fatalf("failed to parse count from %q: %v", text, err)
			}
			counts[m[1]] = c
			continue
		}
		// Anything else is a recent-history row.
		historyRows++
	}

	if counts["nose_picking"] != 2 {
		t.Errorf("nose_picking count = %d, want 2", counts["nose_picking"])
	}
	if counts["nail_biting"] != 1 {
		t.Errorf("nail_biting count = %d, want 1", counts["nail_biting"])
	}
	// 3 detections were recorded, so 3 history rows are expected. Order is
	// intentionally not asserted: records come back from a map, so
	// statsNodes cannot guarantee history ordering.
	if historyRows != 3 {
		t.Errorf("historyRows = %d, want 3", historyRows)
	}
}

func TestStatsNodesWithNoDetectionsShowsOnlyHeader(t *testing.T) {
	h := newFakeHost()

	nodes := statsNodes(h)

	if len(nodes) != 1 {
		t.Fatalf("len(nodes) = %d, want 1 (header only) for an empty store", len(nodes))
	}
	if nodes[0].Children[0].Text != "Detections" {
		t.Errorf("nodes[0] text = %q, want %q", nodes[0].Children[0].Text, "Detections")
	}
}
