package storage

import (
	"testing"

	"go.uber.org/zap"
)

func TestBundledVibeCheckIconsLoad(t *testing.T) {
	il := NewIconLoader(zap.NewNop())
	if err := il.LoadIcons(""); err != nil {
		t.Fatalf("LoadIcons failed: %v", err)
	}

	want := map[string]bool{"nail-biting": false, "nose-picking": false, "hair-pulling": false}
	for _, ic := range il.GetIcons() {
		if _, ok := want[ic.Id]; ok {
			want[ic.Id] = true
			if ic.Category != "health" {
				t.Errorf("icon %q: category = %q, want \"health\"", ic.Id, ic.Category)
			}
		}
	}
	for id, found := range want {
		if !found {
			t.Errorf("catalog missing icon id %q", id)
		}
		data, err := il.GetIconData(id)
		if err != nil {
			t.Errorf("GetIconData(%q) error: %v", id, err)
		}
		if len(data) == 0 {
			t.Errorf("GetIconData(%q) returned empty data", id)
		}
	}
}
