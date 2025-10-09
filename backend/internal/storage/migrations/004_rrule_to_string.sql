-- +goose Up
-- +goose StatementBegin
-- Rename recurrence_json column to rrule
-- This migration converts from JSON format to RFC 5545 RRule string format
ALTER TABLE schedules RENAME COLUMN recurrence_json TO rrule;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
-- Revert column name back to recurrence_json
ALTER TABLE schedules RENAME COLUMN rrule TO recurrence_json;
-- +goose StatementEnd
