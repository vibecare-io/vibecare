-- +goose Up
-- +goose StatementBegin

-- Create actions table for reusable action definitions
CREATE TABLE actions (
    action_id TEXT PRIMARY KEY,
    profile_id TEXT NOT NULL,
    type TEXT NOT NULL,  -- notification, open_link, send_email, run_script, play_sound, system_command, api_call, log_entry
    name TEXT NOT NULL,
    description TEXT,
    parameters_json TEXT DEFAULT '{}',
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (profile_id) REFERENCES profiles(id) ON DELETE CASCADE
);

-- Add indexes for performance
CREATE INDEX idx_actions_profile ON actions(profile_id);
CREATE INDEX idx_actions_type ON actions(type);

-- Add action_ids column to schedules table
ALTER TABLE schedules ADD COLUMN action_ids TEXT DEFAULT '[]';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Remove action_ids column from schedules
ALTER TABLE schedules DROP COLUMN action_ids;

-- Drop indexes
DROP INDEX IF EXISTS idx_actions_type;
DROP INDEX IF EXISTS idx_actions_profile;

-- Drop actions table
DROP TABLE IF EXISTS actions;

-- +goose StatementEnd
