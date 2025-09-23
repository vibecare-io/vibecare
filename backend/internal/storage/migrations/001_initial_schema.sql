-- +goose Up
-- +goose StatementBegin
CREATE TABLE profiles (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT UNIQUE,
    preferences_json TEXT DEFAULT '{}',
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE routines (
    id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    actions_json TEXT DEFAULT '[]', -- JSON array of actions
    enabled INTEGER DEFAULT 1,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE
);

CREATE TABLE schedules (
    schedule_id INTEGER PRIMARY KEY AUTOINCREMENT,
    routine_id TEXT NOT NULL,
    name TEXT,
    recurrence_json TEXT NOT NULL, -- RRule JSON
    dtstart TEXT,
    exdates TEXT, -- comma-separated exclusion dates
    last_execution TEXT,
    notes TEXT,
    enabled INTEGER DEFAULT 1,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (routine_id) REFERENCES routines(id) ON DELETE CASCADE
);

CREATE TABLE execution_logs (
    log_id INTEGER PRIMARY KEY AUTOINCREMENT,
    routine_id TEXT NOT NULL,
    timestamp TEXT DEFAULT CURRENT_TIMESTAMP,
    completed INTEGER DEFAULT 1,
    notes TEXT,
    FOREIGN KEY (routine_id) REFERENCES routines(id) ON DELETE CASCADE
);

-- Indexes for performance
CREATE INDEX idx_routines_profile ON routines(profile_id);
CREATE INDEX idx_schedules_routine ON schedules(routine_id);
CREATE INDEX idx_execution_logs_routine ON execution_logs(routine_id);
CREATE INDEX idx_execution_logs_timestamp ON execution_logs(timestamp);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS execution_logs;
DROP TABLE IF EXISTS schedules;
DROP TABLE IF EXISTS routines;
DROP TABLE IF EXISTS profiles;
-- +goose StatementEnd