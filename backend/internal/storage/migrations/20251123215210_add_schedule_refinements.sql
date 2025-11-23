-- +goose Up
-- +goose StatementBegin

-- Step 1: Add new columns (nullable initially)
ALTER TABLE schedules ADD COLUMN schedule_type TEXT;
ALTER TABLE schedules ADD COLUMN next_execution TEXT;

-- Step 2: Populate schedule_type from existing rrule
-- Empty rrule means ONE_SHOT, non-empty means RECURRING
UPDATE schedules
SET schedule_type = CASE
    WHEN rrule = '' THEN 'ONE_SHOT'
    ELSE 'RECURRING'
END;

-- Step 3: Populate next_execution based on schedule_type
-- For ONE_SHOT schedules:
--   - If never executed and dtstart in future: next_execution = dtstart
--   - If already executed or past: next_execution = NULL
UPDATE schedules
SET next_execution = CASE
    WHEN schedule_type = 'ONE_SHOT'
         AND last_execution IS NULL
         AND dtstart IS NOT NULL
         AND datetime(dtstart) > datetime('now')
    THEN dtstart
    ELSE NULL
END
WHERE schedule_type = 'ONE_SHOT';

-- For RECURRING schedules, we'll calculate next_execution after table recreation
-- (requires RRule parsing which is done in Go code via goose hooks)

-- Step 4: Create new table with constraints
CREATE TABLE schedules_new (
    schedule_id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    routine_id TEXT NOT NULL,
    schedule_type TEXT NOT NULL CHECK(schedule_type IN ('ONE_SHOT', 'RECURRING')),
    name TEXT,
    rrule TEXT NOT NULL,
    dtstart TEXT,
    exdates TEXT,
    last_execution TEXT,
    next_execution TEXT,
    notes TEXT,
    enabled INTEGER DEFAULT 1 NOT NULL,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP NOT NULL,
    FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE,
    FOREIGN KEY (routine_id) REFERENCES routines(id) ON DELETE CASCADE
);

-- Step 5: Copy data from old table to new table
INSERT INTO schedules_new
SELECT
    schedule_id,
    profile_id,
    routine_id,
    schedule_type,
    name,
    rrule,
    dtstart,
    exdates,
    last_execution,
    next_execution,
    notes,
    enabled,
    created_at,
    updated_at
FROM schedules;

-- Step 6: Drop old table
DROP TABLE schedules;

-- Step 7: Rename new table to schedules
ALTER TABLE schedules_new RENAME TO schedules;

-- Step 8: Recreate existing indexes
CREATE INDEX idx_schedules_routine ON schedules(routine_id);
CREATE INDEX idx_schedules_profile ON schedules(profile_id);

-- Step 9: Add new indexes for performance
CREATE INDEX idx_schedules_type ON schedules(schedule_type);

-- Partial index: only index enabled schedules with next_execution set
CREATE INDEX idx_schedules_next_execution ON schedules(next_execution)
    WHERE enabled = 1 AND next_execution IS NOT NULL;

-- Index on enabled for quick filtering
CREATE INDEX idx_schedules_enabled ON schedules(enabled) WHERE enabled = 1;

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Recreate old table structure without new columns
CREATE TABLE schedules_old (
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

-- Copy data back (excluding new columns)
INSERT INTO schedules_old
SELECT
    schedule_id,
    profile_id,
    routine_id,
    name,
    rrule,
    dtstart,
    exdates,
    last_execution,
    notes,
    enabled,
    created_at,
    updated_at
FROM schedules;

-- Drop new table
DROP TABLE schedules;

-- Rename old table back
ALTER TABLE schedules_old RENAME TO schedules;

-- Recreate original indexes
CREATE INDEX idx_schedules_routine ON schedules(routine_id);
CREATE INDEX idx_schedules_profile ON schedules(profile_id);

-- +goose StatementEnd
