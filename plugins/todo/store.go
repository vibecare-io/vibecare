package main

import (
    "encoding/json"
    "errors"
    "fmt"
    "os"
    "strings"
    "sync"
    "time"
)

// Task is one item. IDs are assigned by the store.
type Task struct {
    ID      string    `json:"id"`
    Title   string    `json:"title"`
    Done    bool      `json:"done"`
    Created time.Time `json:"created"`
}

// Store is a JSON file. Plugins own their storage and pick their own store;
// the reference plugin picks the smallest thing that works, so it
// demonstrates the contract rather than a database.
type Store struct {
    mu    sync.Mutex
    path  string
    next  int
    tasks []Task
}

func OpenStore(path string) (*Store, error) {
    s := &Store{path: path}
    b, err := os.ReadFile(path)
    if errors.Is(err, os.ErrNotExist) {
        return s, nil // fresh install
    }
    if err != nil {
        return nil, fmt.Errorf("read store: %w", err)
    }
    if len(b) == 0 {
        return s, nil
    }
    if err := json.Unmarshal(b, &s.tasks); err != nil {
        return nil, fmt.Errorf("parse store %s: %w", path, err)
    }
    for _, t := range s.tasks {
        var n int
        if _, err := fmt.Sscanf(t.ID, "t%d", &n); err == nil && n >= s.next {
            s.next = n + 1
        }
    }
    return s, nil
}

func (s *Store) List() []Task {
    s.mu.Lock()
    defer s.mu.Unlock()
    out := make([]Task, len(s.tasks))
    copy(out, s.tasks)
    return out
}

func (s *Store) Add(title string) (Task, error) {
    title = strings.TrimSpace(title)
    if title == "" {
        return Task{}, errors.New("title is required")
    }
    s.mu.Lock()
    defer s.mu.Unlock()
    t := Task{ID: fmt.Sprintf("t%d", s.next), Title: title, Created: time.Now().UTC()}
    s.next++
    s.tasks = append(s.tasks, t)
    return t, s.flushLocked()
}

func (s *Store) Toggle(id string) (Task, bool, error) {
    s.mu.Lock()
    defer s.mu.Unlock()
    for i := range s.tasks {
        if s.tasks[i].ID == id {
            s.tasks[i].Done = !s.tasks[i].Done
            return s.tasks[i], true, s.flushLocked()
        }
    }
    return Task{}, false, nil
}

func (s *Store) Delete(id string) (bool, error) {
    s.mu.Lock()
    defer s.mu.Unlock()
    for i := range s.tasks {
        if s.tasks[i].ID == id {
            s.tasks = append(s.tasks[:i], s.tasks[i+1:]...)
            return true, s.flushLocked()
        }
    }
    return false, nil
}

// Flush writes the store to disk. Called on shutdown as well as on every
// mutation, since core follows CoreMsg.Shutdown with SIGTERM.
func (s *Store) Flush() error {
    s.mu.Lock()
    defer s.mu.Unlock()
    return s.flushLocked()
}

func (s *Store) flushLocked() error {
    b, err := json.MarshalIndent(s.tasks, "", "  ")
    if err != nil {
        return err
    }
    // Write-then-rename so a crash mid-write cannot truncate the store.
    tmp := s.path + ".tmp"
    if err := os.WriteFile(tmp, b, 0o600); err != nil {
        return err
    }
    return os.Rename(tmp, s.path)
}
