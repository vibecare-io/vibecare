-- +goose Up
-- Rename parameters_json to parameters for consistency
ALTER TABLE actions RENAME COLUMN parameters_json TO parameters;

-- +goose Down
-- Revert: rename parameters back to parameters_json
ALTER TABLE actions RENAME COLUMN parameters TO parameters_json;
