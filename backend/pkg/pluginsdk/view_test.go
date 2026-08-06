package pluginsdk

import "testing"

// TestViewBuildersConvertToProto verifies that the small builder DSL
// (List/Row/Text/Toggle) produces the exact *pb.ViewDescriptor node tree
// Core (and eventually the Swift renderer) expects: a single root "list"
// node whose Children mirror the builder calls, with kind/text/bool_value/
// action/params mapped per field.
func TestViewBuildersConvertToProto(t *testing.T) {
	v := List(Row(Text("a"), Toggle(true, "complete_todo", "1")))

	got := v.toProto()

	if len(got.GetNodes()) != 1 {
		t.Fatalf("Nodes = %d, want 1 root node", len(got.GetNodes()))
	}
	root := got.GetNodes()[0]
	if root.GetKind() != "list" {
		t.Errorf("root.Kind = %q, want %q", root.GetKind(), "list")
	}
	if len(root.GetChildren()) != 1 {
		t.Fatalf("root.Children = %d, want 1", len(root.GetChildren()))
	}

	row := root.GetChildren()[0]
	if row.GetKind() != "row" {
		t.Errorf("row.Kind = %q, want %q", row.GetKind(), "row")
	}
	if len(row.GetChildren()) != 2 {
		t.Fatalf("row.Children = %d, want 2", len(row.GetChildren()))
	}

	text := row.GetChildren()[0]
	if text.GetKind() != "text" {
		t.Errorf("text.Kind = %q, want %q", text.GetKind(), "text")
	}
	if text.GetText() != "a" {
		t.Errorf("text.Text = %q, want %q", text.GetText(), "a")
	}

	toggle := row.GetChildren()[1]
	if toggle.GetKind() != "toggle" {
		t.Errorf("toggle.Kind = %q, want %q", toggle.GetKind(), "toggle")
	}
	if !toggle.GetBoolValue() {
		t.Error("toggle.BoolValue = false, want true")
	}
	if toggle.GetAction() != "complete_todo" {
		t.Errorf("toggle.Action = %q, want %q", toggle.GetAction(), "complete_todo")
	}
	if toggle.GetParams()["id"] != "1" {
		t.Errorf("toggle.Params[id] = %q, want %q", toggle.GetParams()["id"], "1")
	}
}

// TestTextFieldAndButtonKinds verifies the remaining builders map to the
// exact kind strings the Swift renderer switches on.
func TestTextFieldAndButtonKinds(t *testing.T) {
	tf := TextField("New item", "add_item")
	if tf.Kind != "textField" {
		t.Errorf("TextField kind = %q, want %q", tf.Kind, "textField")
	}
	if tf.Text != "New item" {
		t.Errorf("TextField text = %q, want %q", tf.Text, "New item")
	}
	if tf.Action != "add_item" {
		t.Errorf("TextField action = %q, want %q", tf.Action, "add_item")
	}

	btn := Button("Add", "add_item")
	if btn.Kind != "button" {
		t.Errorf("Button kind = %q, want %q", btn.Kind, "button")
	}
	if btn.Text != "Add" {
		t.Errorf("Button text = %q, want %q", btn.Text, "Add")
	}
	if btn.Action != "add_item" {
		t.Errorf("Button action = %q, want %q", btn.Action, "add_item")
	}
	if btn.Params != nil {
		t.Errorf("2-arg Button Params = %v, want nil (backward compatibility: no id given)", btn.Params)
	}

	// 3-arg form: an id (e.g. a row's record key) is carried in Params["id"],
	// the same convention Toggle uses, so delete_todo-style handlers can
	// identify which row a button click came from.
	btnWithID := Button("✕", "delete_todo", "abc")
	if btnWithID.Kind != "button" {
		t.Errorf("Button(with id) kind = %q, want %q", btnWithID.Kind, "button")
	}
	if btnWithID.Action != "delete_todo" {
		t.Errorf("Button(with id) action = %q, want %q", btnWithID.Action, "delete_todo")
	}
	if btnWithID.Params["id"] != "abc" {
		t.Errorf("Button(with id) Params[id] = %q, want %q", btnWithID.Params["id"], "abc")
	}
}
