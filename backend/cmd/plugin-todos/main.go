// Command plugin-todos is the reference VibeCare plugin: a minimal todo
// list built entirely on pluginsdk. It exists to prove the plugin spine
// end-to-end with a real subprocess (see main_test.go) and as a worked
// example for future plugin authors.
//
// Like every plugin built with pluginsdk, this process must never write to
// stdout — the SDK owns the single "host:port" handshake line printed by
// Run. Any diagnostic output here goes through the standard log package,
// which defaults to stderr.
package main

import (
	"log"

	"github.com/google/uuid"
	"github.com/vibecare-io/vibecare/backend/pkg/pluginsdk"
)

// todoRecord looks up the current text and done state of the todo stored
// under id. found is false (with a nil err) when no record with that id
// exists — a distinct case from a genuine Query/decode error, so callers
// can tell "no-op, nothing to do" apart from "something actually broke".
func todoRecord(c pluginsdk.Ctx, id string) (text string, done bool, found bool, err error) {
	recs, err := c.Host.Query("todos")
	if err != nil {
		return "", false, false, err
	}
	for _, r := range recs {
		if r.Key != id {
			continue
		}
		m, err := r.AsMap()
		if err != nil {
			return "", false, false, err
		}
		text, _ := m["text"].(string)
		done, _ := m["done"].(bool)
		return text, done, true, nil
	}
	return "", false, false, nil
}

func main() {
	p := pluginsdk.New()

	p.OnAction("add_todo", func(c pluginsdk.Ctx, in map[string]string) error {
		return c.Host.Store("todos", uuid.New().String(), map[string]any{
			"text": in["text"],
			"done": false,
		})
	})

	p.OnAction("complete_todo", func(c pluginsdk.Ctx, in map[string]string) error {
		// The Toggle that triggers this action only carries the row's id in
		// its params (see Toggle in view.go), not its text or current done
		// state — so both have to be looked up rather than trusted from in.
		// This action name is a misnomer carried over from v0 (it now
		// toggles, not just completes): flip done, and preserve text so
		// completing a todo never blanks it out. If the id can't be found
		// (e.g. deleted from another client concurrently), treat it as a
		// no-op rather than creating a blank record under a stale id.
		text, done, found, err := todoRecord(c, in["id"])
		if err != nil {
			return err
		}
		if !found {
			return nil
		}
		return c.Host.Store("todos", in["id"], map[string]any{
			"text": text,
			"done": !done,
		})
	})

	p.OnAction("delete_todo", func(c pluginsdk.Ctx, in map[string]string) error {
		return c.Host.Delete("todos", in["id"])
	})

	p.OnRender("main", func(c pluginsdk.Ctx) pluginsdk.View {
		recs, _ := c.Host.Query("todos")

		rows := []pluginsdk.Node{pluginsdk.Row(pluginsdk.TextField("New todo…", "add_todo"))}
		for _, r := range recs {
			m, err := r.AsMap()
			if err != nil {
				continue
			}
			done, _ := m["done"].(bool)
			text, _ := m["text"].(string)
			rows = append(rows, pluginsdk.Row(
				pluginsdk.Toggle(done, "complete_todo", r.Key),
				pluginsdk.Text(text),
				pluginsdk.Button("✕", "delete_todo", r.Key),
			))
		}

		return pluginsdk.List(rows...)
	})

	log.Fatal(p.Run())
}
