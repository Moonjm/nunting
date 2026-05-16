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

func TestKeywordCRUD(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	if err := store.UpsertUser(ctx, "nnt_a"); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	keys, _ := store.ListKeywords(ctx, "nnt_a")
	if len(keys) != 0 {
		t.Errorf("want empty, got %v", keys)
	}

	store.AddKeyword(ctx, "nnt_a", "삼성")
	store.AddKeyword(ctx, "nnt_a", "갤럭시")
	keys, _ = store.ListKeywords(ctx, "nnt_a")
	want := []string{"갤럭시", "삼성"}
	if len(keys) != 2 || keys[0] != want[0] || keys[1] != want[1] {
		t.Errorf("want %v sorted, got %v", want, keys)
	}

	if err := store.AddKeyword(ctx, "nnt_a", "삼성"); err != nil {
		t.Errorf("duplicate add should be no-op, got error: %v", err)
	}

	store.RemoveKeyword(ctx, "nnt_a", "삼성")
	keys, _ = store.ListKeywords(ctx, "nnt_a")
	if len(keys) != 1 || keys[0] != "갤럭시" {
		t.Errorf("want [갤럭시], got %v", keys)
	}
}

func TestMatchedUsersForTitle(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	store.UpsertUser(ctx, "nnt_a")
	store.SetPushToken(ctx, "nnt_a", "tok_a")
	store.AddKeyword(ctx, "nnt_a", "갤럭시")

	store.UpsertUser(ctx, "nnt_b")
	store.SetPushToken(ctx, "nnt_b", "tok_b")
	store.AddKeyword(ctx, "nnt_b", "ultra") // case-insensitive: 소문자 키워드가 대문자 ULTRA in title 매칭

	store.UpsertUser(ctx, "nnt_c")
	store.AddKeyword(ctx, "nnt_c", "갤럭시") // push_token 없음

	matches, err := store.MatchedUsersForTitle(ctx, "삼성 갤럭시 S25 ULTRA")
	if err != nil {
		t.Fatalf("query: %v", err)
	}

	if len(matches) != 2 {
		t.Fatalf("want 2 matches, got %d: %+v", len(matches), matches)
	}
	want := map[string]string{"nnt_a": "tok_a", "nnt_b": "tok_b"}
	for _, m := range matches {
		if want[m.UUID] != m.PushToken || want[m.UUID] == "" {
			t.Errorf("unexpected match: uuid=%s token=%s keyword=%s", m.UUID, m.PushToken, m.Keyword)
		}
	}
}
