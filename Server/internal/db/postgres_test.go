package db

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"strconv"
	"sync/atomic"
	"testing"
	"time"
)

func TestOpenAppliesSchema(t *testing.T) {
	store := newStore(t)

	// 모든 테이블이 현재 schema 에 존재해야 함.
	for _, table := range []string{"users", "keyword_subs", "alert_history", "metric_payloads", "footprint_samples"} {
		var name string
		err := store.db.QueryRowContext(context.Background(),
			`SELECT table_name FROM information_schema.tables
			 WHERE table_schema = current_schema() AND table_name = $1`, table).Scan(&name)
		if err != nil {
			t.Errorf("table %q not found: %v", table, err)
		}
	}
}

func TestUpsertUserIdempotent(t *testing.T) {
	store := newStore(t)
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
	store := newStore(t)
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
	store := newStore(t)
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
	if len(keys) != 2 || keys[0].Keyword != want[0] || keys[1].Keyword != want[1] {
		t.Errorf("want %v sorted, got %v", want, keys)
	}

	if err := store.AddKeyword(ctx, "nnt_a", "삼성"); err != nil {
		t.Errorf("duplicate add should be no-op, got error: %v", err)
	}

	store.RemoveKeyword(ctx, "nnt_a", "삼성")
	keys, _ = store.ListKeywords(ctx, "nnt_a")
	if len(keys) != 1 || keys[0].Keyword != "갤럭시" {
		t.Errorf("want [갤럭시], got %v", keys)
	}
}

func TestUpsertKeywordAndExcludeMatching(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()

	store.UpsertUser(ctx, "nnt_a")
	store.SetPushToken(ctx, "nnt_a", "tok_a")
	// 포함 "갤럭시", 제외 "중고,판매".
	if _, err := store.UpsertKeyword(ctx, "nnt_a", "갤럭시", "중고,판매"); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	// ListKeywords 가 exclude 동반 반환.
	keys, _ := store.ListKeywords(ctx, "nnt_a")
	if len(keys) != 1 || keys[0].Keyword != "갤럭시" || keys[0].Exclude != "중고,판매" {
		t.Fatalf("list: want 갤럭시/중고,판매, got %+v", keys)
	}

	// 포함O · 제외X → 매칭.
	m, _ := store.MatchedUsersForTitle(ctx, "갤럭시 S25 개봉기")
	if len(m) != 1 || m[0].UUID != "nnt_a" {
		t.Errorf("include hit, no exclude: want [nnt_a], got %+v", m)
	}

	// 포함O · 제외O(중고) → 탈락.
	m, _ = store.MatchedUsersForTitle(ctx, "갤럭시 중고 팝니다")
	if len(m) != 0 {
		t.Errorf("exclude '중고' present: want empty, got %+v", m)
	}
	// 다른 제외 토큰(판매)도 탈락 — OR 의미.
	m, _ = store.MatchedUsersForTitle(ctx, "갤럭시 판매합니다")
	if len(m) != 0 {
		t.Errorf("exclude '판매' present: want empty, got %+v", m)
	}

	// upsert 재호출로 제외 갱신(행 중복 없이 exclude 만 교체).
	if _, err := store.UpsertKeyword(ctx, "nnt_a", "갤럭시", ""); err != nil {
		t.Fatalf("re-upsert: %v", err)
	}
	keys, _ = store.ListKeywords(ctx, "nnt_a")
	if len(keys) != 1 || keys[0].Exclude != "" {
		t.Fatalf("exclude cleared: want 1 row exclude='', got %+v", keys)
	}
	// 제외가 비었으니 이제 "갤럭시 중고" 도 매칭.
	m, _ = store.MatchedUsersForTitle(ctx, "갤럭시 중고 팝니다")
	if len(m) != 1 {
		t.Errorf("after clearing exclude: want match, got %+v", m)
	}
}

func TestMatchedUsersExcludeFallsThroughToNextRow(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()

	store.UpsertUser(ctx, "nnt_a")
	store.SetPushToken(ctx, "nnt_a", "tok_a")
	// 같은 user 의 두 행: "갤럭시"(제외 중고) + "삼성"(제외 없음).
	store.UpsertKeyword(ctx, "nnt_a", "갤럭시", "중고")
	store.UpsertKeyword(ctx, "nnt_a", "삼성", "")

	// "삼성 갤럭시 중고": 갤럭시 행은 제외(중고)로 탈락하지만, 삼성 행이
	// 매칭되어 알림은 1건 발생해야 한다(첫 행 탈락이 user 전체를 막지 않음).
	m, _ := store.MatchedUsersForTitle(ctx, "삼성 갤럭시 중고 한정")
	if len(m) != 1 || m[0].UUID != "nnt_a" || m[0].Keyword != "삼성" {
		t.Errorf("fall-through to 삼성 row: want [nnt_a/삼성], got %+v", m)
	}
}

