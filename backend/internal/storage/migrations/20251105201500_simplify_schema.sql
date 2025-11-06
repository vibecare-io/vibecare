-- +goose Up
-- Simplify database schema: remove JSON fields, add join table, add profile_id to schedules

-- Step 1: Create schedule_actions join table
CREATE TABLE schedule_actions (
    schedule_id TEXT NOT NULL,
    action_id TEXT NOT NULL,
    action_order INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (schedule_id, action_id),
    FOREIGN KEY (schedule_id) REFERENCES schedules(schedule_id) ON DELETE CASCADE,
    FOREIGN KEY (action_id) REFERENCES actions(action_id) ON DELETE CASCADE
);

CREATE INDEX idx_schedule_actions_schedule ON schedule_actions(schedule_id);
CREATE INDEX idx_schedule_actions_action ON schedule_actions(action_id);
CREATE INDEX idx_schedule_actions_order ON schedule_actions(schedule_id, action_order);

-- Step 2: Add profile_id column to schedules (nullable first for data migration)
ALTER TABLE schedules ADD COLUMN profile_id TEXT;

-- Step 3: Populate profile_id in schedules from their parent routines
UPDATE schedules
SET profile_id = (
    SELECT profile_id FROM routines WHERE routines.id = schedules.routine_id
);

-- Step 4: Make profile_id NOT NULL after populating data
-- Note: SQLite doesn't support ALTER COLUMN, so we need to recreate the table
CREATE TABLE schedules_new (
    schedule_id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    routine_id TEXT NOT NULL,
    name TEXT,
    rrule TEXT NOT NULL,
    dtstart TEXT,
    exdates TEXT,
    last_execution TEXT,
    notes TEXT,
    enabled INTEGER DEFAULT 1,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE,
    FOREIGN KEY (routine_id) REFERENCES routines(id) ON DELETE CASCADE
);

-- Copy data to new table (excluding action_ids)
INSERT INTO schedules_new (schedule_id, profile_id, routine_id, name, rrule, dtstart, exdates, last_execution, notes, enabled, created_at, updated_at)
SELECT schedule_id, profile_id, routine_id, name, rrule, dtstart, exdates, last_execution, notes, enabled, created_at, updated_at
FROM schedules;

-- Drop old table and rename new one
DROP TABLE schedules;
ALTER TABLE schedules_new RENAME TO schedules;

-- Recreate indexes
CREATE INDEX idx_schedules_routine ON schedules(routine_id);
CREATE INDEX idx_schedules_profile ON schedules(profile_id);

-- Step 5: Recreate routines table without JSON action fields
CREATE TABLE routines_new (
    id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    enabled INTEGER DEFAULT 1,
    metadata TEXT DEFAULT '{}',
    last_executed_at TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE
);

-- Copy data to new table (excluding actions_json and action_ids)
INSERT INTO routines_new (id, profile_id, name, description, enabled, metadata, last_executed_at, created_at, updated_at)
SELECT id, profile_id, name, description, enabled, metadata, last_executed_at, created_at, updated_at
FROM routines;

-- Drop old table and rename new one
DROP TABLE routines;
ALTER TABLE routines_new RENAME TO routines;

-- Recreate index
CREATE INDEX idx_routines_profile ON routines(profile_id);

-- Step 6: Drop execution_logs table
DROP TABLE IF EXISTS execution_logs;

-- +goose Down
-- Rollback: Restore original schema (for emergencies only)

-- Restore execution_logs table
CREATE TABLE execution_logs (
    log_id INTEGER PRIMARY KEY AUTOINCREMENT,
    routine_id TEXT NOT NULL,
    timestamp TEXT DEFAULT CURRENT_TIMESTAMP,
    completed INTEGER DEFAULT 1,
    notes TEXT,
    action_results TEXT DEFAULT '{}',
    FOREIGN KEY (routine_id) REFERENCES routines(id) ON DELETE CASCADE
);

CREATE INDEX idx_execution_logs_routine ON execution_logs(routine_id);
CREATE INDEX idx_execution_logs_timestamp ON execution_logs(timestamp);

-- Restore routines table with JSON fields
CREATE TABLE routines_old (
    id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    actions_json TEXT DEFAULT '[]',
    enabled INTEGER DEFAULT 1,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    action_ids TEXT DEFAULT '[]',
    metadata TEXT DEFAULT '{}',
    last_executed_at TEXT,
    FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE
);

INSERT INTO routines_old (id, profile_id, name, description, enabled, metadata, last_executed_at, created_at, updated_at)
SELECT id, profile_id, name, description, enabled, metadata, last_executed_at, created_at, updated_at
FROM routines;

DROP TABLE routines;
ALTER TABLE routines_old RENAME TO routines;
CREATE INDEX idx_routines_profile ON routines(profile_id);

-- Restore schedules table with action_ids
CREATE TABLE schedules_old (
    schedule_id TEXT PRIMARY KEY,
    routine_id TEXT NOT NULL,
    name TEXT,
    rrule TEXT NOT NULL,
    dtstart TEXT,
    exdates TEXT,
    last_execution TEXT,
    notes TEXT,
    enabled INTEGER DEFAULT 1,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
    action_ids TEXT DEFAULT '[]',
    FOREIGN KEY (routine_id) REFERENCES routines(id) ON DELETE CASCADE
);

INSERT INTO schedules_old (schedule_id, routine_id, name, rrule, dtstart, exdates, last_execution, notes, enabled, created_at, updated_at)
SELECT schedule_id, routine_id, name, rrule, dtstart, exdates, last_execution, notes, enabled, created_at, updated_at
FROM schedules;

DROP TABLE schedules;
ALTER TABLE schedules_old RENAME TO schedules;
CREATE INDEX idx_schedules_routine ON schedules(routine_id);

-- Drop schedule_actions join table
DROP TABLE IF EXISTS schedule_actions;
