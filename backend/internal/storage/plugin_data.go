package storage

import "time"

// PluginRecord is a single key/value entry stored by a plugin in one of its collections.
type PluginRecord struct {
	Key       string
	ValueJSON string
}

// StorePluginData upserts a value for the given plugin, collection, and key.
// Data is namespaced by plugin_id + collection: plugins can never see or overwrite
// each other's data, even if they use the same collection/key names.
func (db *DB) StorePluginData(pluginID, collection, key, valueJSON string) error {
	query := `
		INSERT INTO plugin_data (plugin_id, collection, key, value_json, updated_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(plugin_id, collection, key) DO UPDATE SET
			value_json = excluded.value_json,
			updated_at = excluded.updated_at
	`
	_, err := db.Exec(query, pluginID, collection, key, valueJSON, time.Now().UTC().Format(time.RFC3339))
	return err
}

// QueryPluginData returns all records for the given plugin_id and collection.
// It returns ONLY rows matching both pluginID and collection — no cross-plugin
// or cross-collection leakage.
func (db *DB) QueryPluginData(pluginID, collection string) ([]PluginRecord, error) {
	query := `
		SELECT key, value_json
		FROM plugin_data
		WHERE plugin_id = ? AND collection = ?
	`
	rows, err := db.Query(query, pluginID, collection)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	records := []PluginRecord{}
	for rows.Next() {
		var rec PluginRecord
		if err := rows.Scan(&rec.Key, &rec.ValueJSON); err != nil {
			return nil, err
		}
		records = append(records, rec)
	}

	if err := rows.Err(); err != nil {
		return nil, err
	}

	return records, nil
}

// DeletePluginData removes the record for the given plugin_id, collection,
// and key. Deleting a key that doesn't exist (already deleted or never
// stored) is a no-op, not an error.
func (db *DB) DeletePluginData(pluginID, collection, key string) error {
	query := `DELETE FROM plugin_data WHERE plugin_id = ? AND collection = ? AND key = ?`
	_, err := db.Exec(query, pluginID, collection, key)
	return err
}
