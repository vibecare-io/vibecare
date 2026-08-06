package storage

import (
	"os"
	"testing"
)

// TestStoreAndQueryPluginData verifies a store->query round-trip returns the record.
func TestStoreAndQueryPluginData(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	err := db.StorePluginData("p", "todos", "k1", `{"text":"a"}`)
	if err != nil {
		t.Fatalf("StorePluginData failed: %v", err)
	}

	records, err := db.QueryPluginData("p", "todos")
	if err != nil {
		t.Fatalf("QueryPluginData failed: %v", err)
	}

	if len(records) != 1 {
		t.Fatalf("Expected 1 record, got %d", len(records))
	}

	if records[0].Key != "k1" {
		t.Errorf("Expected key 'k1', got %q", records[0].Key)
	}
	if records[0].ValueJSON != `{"text":"a"}` {
		t.Errorf("Expected value_json %q, got %q", `{"text":"a"}`, records[0].ValueJSON)
	}
}

// TestQueryPluginDataNamespacing verifies that data is namespaced by plugin_id and collection —
// a different pluginID and a different collection must not see another plugin's data.
func TestQueryPluginDataNamespacing(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	err := db.StorePluginData("p", "todos", "k1", `{"text":"a"}`)
	if err != nil {
		t.Fatalf("StorePluginData failed: %v", err)
	}

	// Different plugin ID, same collection -> must not see the other plugin's data.
	otherPluginRecords, err := db.QueryPluginData("other", "todos")
	if err != nil {
		t.Fatalf("QueryPluginData failed: %v", err)
	}
	if len(otherPluginRecords) != 0 {
		t.Errorf("Expected 0 records for different pluginID, got %d", len(otherPluginRecords))
	}

	// Same plugin ID, different collection -> must not see data from another collection.
	otherCollectionRecords, err := db.QueryPluginData("p", "other-collection")
	if err != nil {
		t.Fatalf("QueryPluginData failed: %v", err)
	}
	if len(otherCollectionRecords) != 0 {
		t.Errorf("Expected 0 records for different collection, got %d", len(otherCollectionRecords))
	}
}

// TestStorePluginDataUpsert verifies that storing the same (plugin,collection,key) twice
// updates the existing row rather than creating a duplicate.
func TestStorePluginDataUpsert(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	if err := db.StorePluginData("p", "todos", "k1", `{"text":"a"}`); err != nil {
		t.Fatalf("StorePluginData (first) failed: %v", err)
	}
	if err := db.StorePluginData("p", "todos", "k1", `{"text":"b"}`); err != nil {
		t.Fatalf("StorePluginData (second) failed: %v", err)
	}

	records, err := db.QueryPluginData("p", "todos")
	if err != nil {
		t.Fatalf("QueryPluginData failed: %v", err)
	}

	if len(records) != 1 {
		t.Fatalf("Expected 1 record after upsert, got %d", len(records))
	}
	if records[0].ValueJSON != `{"text":"b"}` {
		t.Errorf("Expected updated value_json %q, got %q", `{"text":"b"}`, records[0].ValueJSON)
	}
}

// TestDeletePluginData verifies a stored record is gone after DeletePluginData,
// and that deleting only removes the (plugin_id, collection, key) row it targets.
func TestDeletePluginData(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	if err := db.StorePluginData("p", "todos", "k1", `{"text":"a"}`); err != nil {
		t.Fatalf("StorePluginData failed: %v", err)
	}
	if err := db.StorePluginData("p", "todos", "k2", `{"text":"b"}`); err != nil {
		t.Fatalf("StorePluginData failed: %v", err)
	}

	if err := db.DeletePluginData("p", "todos", "k1"); err != nil {
		t.Fatalf("DeletePluginData failed: %v", err)
	}

	records, err := db.QueryPluginData("p", "todos")
	if err != nil {
		t.Fatalf("QueryPluginData failed: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("Expected 1 record after delete, got %d", len(records))
	}
	if records[0].Key != "k2" {
		t.Errorf("Expected remaining key 'k2', got %q", records[0].Key)
	}
}

// TestDeletePluginDataNonexistentIsNoop verifies deleting a key that was never
// stored (or already deleted) succeeds without error rather than failing.
func TestDeletePluginDataNonexistentIsNoop(t *testing.T) {
	db, dbPath := setupTestDB(t)
	defer os.Remove(dbPath)
	defer db.Close()

	if err := db.DeletePluginData("p", "todos", "does-not-exist"); err != nil {
		t.Fatalf("DeletePluginData on nonexistent key should be a no-op, got error: %v", err)
	}
}
