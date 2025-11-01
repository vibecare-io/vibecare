-- +goose Up
-- +goose StatementBegin

-- Add enabled column to actions table (default to true for backward compatibility)
ALTER TABLE actions ADD COLUMN enabled INTEGER DEFAULT 1;

-- Add index for filtering by enabled status
CREATE INDEX idx_actions_enabled ON actions(enabled);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Drop index
DROP INDEX IF EXISTS idx_actions_enabled;

-- Remove enabled column
ALTER TABLE actions DROP COLUMN enabled;

-- +goose StatementEnd
