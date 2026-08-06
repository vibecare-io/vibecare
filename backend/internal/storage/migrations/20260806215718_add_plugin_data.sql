-- +goose Up
-- +goose StatementBegin
CREATE TABLE plugin_data (
  plugin_id  TEXT NOT NULL,
  collection TEXT NOT NULL,
  key        TEXT NOT NULL,
  value_json TEXT NOT NULL,
  updated_at TIMESTAMP NOT NULL,
  PRIMARY KEY (plugin_id, collection, key)
);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE plugin_data;
-- +goose StatementEnd
