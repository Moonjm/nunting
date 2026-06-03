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

func TestMatchedUsersForTitle_ANDTokens(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	// nnt_a 는 AND 키워드 "500ml,삼다수" (정규화된 CSV 형태로 직접 저장)
	store.UpsertUser(ctx, "nnt_a")
	store.SetPushToken(ctx, "nnt_a", "tok_a")
	store.AddKeyword(ctx, "nnt_a", "500ml,삼다수")

	// nnt_b 는 단일 키워드 "콜라" — AND user 와 동시 동작 확인용
	store.UpsertUser(ctx, "nnt_b")
	store.SetPushToken(ctx, "nnt_b", "tok_b")
	store.AddKeyword(ctx, "nnt_b", "콜라")

	// 1) 두 토큰 모두 포함 + case-insensitive (title 에 대문자 500ML) → nnt_a 매칭
	matches, err := store.MatchedUsersForTitle(ctx, "삼다수 500ML 24개입")
	if err != nil {
		t.Fatalf("query hit: %v", err)
	}
	if len(matches) != 1 || matches[0].UUID != "nnt_a" || matches[0].Keyword != "500ml,삼다수" {
		t.Errorf("AND hit: want [nnt_a/500ml,삼다수], got %+v", matches)
	}

	// 2) 한 토큰만 포함 → no match
	matches, _ = store.MatchedUsersForTitle(ctx, "삼다수 2L 6개입")
	if len(matches) != 0 {
		t.Errorf("AND miss (only 1 token): want empty, got %+v", matches)
	}

	// 3) 다른 user 의 단일 키워드 매칭은 여전히 동작
	matches, _ = store.MatchedUsersForTitle(ctx, "코카콜라 1+1 행사")
	if len(matches) != 1 || matches[0].UUID != "nnt_b" {
		t.Errorf("single-token regression: want [nnt_b], got %+v", matches)
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

func TestRecordAndListAlertHistory(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer store.Close()
	ctx := context.Background()
	if err := store.UpsertUser(ctx, "nnt_a"); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	for i := 0; i < 3; i++ {
		if _, err := store.RecordAlert(ctx, "nnt_a", "갤럭시", "100"+string(rune('0'+i)), "title "+string(rune('0'+i)), "https://x/"+string(rune('0'+i))); err != nil {
			t.Fatalf("record %d: %v", i, err)
		}
	}

	items, err := store.ListAlertHistory(ctx, "nnt_a", 10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(items) != 3 {
		t.Fatalf("want 3 items, got %d", len(items))
	}
	// 최신순(가장 최근 insert 가 맨 앞).
	if items[0].Title != "title 2" {
		t.Errorf("want newest first, got %q", items[0].Title)
	}
	if items[0].Keyword != "갤럭시" || items[0].URL != "https://x/2" || items[0].PostNo != "1002" {
		t.Errorf("unexpected row: %+v", items[0])
	}
	if items[0].SentAt == 0 {
		t.Errorf("sent_at not set")
	}
	// 새 알림은 안 읽음(read_at NULL) 이어야 하고 id 가 채워져야 함.
	if items[0].Read {
		t.Errorf("new alert should be unread")
	}
	if items[0].ID == 0 {
		t.Errorf("id not set")
	}
}

func TestRecordAlertNoCap(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer store.Close()
	ctx := context.Background()
	if err := store.UpsertUser(ctx, "nnt_a"); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	// 보관 제한 제거 — 250건 넣으면 250건 모두 남아야 함.
	const total = 250
	for i := 0; i < total; i++ {
		if _, err := store.RecordAlert(ctx, "nnt_a", "k", "n", "t", "u"); err != nil {
			t.Fatalf("record %d: %v", i, err)
		}
	}

	var n int
	store.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM alert_history WHERE uuid='nnt_a'").Scan(&n)
	if n != total {
		t.Errorf("want all %d rows kept, got %d", total, n)
	}
}

func TestMarkAlertRead(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer store.Close()
	ctx := context.Background()
	if err := store.UpsertUser(ctx, "nnt_a"); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if _, err := store.RecordAlert(ctx, "nnt_a", "갤럭시", "1001", "t", "u"); err != nil {
		t.Fatalf("record: %v", err)
	}

	items, _ := store.ListAlertHistory(ctx, "nnt_a", 10)
	if len(items) != 1 || items[0].Read {
		t.Fatalf("setup: want 1 unread, got %+v", items)
	}
	id := items[0].ID

	// 다른 유저는 못 건드림 — uuid 불일치면 no-op.
	if err := store.MarkAlertRead(ctx, "nnt_other", id); err != nil {
		t.Fatalf("mark(other): %v", err)
	}
	items, _ = store.ListAlertHistory(ctx, "nnt_a", 10)
	if items[0].Read {
		t.Errorf("other user must not mark read")
	}

	// 본인은 읽음 처리됨.
	if err := store.MarkAlertRead(ctx, "nnt_a", id); err != nil {
		t.Fatalf("mark: %v", err)
	}
	items, _ = store.ListAlertHistory(ctx, "nnt_a", 10)
	if !items[0].Read {
		t.Errorf("want read after mark")
	}
}

func TestAlertHistoryCascadesOnUserDelete(t *testing.T) {
	store, err := Open(":memory:")
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer store.Close()
	ctx := context.Background()
	if err := store.UpsertUser(ctx, "nnt_a"); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if _, err := store.RecordAlert(ctx, "nnt_a", "k", "n", "t", "u"); err != nil {
		t.Fatalf("record: %v", err)
	}
	if _, err := store.db.ExecContext(ctx, "DELETE FROM users WHERE uuid='nnt_a'"); err != nil {
		t.Fatalf("delete user: %v", err)
	}
	var n int
	store.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM alert_history").Scan(&n)
	if n != 0 {
		t.Errorf("want cascade delete, %d rows remain", n)
	}
}
