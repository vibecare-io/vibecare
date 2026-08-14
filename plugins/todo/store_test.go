package main

import (
	"path/filepath"
	"testing"
)

func newStore(t *testing.T) *Store {
	t.Helper()
	s, err := OpenStore(filepath.Join(t.TempDir(), "todo.json"))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestAddAndList(t *testing.T) {
	s := newStore(t)
	if got := s.List(); len(got) != 0 {
		t.Fatalf("new store has %d tasks", len(got))
	}

	task, err := s.Add("write the plan")
	if err != nil {
		t.Fatal(err)
	}
	if task.ID == "" || task.Title != "write the plan" || task.Done {
		t.Fatalf("task = %+v", task)
	}
	if got := s.List(); len(got) != 1 || got[0].ID != task.ID {
		t.Fatalf("list = %+v", got)
	}
}

func TestAddRejectsBlankTitle(t *testing.T) {
	s := newStore(t)
	if _, err := s.Add("   "); err == nil {
		t.Fatal("expected an error for a blank title")
	}
	if len(s.List()) != 0 {
		t.Fatal("blank task was stored anyway")
	}
}

func TestToggle(t *testing.T) {
	s := newStore(t)
	task, _ := s.Add("a")

	got, ok, err := s.Toggle(task.ID)
	if err != nil || !ok || !got.Done {
		t.Fatalf("toggle = %+v %v %v", got, ok, err)
	}
	got, _, _ = s.Toggle(task.ID)
	if got.Done {
		t.Fatal("second toggle should clear Done")
	}
	if _, ok, _ := s.Toggle("nope"); ok {
		t.Fatal("toggling an unknown id should report not-found")
	}
}

func TestDelete(t *testing.T) {
	s := newStore(t)
	task, _ := s.Add("a")
	ok, err := s.Delete(task.ID)
	if err != nil || !ok {
		t.Fatalf("delete = %v %v", ok, err)
	}
	if len(s.List()) != 0 {
		t.Fatal("task survived delete")
	}
	if ok, _ := s.Delete(task.ID); ok {
		t.Fatal("second delete should report not-found")
	}
}

// Uninstall is deleting one directory, and corruption is contained to one
// plugin — both only hold if state really is on disk in the data dir.
func TestStorePersistsAcrossReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "todo.json")
	s1, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	task, _ := s1.Add("survive me")

	s2, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	got := s2.List()
	if len(got) != 1 || got[0].ID != task.ID || got[0].Title != "survive me" {
		t.Fatalf("reopened store = %+v", got)
	}
}

func TestOpenStoreOnMissingFileStartsEmpty(t *testing.T) {
	s := newStore(t)
	if len(s.List()) != 0 {
		t.Fatal("missing file should start empty, not error")
	}
}
