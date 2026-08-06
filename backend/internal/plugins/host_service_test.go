package plugins

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/vibecare-io/vibecare/backend/internal/scheduler"
	"github.com/vibecare-io/vibecare/backend/internal/storage"
	pb "github.com/vibecare-io/vibecare/backend/pkg/proto"
	"go.uber.org/zap"
)

// newTestDB creates a temporary, migrated storage.DB for use in a test.
func newTestDB(t *testing.T) *storage.DB {
	t.Helper()
	db, err := storage.New(filepath.Join(t.TempDir(), "x.db"))
	if err != nil {
		t.Fatalf("storage.New failed: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

// TestStoreAndQueryDataRoundTrip verifies StoreData followed by QueryData, both
// attributed to plugin "p" via context, returns the stored record.
func TestStoreAndQueryDataRoundTrip(t *testing.T) {
	db := newTestDB(t)
	hub := scheduler.NewEventHub(zap.NewNop())
	svc := NewHostService(db, hub, zap.NewNop())

	ctx := svc.WithPluginID(context.Background(), "p")

	_, err := svc.StoreData(ctx, &pb.StoreRequest{
		Collection: "todos",
		Key:        "k1",
		ValueJson:  `{"text":"a"}`,
	})
	if err != nil {
		t.Fatalf("StoreData failed: %v", err)
	}

	resp, err := svc.QueryData(ctx, &pb.QueryRequest{Collection: "todos"})
	if err != nil {
		t.Fatalf("QueryData failed: %v", err)
	}
	if len(resp.Records) != 1 {
		t.Fatalf("expected 1 record, got %d", len(resp.Records))
	}
	if resp.Records[0].Key != "k1" || resp.Records[0].ValueJson != `{"text":"a"}` {
		t.Errorf("unexpected record: %+v", resp.Records[0])
	}
}

// TestQueryDataNamespacedByContextPluginID verifies that a different plugin id
// on the context cannot see another plugin's stored data.
func TestQueryDataNamespacedByContextPluginID(t *testing.T) {
	db := newTestDB(t)
	hub := scheduler.NewEventHub(zap.NewNop())
	svc := NewHostService(db, hub, zap.NewNop())

	ctxP := svc.WithPluginID(context.Background(), "p")
	if _, err := svc.StoreData(ctxP, &pb.StoreRequest{
		Collection: "todos",
		Key:        "k1",
		ValueJson:  `{"text":"a"}`,
	}); err != nil {
		t.Fatalf("StoreData failed: %v", err)
	}

	ctxOther := svc.WithPluginID(context.Background(), "other")
	resp, err := svc.QueryData(ctxOther, &pb.QueryRequest{Collection: "todos"})
	if err != nil {
		t.Fatalf("QueryData failed: %v", err)
	}
	if len(resp.Records) != 0 {
		t.Errorf("expected 0 records for different plugin id, got %d", len(resp.Records))
	}
}

// TestEmitEventNotifyLogNoError verifies the remaining HostServiceServer methods
// succeed without error for a well-formed request.
func TestEmitEventNotifyLogNoError(t *testing.T) {
	db := newTestDB(t)
	hub := scheduler.NewEventHub(zap.NewNop())
	svc := NewHostService(db, hub, zap.NewNop())

	ctx := svc.WithPluginID(context.Background(), "p")

	if _, err := svc.EmitEvent(ctx, &pb.PluginEvent{
		Type:    "todo.created",
		Payload: map[string]string{"id": "1"},
	}); err != nil {
		t.Errorf("EmitEvent failed: %v", err)
	}

	if _, err := svc.Notify(ctx, &pb.NotifyRequest{
		Title:   "Hello",
		Message: "World",
	}); err != nil {
		t.Errorf("Notify failed: %v", err)
	}

	if _, err := svc.Log(ctx, &pb.LogRequest{
		Level:   "info",
		Message: "plugin log line",
	}); err != nil {
		t.Errorf("Log failed: %v", err)
	}
}
