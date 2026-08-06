package pluginsdk

import (
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
)

// Node is the SDK-side representation of one element in a plugin's
// declarative UI tree. Kind is one of the strings the Swift renderer
// switches on: "list", "row", "text", "toggle", "textField", "button"
// (plus "spacer", reserved but not built by any helper here yet).
type Node struct {
	Kind      string
	Text      string
	BoolValue bool
	Action    string
	Params    map[string]string
	Children  []Node
}

// View is a plugin's whole rendered UI, returned from an OnRender handler.
// It's built with List and converted to *pb.ViewDescriptor internally
// before being sent to Core.
type View struct {
	root Node
}

// List builds a View whose single root node is a "list" containing children.
func List(children ...Node) View {
	return View{root: Node{Kind: "list", Children: children}}
}

// Row groups children horizontally.
func Row(children ...Node) Node {
	return Node{Kind: "row", Children: children}
}

// Text renders a static string.
func Text(s string) Node {
	return Node{Kind: "text", Text: s}
}

// Toggle renders a boolean switch. id is carried in Params["id"] so the
// action handler receiving the resulting InvokeAction can identify which
// item was toggled.
func Toggle(on bool, action, id string) Node {
	return Node{
		Kind:      "toggle",
		BoolValue: on,
		Action:    action,
		Params:    map[string]string{"id": id},
	}
}

// TextField renders a single-line text input.
func TextField(placeholder, action string) Node {
	return Node{Kind: "textField", Text: placeholder, Action: action}
}

// Button renders a tappable button.
func Button(label, action string) Node {
	return Node{Kind: "button", Text: label, Action: action}
}

// toProto converts a View to the wire representation sent to Core.
func (v View) toProto() *pb.ViewDescriptor {
	return &pb.ViewDescriptor{Nodes: []*pb.Node{v.root.toProto()}}
}

// toProto converts a Node (and its children, recursively) to the wire
// representation.
func (n Node) toProto() *pb.Node {
	children := make([]*pb.Node, 0, len(n.Children))
	for _, c := range n.Children {
		children = append(children, c.toProto())
	}
	return &pb.Node{
		Kind:      n.Kind,
		Text:      n.Text,
		BoolValue: n.BoolValue,
		Action:    n.Action,
		Params:    n.Params,
		Children:  children,
	}
}
