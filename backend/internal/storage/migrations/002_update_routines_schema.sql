-- +goose Up
-- +goose StatementBegin
-- Update routines table to match protobuf structure
ALTER TABLE routines ADD COLUMN action_ids TEXT DEFAULT '[]';
ALTER TABLE routines ADD COLUMN metadata TEXT DEFAULT '{}';
ALTER TABLE routines ADD COLUMN last_executed_at TEXT;

-- Migrate existing data (for now, we'll handle this by keeping actions_json as backup)
-- In a real migration, you'd convert actions_json to action_ids

-- Update execution_logs table to match protobuf structure
ALTER TABLE execution_logs ADD COLUMN action_results TEXT DEFAULT '{}';
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
ALTER TABLE routines DROP COLUMN action_ids;
ALTER TABLE routines DROP COLUMN metadata;
ALTER TABLE routines DROP COLUMN last_executed_at;
ALTER TABLE execution_logs DROP COLUMN action_results;
-- +goose StatementEnd