func TestMatchedUsersForTitle_ANDTokens(t *testing.T) {
	store := newStore(t)
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

func TestKeywordEnabledDefaultAndToggle(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()
	store.UpsertUser(ctx, "nnt_a")

	// 새 키워드는 기본 켜짐(enabled=true).
	store.AddKeyword(ctx, "nnt_a", "갤럭시")
	if _, err := store.UpsertKeyword(ctx, "nnt_a", "삼성", "중고"); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	keys, _ := store.ListKeywords(ctx, "nnt_a")
	if len(keys) != 2 {
		t.Fatalf("want 2 keys, got %+v", keys)
	}
	for _, k := range keys {
		if !k.Enabled {
			t.Errorf("new keyword %q should default enabled, got %+v", k.Keyword, k)
		}
	}

	// 토글 끄기 — exclude 는 보존돼야 한다(분리된 통로).
	if err := store.SetKeywordEnabled(ctx, "nnt_a", "삼성", false); err != nil {
		t.Fatalf("disable: %v", err)
	}
	keys, _ = store.ListKeywords(ctx, "nnt_a")
	for _, k := range keys {
		if k.Keyword == "삼성" {
			if k.Enabled {
				t.Errorf("삼성 should be disabled, got %+v", k)
			}
			if k.Exclude != "중고" {
				t.Errorf("toggle must preserve exclude, got %q", k.Exclude)
			}
		}
		if k.Keyword == "갤럭시" && !k.Enabled {
			t.Errorf("갤럭시 should stay enabled, got %+v", k)
		}
	}

	// exclude 편집(upsert) 후에도 토글(off) 보존 — 반환 enabled 도 false.
	on, err := store.UpsertKeyword(ctx, "nnt_a", "삼성", "판매")
	if err != nil {
		t.Fatalf("re-upsert: %v", err)
	}
	if on {
		t.Errorf("upsert must preserve disabled state, returned enabled=true")
	}

	// 다시 켜기.
	if err := store.SetKeywordEnabled(ctx, "nnt_a", "삼성", true); err != nil {
		t.Fatalf("enable: %v", err)
	}
	keys, _ = store.ListKeywords(ctx, "nnt_a")
	for _, k := range keys {
		if k.Keyword == "삼성" && !k.Enabled {
			t.Errorf("삼성 should be re-enabled, got %+v", k)
		}
	}

	// 없는 keyword 토글은 no-op(에러 없음).
	if err := store.SetKeywordEnabled(ctx, "nnt_a", "없음", false); err != nil {
		t.Errorf("toggle missing keyword should be no-op, got %v", err)
	}
}

func TestMatchedUsersCarriesEnabledAndSuppressesPush(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()
	store.UpsertUser(ctx, "nnt_a")
	store.SetPushToken(ctx, "nnt_a", "tok_a")
	store.AddKeyword(ctx, "nnt_a", "갤럭시")

	// 토글 켜진 키워드: 매칭 + Enabled=true(폴러가 push).
	m, _ := store.MatchedUsersForTitle(ctx, "갤럭시 S25")
	if len(m) != 1 || !m[0].Enabled {
		t.Fatalf("enabled keyword: want 1 match Enabled=true, got %+v", m)
	}

	// 토글 끄면: 여전히 매칭되어 1건 반환되지만 Enabled=false
	// (폴러가 이력만 남기고 push 는 건너뛴다).
	store.SetKeywordEnabled(ctx, "nnt_a", "갤럭시", false)
	m, _ = store.MatchedUsersForTitle(ctx, "갤럭시 S25")
	if len(m) != 1 {
		t.Fatalf("disabled keyword still matches (history-only): want 1, got %+v", m)
	}
	if m[0].Enabled {
		t.Errorf("disabled keyword: want Enabled=false, got %+v", m[0])
	}
}

func TestMatchedUsersPrefersEnabledKeyword(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()
	store.UpsertUser(ctx, "nnt_a")
	store.SetPushToken(ctx, "nnt_a", "tok_a")
	// "갤럭시"(끔, 알파벳상 먼저) + "삼성"(켬). 한 글이 둘 다 매칭될 때
	// enabled 행(삼성)이 선택돼야 push 가 간다.
	store.AddKeyword(ctx, "nnt_a", "갤럭시")
	store.AddKeyword(ctx, "nnt_a", "삼성")
	store.SetKeywordEnabled(ctx, "nnt_a", "갤럭시", false)

	m, _ := store.MatchedUsersForTitle(ctx, "삼성 갤럭시 핫딜")
	if len(m) != 1 {
		t.Fatalf("want 1 match (deduped), got %+v", m)
	}
	if m[0].Keyword != "삼성" || !m[0].Enabled {
		t.Errorf("want enabled '삼성' preferred, got %+v", m[0])
	}

	// 둘 다 끄면 한 행만(어느 쪽이든) Enabled=false 로 반환 — history-only.
	store.SetKeywordEnabled(ctx, "nnt_a", "삼성", false)
	m, _ = store.MatchedUsersForTitle(ctx, "삼성 갤럭시 핫딜")
	if len(m) != 1 || m[0].Enabled {
		t.Errorf("both disabled: want 1 match Enabled=false, got %+v", m)
	}
}

func TestMatchedUsersForTitle(t *testing.T) {
	store := newStore(t)
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
	store := newStore(t)
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
	store := newStore(t)
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
	store := newStore(t)
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
	store := newStore(t)
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

func TestMetricPayloadAccumulates(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()
	if err := store.UpsertUser(ctx, "nnt_x"); err != nil {
		t.Fatalf("upsert user: %v", err)
	}

	// 보관 제한 없이 전부 누적 — prune 으로 사라지는 행이 없어야 함.
	const total = 520
	for i := 0; i < total; i++ {
		payload := `{"i":` + strconv.Itoa(i) + `}`
		if err := store.InsertMetricPayload(ctx, "nnt_x", "metric", payload); err != nil {
			t.Fatalf("insert %d: %v", i, err)
		}
	}

	rows, err := store.ListMetricPayloads(ctx, total+10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != total {
		t.Fatalf("want all %d rows kept, got %d", total, len(rows))
	}
	// 최신순 — 첫 행이 마지막 삽입분, 마지막 행이 최초 삽입분.
	if rows[0].Payload != `{"i":`+strconv.Itoa(total-1)+`}` {
		t.Errorf("newest wrong: got %q", rows[0].Payload)
	}
	if rows[total-1].Payload != `{"i":0}` {
		t.Errorf("oldest pruned: got %q", rows[total-1].Payload)
	}
}

func TestMetricPayloadReceivedAtIsTimestamp(t *testing.T) {
	store := newStore(t)
	ctx := context.Background()
	if err := store.UpsertUser(ctx, "nnt_x"); err != nil {
		t.Fatalf("upsert user: %v", err)
	}
	if err := store.InsertMetricPayload(ctx, "nnt_x", "metric", `{"a":1}`); err != nil {
		t.Fatalf("insert: %v", err)
	}
	rows, err := store.ListMetricPayloads(ctx, 1)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("want 1 row, got %d", len(rows))
	}
	// received_at 은 timestamptz 로 저장되어 time.Time 으로 읽혀야 하고, DEFAULT
	// now() 가 채우므로 방금 시각이어야 한다.
	if d := time.Since(rows[0].ReceivedAt); d < 0 || d > time.Minute {
		t.Errorf("received_at not a recent timestamp: %v (since=%v)", rows[0].ReceivedAt, d)
	}
}

// --- 테스트 격리 헬퍼 ---

var schemaCounter int64

// testBaseDSN 테스트가 붙을 로컬 Postgres. NUNTING_TEST_DATABASE_URL 로 덮어쓸 수 있고,
// 기본은 로컬 nnt/nnt00. PG 가 없으면 newStore 가 t.Skip 한다.
func testBaseDSN() string {
	if v := os.Getenv("NUNTING_TEST_DATABASE_URL"); v != "" {
		return v
	}
	return "postgres://nnt:nnt00@localhost:5432/nnt?sslmode=disable"
}

// uniqueSchema 테스트별/프로세스별 유일한 schema 명. [a-z0-9_] 만 써서 인용 불필요.
func uniqueSchema() string {
	return fmt.Sprintf("t_%d_%d", os.Getpid(), atomic.AddInt64(&schemaCounter, 1))
}

// newStore 격리된 schema 위에 Store 를 연다. :memory: 시절의 테스트별 격리를 대체.
// PG 미연결이면 skip(테스트 머신에 로컬 PG 가 없을 수 있음). cleanup 은 별도 admin
// connection 으로 schema 를 DROP 하므로, 테스트가 store 를 먼저 닫아도 누수 없다.
func newStore(t *testing.T) *Store {
	t.Helper()
	base := testBaseDSN()
	schema := uniqueSchema()
	store, err := OpenSchema(base, schema)
	if err != nil {
		t.Skipf("postgres 미연결(%v) — NUNTING_TEST_DATABASE_URL 설정 또는 로컬 PG 필요", err)
	}
	t.Cleanup(func() {
		_ = store.Close()
		if admin, err := sql.Open("pgx", base); err == nil {
			_, _ = admin.Exec(`DROP SCHEMA IF EXISTS "` + schema + `" CASCADE`)
			_ = admin.Close()
		}
	})
	return store
}
