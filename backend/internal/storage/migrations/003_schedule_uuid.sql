-- +goose Up
-- +goose StatementBegin

-- Update schedules table to use TEXT for schedule_id instead of INTEGER
-- SQLite doesn't support ALTER COLUMN, so we create new table and copy data

-- Backup existing schedules if any
CREATE TABLE IF NOT EXISTS schedules_backup AS SELECT * FROM schedules;

-- Drop existing table
DROP TABLE schedules;

-- Recreate with TEXT primary key
CREATE TABLE schedules (
    schedule_id TEXT PRIMARY KEY,
    routine_id TEXT NOT NULL,
    name TEXT,
    recurrence_json TEXT NOT NULL,
    dtstart TEXT,
    exdates TEXT,
    last_execution TEXT,
    notes TEXT,
    enabled INTEGER DEFAULT 1,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (routine_id) REFERENCES routines(id) ON DELETE CASCADE
);

-- Recreate index
CREATE INDEX idx_schedules_routine ON schedules(routine_id);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Revert back to INTEGER auto-increment
DROP TABLE schedules;

CREATE TABLE schedules (
    schedule_id INTEGER PRIMARY KEY AUTOINCREMENT,
    routine_id TEXT NOT NULL,
    name TEXT,
    recurrence_json TEXT NOT NULL,
    dtstart TEXT,
    exdates TEXT,
    last_execution TEXT,
    notes TEXT,
    enabled INTEGER DEFAULT 1,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (routine_id) REFERENCES routines(id) ON DELETE CASCADE
);

CREATE INDEX idx_schedules_routine ON schedules(routine_id);

-- +goose StatementEnd