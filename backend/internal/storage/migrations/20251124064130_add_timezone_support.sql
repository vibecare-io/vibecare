-- +goose Up
-- +goose StatementBegin

-- Add timezone column to profiles table
-- Stores user's current location timezone (for display and "follow me" schedules)
-- Uses IANA timezone identifiers (e.g., "America/Los_Angeles", "Asia/Tokyo")
ALTER TABLE profiles ADD COLUMN timezone TEXT NOT NULL DEFAULT 'UTC';

-- Add schedule_timezone column to schedules table
-- Stores the timezone context for RRule calculations (for "sticky" schedules)
-- Enables proper DST handling and timezone-anchored schedules
ALTER TABLE schedules ADD COLUMN schedule_timezone TEXT NOT NULL DEFAULT 'UTC';

-- Populate existing profiles with UTC timezone as default
-- Users can update this later via profile settings
UPDATE profiles SET timezone = 'UTC' WHERE timezone IS NULL OR timezone = '';

-- Populate existing schedules with UTC timezone
-- This preserves current behavior (all calculations in UTC)
UPDATE schedules SET schedule_timezone = 'UTC' WHERE schedule_timezone IS NULL OR schedule_timezone = '';

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin

-- Remove timezone columns in reverse order
ALTER TABLE schedules DROP COLUMN schedule_timezone;
ALTER TABLE profiles DROP COLUMN timezone;

-- +goose StatementEnd
