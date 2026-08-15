package keymap

import (
	"strings"
	"testing"
)

// allCtx is every context the tables must answer for. A pane that reports a
// Ctx missing here would render an empty footer, so the list is asserted
// against Tabs below rather than trusted.
var allCtx = []Ctx{
	CtxOverview, CtxStatus, CtxLogs, CtxEvents, CtxAlerts,
	CtxSchedules, CtxRoutines, CtxActions, CtxManifest, CtxStats,
}

var allKinds = []SubjectKind{SubjectAll, SubjectCore, SubjectPlugin}

// Every table invariant has to hold in both focuses. A key that is unique
// on the sidebar but collides in the panel is still a broken binding.
var allFocus = []Focus{FocusSidebar, FocusDetail}

// A duplicate key is the one bug these tables can have that the compiler
// cannot catch: two groups in the same popup both claiming "s" makes one of
// them dead, and which one wins depends on iteration order.
func TestNoDuplicateKeyWithinContext(t *testing.T) {
	for _, f := range allFocus {
		for _, c := range allCtx {
			for _, k := range allKinds {
				seen := map[string]Binding{}
				for _, g := range All(c, k, f) {
					for _, b := range g.Bindings {
						for _, key := range b.Keys() {
							if prev, dup := seen[key]; dup {
								t.Errorf("ctx %s kind %s: key %q bound twice: %q and %q",
									c, k, key, prev.Action, b.Action)
								continue
							}
							seen[key] = b
						}
					}
				}
			}
		}
	}
}

// The footer is a shortcut for the transient, never a second source of
// truth. Anything it advertises must be reachable from the same tables the
// popup and the help screen render.
func TestFooterBindingsAreBound(t *testing.T) {
	for _, f := range allFocus {
		for _, c := range allCtx {
			for _, k := range allKinds {
				have := map[string]string{}
				for _, g := range All(c, k, f) {
					for _, b := range g.Bindings {
						have[b.Key] = b.Action
					}
				}
				for _, b := range Footer(c, f) {
					action, ok := have[b.Key]
					if !ok {
						t.Errorf("ctx %s kind %s: footer key %q is not bound at all", c, k, b.Key)
						continue
					}
					if action != b.Action {
						t.Errorf("ctx %s kind %s: footer key %q means %q, All() says %q",
							c, k, b.Key, b.Action, action)
					}
				}
			}
		}
	}
}

func TestEveryBindingIsComplete(t *testing.T) {
	for _, f := range allFocus {
		for _, c := range allCtx {
			for _, k := range allKinds {
				for _, g := range All(c, k, f) {
					if g.Title == "" {
						t.Errorf("ctx %s kind %s: group with no title", c, k)
					}
					if len(g.Bindings) == 0 {
						t.Errorf("ctx %s kind %s: group %q is empty", c, k, g.Title)
					}
					for _, b := range g.Bindings {
						if b.Key == "" || b.Desc == "" || b.Action == "" {
							t.Errorf("ctx %s kind %s group %q: incomplete binding %+v", c, k, g.Title, b)
						}
					}
				}
			}
		}
	}
}

// Tabs and contexts are one table read two ways: the tab strip renders the
// names, the keymap renders the bindings for whichever tab is selected.
func TestTabsCoverEveryContext(t *testing.T) {
	covered := map[Ctx]bool{}
	for _, k := range allKinds {
		tabs := Tabs(k)
		if len(tabs) == 0 {
			t.Fatalf("kind %s has no tabs", k)
		}
		for _, tab := range tabs {
			if tab.Name == "" {
				t.Errorf("kind %s: tab with empty name", k)
			}
			covered[tab.Ctx] = true
			if len(Footer(tab.Ctx, FocusDetail)) == 0 {
				t.Errorf("kind %s tab %s: ctx %q has an empty footer", k, tab.Name, tab.Ctx)
			}
		}
	}
	for _, c := range allCtx {
		if !covered[c] {
			t.Errorf("ctx %q is not reachable from any tab", c)
		}
	}
}

