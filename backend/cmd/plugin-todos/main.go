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
	"fmt"
	"log"

	"github.com/google/uuid"
	"github.com/vibecare-io/vibecare/backend/pkg/pluginsdk"
)

// todoText looks up the current text of the todo stored under id.
func todoText(c pluginsdk.Ctx, id string) (string, error) {
	recs, err := c.Host.Query("todos")
	if err != nil {
		return "", err
	}
	for _, r := range recs {
		if r.Key != id {
			continue
		}
		m, err := r.AsMap()
		if err != nil {
			return "", err
		}
		text, _ := m["text"].(string)
		return text, nil
	}
	return "", fmt.Errorf("todo %q not found", id)
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
		// its params (see Toggle in view.go), not its text — so the
		// existing text has to be looked up rather than trusted from in,
		// or completing a todo would blank it out.
		text, err := todoText(c, in["id"])
		if err != nil {
			return err
		}
		return c.Host.Store("todos", in["id"], map[string]any{
			"text": text,
			"done": true,
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
