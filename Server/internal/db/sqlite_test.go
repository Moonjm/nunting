package db

import (
	"context"
	"testing"
)

func TestOpenAppliesSchema(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer store.Close()

	// users / keyword_subs 테이블이 존재해야 함.
	for _, table := range []string{"users", "keyword_subs"} {
		var name string
		err := store.db.QueryRowContext(context.Background(),
			"SELECT name FROM sqlite_master WHERE type='table' AND name=?", table).Scan(&name)
		if err != nil {
			t.Errorf("table %q not found: %v", table, err)
		}
	}
}

func TestUpsertUserIdempotent(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	if err := store.UpsertUser(ctx, "nnt_a"); err != nil {
		t.Fatalf("first upsert: %v", err)
	}
	var firstCreated int64
	store.db.QueryRowContext(ctx, "SELECT created_at FROM users WHERE uuid='nnt_a'").Scan(&firstCreated)

	if err := store.UpsertUser(ctx, "nnt_a"); err != nil {
		t.Fatalf("second upsert: %v", err)
	}
	var secondCreated int64
	store.db.QueryRowContext(ctx, "SELECT created_at FROM users WHERE uuid='nnt_a'").Scan(&secondCreated)

	if firstCreated != secondCreated {
		t.Errorf("upsert mutated created_at: %d → %d", firstCreated, secondCreated)
	}
}

func TestSetPushTokenRoundTrip(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	if err := store.UpsertUser(ctx, "nnt_a"); err != nil {
		t.Fatalf("setup upsert: %v", err)
	}
	if err := store.SetPushToken(ctx, "nnt_a", "abc123"); err != nil {
		t.Fatalf("set: %v", err)
	}
	got, err := store.GetPushToken(ctx, "nnt_a")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got == nil || *got != "abc123" {
		t.Errorf("want abc123, got %v", got)
	}

	if err := store.SetPushToken(ctx, "nnt_a", ""); err != nil {
		t.Fatalf("clear: %v", err)
	}
	got, _ = store.GetPushToken(ctx, "nnt_a")
	if got != nil {
		t.Errorf("want nil after clear, got %v", *got)
	}
}