// Every tab must be jumpable from the transient, otherwise the popup lies
// about what the subject can show.
func TestViewGroupMatchesTabs(t *testing.T) {
	for _, k := range allKinds {
		tabs := Tabs(k)
		var jumps []Binding
		for _, g := range For(CtxLogs, k, FocusDetail) {
			for _, b := range g.Bindings {
				if strings.HasPrefix(b.Action, ActionTabJump) {
					jumps = append(jumps, b)
				}
			}
		}
		if len(jumps) != len(tabs) {
			t.Fatalf("kind %s: %d tabs but %d jump bindings", k, len(tabs), len(jumps))
		}
		for i, b := range jumps {
			idx, ok := TabIndex(b.Action)
			if !ok || idx != i {
				t.Errorf("kind %s: jump %q resolves to %d, want %d", k, b.Action, idx, i)
			}
		}
	}
}

func TestLookup(t *testing.T) {
	tests := []struct {
		name   string
		ctx    Ctx
		kind   SubjectKind
		focus  Focus
		key    string
		want   string
		wantOK bool
	}{
		{"global quit", CtxLogs, SubjectAll, FocusDetail, "q", ActionQuit, true},
		{"transient", CtxOverview, SubjectPlugin, FocusSidebar, " ", ActionTransient, true},
		{"ctx binding", CtxLogs, SubjectCore, FocusDetail, "f", ActionLogFollow, true},
		{"restart is plugin-only", CtxLogs, SubjectPlugin, FocusDetail, "r", ActionPluginRestart, true},
		{"refresh where there is no plugin", CtxLogs, SubjectAll, FocusDetail, "r", ActionRefresh, true},
		{"unbound", CtxManifest, SubjectPlugin, FocusDetail, "ctrl+x", "", false},
		{"ctx binding does not leak", CtxManifest, SubjectPlugin, FocusDetail, "f", "", false},

		// The focus dimension: the same physical key, two meanings. This is
		// the whole reason Lookup takes a Focus, so it is asserted directly
		// rather than only through the model.
		{"j moves subject on the sidebar", CtxOverview, SubjectAll, FocusSidebar, "j", ActionSubjectNext, true},
		{"j scrolls in the panel", CtxLogs, SubjectAll, FocusDetail, "j", ActionSelectNext, true},
		{"l enters the panel", CtxOverview, SubjectAll, FocusSidebar, "l", ActionFocusDetail, true},
		{"l walks tabs in the panel", CtxLogs, SubjectAll, FocusDetail, "l", ActionTabNext, true},
		{"h is prev tab in the panel", CtxLogs, SubjectAll, FocusDetail, "h", ActionTabPrev, true},
		{"tab enters the panel", CtxOverview, SubjectAll, FocusSidebar, "tab", ActionFocusDetail, true},
		{"tab leaves the panel", CtxLogs, SubjectAll, FocusDetail, "tab", ActionFocusSidebar, true},
		{"arrows still work", CtxLogs, SubjectAll, FocusDetail, "right", ActionTabNext, true},
		{"pane keys are not offered from the sidebar", CtxLogs, SubjectAll, FocusSidebar, "f", "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			b, ok := Lookup(tt.ctx, tt.kind, tt.focus, tt.key)
			if ok != tt.wantOK {
				t.Fatalf("Lookup(%q) ok=%v, want %v", tt.key, ok, tt.wantOK)
			}
			if ok && b.Action != tt.want {
				t.Errorf("Lookup(%q) = %q, want %q", tt.key, b.Action, tt.want)
			}
		})
	}
}

// Callers hold the returned groups while rendering; they must not be able to
// scribble on the tables every other surface reads from.
func TestForReturnsACopy(t *testing.T) {
	got := For(CtxLogs, SubjectPlugin, FocusDetail)
	got[0].Bindings[0].Desc = "clobbered"
	again := For(CtxLogs, SubjectPlugin, FocusDetail)
	if again[0].Bindings[0].Desc == "clobbered" {
		t.Fatal("For() handed out the shared table")
	}
}

// The popup is a subset of what is bound, never a superset: it may choose
// not to advertise movement, but it must never offer a key that does
// nothing.
func TestPopupIsASubsetOfWhatIsBound(t *testing.T) {
	for _, f := range allFocus {
		for _, c := range allCtx {
			for _, k := range allKinds {
				bound := map[string]bool{}
				for _, g := range All(c, k, f) {
					for _, b := range g.Bindings {
						for _, key := range b.Keys() {
							bound[key] = true
						}
					}
				}
				for _, g := range For(c, k, f) {
					for _, b := range g.Bindings {
						for _, key := range b.Keys() {
							if !bound[key] {
								t.Errorf("ctx %s kind %s focus %s: popup offers %q, which is not bound",
									c, k, f, key)
							}
						}
					}
				}
			}
		}
	}
}
