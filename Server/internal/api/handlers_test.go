package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Moonjm/nunting/server/internal/db"
	"github.com/Moonjm/nunting/server/internal/dbtest"
)

func newTestServer(t *testing.T) (*httptest.Server, *db.Store) {
	t.Helper()
	store := dbtest.New(t)
	return httptest.NewServer(NewRouter(store)), store
}

func do(t *testing.T, method, url, token, body string) (int, string) {
	t.Helper()
	var rdr io.Reader
	if body != "" {
		rdr = bytes.NewReader([]byte(body))
	}
	req, _ := http.NewRequest(method, url, rdr)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func TestHealth(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	code, body := do(t, "GET", srv.URL+"/health", "", "")
	if code != 200 || body != "ok" {
		t.Errorf("want 200 'ok', got %d %q", code, body)
	}
}

func TestEcho(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	code, body := do(t, "GET", srv.URL+"/me/_echo", "nnt_x", "")
	if code != 200 || body != "nnt_x" {
		t.Errorf("want 200 'nnt_x', got %d %q", code, body)
	}
}

func TestPushTokenSetAndClear(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	code, _ := do(t, "PUT", srv.URL+"/me/push-token", "nnt_x", `{"token":"hex123"}`)
	if code != 200 {
		t.Fatalf("set: want 200, got %d", code)
	}
	code, _ = do(t, "PUT", srv.URL+"/me/push-token", "nnt_x", `{"token":null}`)
	if code != 200 {
		t.Fatalf("clear: want 200, got %d", code)
	}
}

func TestKeywordsCRUD(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	code, body := do(t, "GET", srv.URL+"/me/keywords", "nnt_x", "")
	if code != 200 || body != "[]" {
		t.Errorf("empty list: want 200 '[]', got %d %q", code, body)
	}

	code, body = do(t, "POST", srv.URL+"/me/keywords", "nnt_x", `{"keyword":"갤럭시"}`)
	if code != 200 {
		t.Fatalf("add: want 200, got %d body=%q", code, body)
	}
	if body != `{"keyword":"갤럭시","exclude":"","enabled":true}` {
		t.Errorf("add response: got %q", body)
	}

	code, body = do(t, "GET", srv.URL+"/me/keywords", "nnt_x", "")
	if code != 200 || body != `[{"keyword":"갤럭시","exclude":"","enabled":true}]` {
		t.Errorf("list-1: got %d %q", code, body)
	}

	code, _ = do(t, "DELETE", srv.URL+"/me/keywords/%EA%B0%A4%EB%9F%AD%EC%8B%9C", "nnt_x", "")
	if code != 200 {
		t.Errorf("delete: want 200, got %d", code)
	}

	code, body = do(t, "GET", srv.URL+"/me/keywords", "nnt_x", "")
	if code != 200 || body != "[]" {
		t.Errorf("after-delete: got %d %q", code, body)
	}
}

func TestKeywordRawTooLongRejected(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	// 콤마 폭탄 — normalizeKeyword 가 Split 으로 메모리 폭발하기 전에 차단되어야.
	huge := strings.Repeat("a,", 1000) // 2000 chars, > maxRawKeywordLength=500
	body := `{"keyword":"` + huge + `"}`
	code, _ := do(t, "POST", srv.URL+"/me/keywords", "nnt_x", body)
	if code != 400 {
		t.Errorf("raw too long: want 400, got %d", code)
	}
}

func TestKeywordEmptyRejected(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	code, _ := do(t, "POST", srv.URL+"/me/keywords", "nnt_x", `{"keyword":"   "}`)
	if code != 400 {
		t.Errorf("whitespace-only: want 400, got %d", code)
	}
}

func TestKeywordANDNormalization(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	// 1) 입력 "삼다수, 500ML" → 응답 {"keyword":"500ml,삼다수","exclude":""}
	code, body := do(t, "POST", srv.URL+"/me/keywords", "nnt_x", `{"keyword":"삼다수, 500ML"}`)
	if code != 200 {
		t.Fatalf("add AND: want 200, got %d body=%q", code, body)
	}
	if body != `{"keyword":"500ml,삼다수","exclude":"","enabled":true}` {
		t.Errorf("normalized add response: got %q", body)
	}

	// 2) 순서만 다른 입력 → 같은 키 (중복 row 생성 안 됨)
	code, _ = do(t, "POST", srv.URL+"/me/keywords", "nnt_x", `{"keyword":"500ml,삼다수"}`)
	if code != 200 {
		t.Fatalf("add reorder: want 200, got %d", code)
	}
	code, body = do(t, "GET", srv.URL+"/me/keywords", "nnt_x", "")
	if code != 200 || body != `[{"keyword":"500ml,삼다수","exclude":"","enabled":true}]` {
		t.Errorf("list after reorder add: got %d %q (want one item)", code, body)
	}

	// 3) 콤마만 / 공백만 → 400
	code, _ = do(t, "POST", srv.URL+"/me/keywords", "nnt_x", `{"keyword":",, ,"}`)
	if code != 400 {
		t.Errorf("commas-only: want 400, got %d", code)
	}

	// 4) 비정규화된 형태로 DELETE 요청 → 정규화 후 삭제 성공
	// "삼다수, 500ML" → "500ml,삼다수" 와 동일 row 삭제.
	encoded := "%EC%82%BC%EB%8B%A4%EC%88%98%2C%20500ML" // "삼다수, 500ML"
	code, _ = do(t, "DELETE", srv.URL+"/me/keywords/"+encoded, "nnt_x", "")
	if code != 200 {
		t.Fatalf("delete denormalized: want 200, got %d", code)
	}
	code, body = do(t, "GET", srv.URL+"/me/keywords", "nnt_x", "")
	if code != 200 || body != "[]" {
		t.Errorf("after delete: got %d %q", code, body)
	}
}

func TestKeywordExcludeUpsert(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	// 포함+제외 동시 등록. 제외도 정규화됨("중고, 판매" → "중고,판매").
	code, body := do(t, "POST", srv.URL+"/me/keywords", "nnt_x",
		`{"keyword":"갤럭시","exclude":"판매, 중고"}`)
	if code != 200 {
		t.Fatalf("add with exclude: want 200, got %d body=%q", code, body)
	}
	if body != `{"keyword":"갤럭시","exclude":"중고,판매","enabled":true}` {
		t.Errorf("exclude normalized response: got %q", body)
	}

	// 같은 keyword 로 재 POST → 제외만 갱신(행 중복 없이 upsert).
	code, body = do(t, "POST", srv.URL+"/me/keywords", "nnt_x",
		`{"keyword":"갤럭시","exclude":"리퍼"}`)
	if code != 200 {
		t.Fatalf("edit exclude: want 200, got %d", code)
	}
	if body != `{"keyword":"갤럭시","exclude":"리퍼","enabled":true}` {
		t.Errorf("edited exclude response: got %q", body)
	}
	code, body = do(t, "GET", srv.URL+"/me/keywords", "nnt_x", "")
	if code != 200 || body != `[{"keyword":"갤럭시","exclude":"리퍼","enabled":true}]` {
		t.Errorf("list after exclude edit: got %d %q (want single upserted row)", code, body)
	}

	// 제외 생략 → "제외 없음"으로 갱신.
	code, _ = do(t, "POST", srv.URL+"/me/keywords", "nnt_x", `{"keyword":"갤럭시"}`)
	if code != 200 {
		t.Fatalf("clear exclude: want 200, got %d", code)
	}
	code, body = do(t, "GET", srv.URL+"/me/keywords", "nnt_x", "")
	if code != 200 || body != `[{"keyword":"갤럭시","exclude":"","enabled":true}]` {
		t.Errorf("list after clearing exclude: got %d %q", code, body)
	}
}

func TestKeywordEnabledToggle(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	// 제외 포함 등록 후 토글 off → 응답/리스트에 enabled=false, exclude 보존.
	do(t, "POST", srv.URL+"/me/keywords", "nnt_x", `{"keyword":"갤럭시","exclude":"중고"}`)
	code, _ := do(t, "POST", srv.URL+"/me/keywords/%EA%B0%A4%EB%9F%AD%EC%8B%9C/enabled", "nnt_x", `{"enabled":false}`)
	if code != 200 {
		t.Fatalf("toggle off: want 200, got %d", code)
	}
	code, body := do(t, "GET", srv.URL+"/me/keywords", "nnt_x", "")
	if code != 200 || body != `[{"keyword":"갤럭시","exclude":"중고","enabled":false}]` {
		t.Errorf("after toggle off: got %d %q", code, body)
	}

	// exclude 편집(upsert) 해도 토글 off 보존 — 응답 enabled=false.
	code, body = do(t, "POST", srv.URL+"/me/keywords", "nnt_x", `{"keyword":"갤럭시","exclude":"리퍼"}`)
	if code != 200 || body != `{"keyword":"갤럭시","exclude":"리퍼","enabled":false}` {
		t.Errorf("upsert preserves toggle: got %d %q", code, body)
	}

	// 다시 on.
	code, _ = do(t, "POST", srv.URL+"/me/keywords/%EA%B0%A4%EB%9F%AD%EC%8B%9C/enabled", "nnt_x", `{"enabled":true}`)
	if code != 200 {
		t.Fatalf("toggle on: want 200, got %d", code)
	}
	code, body = do(t, "GET", srv.URL+"/me/keywords", "nnt_x", "")
	if code != 200 || body != `[{"keyword":"갤럭시","exclude":"리퍼","enabled":true}]` {
		t.Errorf("after toggle on: got %d %q", code, body)
	}
}

func TestNormalizeKeyword(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		// single token (회귀 가드)
		{"갤럭시", "갤럭시"},
		{"  갤럭시  ", "갤럭시"},
		{"iPhone", "iphone"},
		{"IPHONE", "iphone"},

		// AND tokens — 정렬 + 소문자 + 공백 제거
		{"삼다수, 500ml", "500ml,삼다수"},
		{"500ml, 삼다수", "500ml,삼다수"},
		{"500ML,  삼다수", "500ml,삼다수"},

		// dedup (동일 토큰 반복)
		{"삼다수,삼다수, 500ml", "500ml,삼다수"},
		{"삼다수, 삼다수", "삼다수"},

		// empty 토큰 drop
		{",,500ml,,", "500ml"},
		{" , , ", ""},
		{"", ""},
		{"   ", ""},
	}
	for _, c := range cases {
		got := normalizeKeyword(c.in)
		if got != c.want {
			t.Errorf("normalizeKeyword(%q): want %q, got %q", c.in, c.want, got)
		}
	}
}

func TestAlertHistoryEndpoint(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	// 빈 이력은 "null" 이 아니라 "[]" 여야 함. (요청이 user 도 생성)
	code, body := do(t, "GET", srv.URL+"/me/alert-history", "nnt_x", "")
	if code != 200 || strings.TrimSpace(body) != "[]" {
		t.Fatalf("empty: want 200 '[]', got %d %q", code, body)
	}

	if _, err := store.RecordAlert(t.Context(), "nnt_x", "갤럭시", "1001", "갤럭시 핫딜", "https://m.ppomppu.co.kr/1001"); err != nil {
		t.Fatalf("record: %v", err)
	}

	code, body = do(t, "GET", srv.URL+"/me/alert-history?limit=10", "nnt_x", "")
	if code != 200 {
		t.Fatalf("want 200, got %d %q", code, body)
	}
	var items []db.AlertHistoryItem
	if err := json.Unmarshal([]byte(body), &items); err != nil {
		t.Fatalf("decode %q: %v", body, err)
	}
	if len(items) != 1 || items[0].Keyword != "갤럭시" || items[0].Title != "갤럭시 핫딜" {
		t.Fatalf("unexpected items: %+v", items)
	}
	if items[0].URL != "https://m.ppomppu.co.kr/1001" || items[0].PostNo != "1001" {
		t.Errorf("unexpected row: %+v", items[0])
	}
	if items[0].Read || items[0].ID == 0 {
		t.Errorf("want unread with id set, got %+v", items[0])
	}

	// 읽음 마킹 후 read=true 로 바뀌어야 함.
	id := items[0].ID
	code, _ = do(t, "POST", srv.URL+fmt.Sprintf("/me/alert-history/%d/read", id), "nnt_x", "")
	if code != 200 {
		t.Fatalf("mark read: want 200, got %d", code)
	}
	_, body = do(t, "GET", srv.URL+"/me/alert-history", "nnt_x", "")
	_ = json.Unmarshal([]byte(body), &items)
	if !items[0].Read {
		t.Errorf("want read=true after mark, got %+v", items[0])
	}

	// 잘못된 id → 400.
	code, _ = do(t, "POST", srv.URL+"/me/alert-history/abc/read", "nnt_x", "")
	if code != 400 {
		t.Errorf("invalid id: want 400, got %d", code)
	}
}

func TestPostMetricsStoresPayload(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	body := `{"applicationExitMetric":{"foregroundExitData":{"cumulativeMemoryResourceLimitExitCount":3}}}`
	code, resp := do(t, "POST", srv.URL+"/me/metrics?kind=metric", "nnt_x", body)
	if code != 200 {
		t.Fatalf("post metrics: want 200, got %d body=%q", code, resp)
	}

	rows, err := store.ListMetricPayloads(t.Context(), 10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 || rows[0].Kind != "metric" || rows[0].UUID != "nnt_x" {
		t.Fatalf("unexpected rows: %+v", rows)
	}
	if rows[0].Payload != body {
		t.Errorf("payload not stored verbatim: %q", rows[0].Payload)
	}
}

// kind=parser — iOS ParserFailureTelemetry 가 올리는 structureChanged 집계.
// {site, phase, detail} 작은 JSON 이며 metric/diagnostic 과 같은 경로로 저장된다.
func TestPostMetricsAcceptsParserKind(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	body := `{"site":"clien","phase":"list","detail":"clien-news 목록 0건 (24000B)"}`
	code, resp := do(t, "POST", srv.URL+"/me/metrics?kind=parser", "nnt_x", body)
	if code != 200 {
		t.Fatalf("post parser metric: want 200, got %d body=%q", code, resp)
	}

	rows, err := store.ListMetricPayloads(t.Context(), 10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 || rows[0].Kind != "parser" {
		t.Fatalf("unexpected rows: %+v", rows)
	}
}

func TestPostMetricsRejectsBadKindAndJSON(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	// kind 누락/오타 → 400.
	if code, _ := do(t, "POST", srv.URL+"/me/metrics", "nnt_x", `{}`); code != 400 {
		t.Errorf("missing kind: want 400, got %d", code)
	}
	if code, _ := do(t, "POST", srv.URL+"/me/metrics?kind=bogus", "nnt_x", `{}`); code != 400 {
		t.Errorf("bad kind: want 400, got %d", code)
	}
	// 깨진 JSON → 400.
	if code, _ := do(t, "POST", srv.URL+"/me/metrics?kind=metric", "nnt_x", `{not json`); code != 400 {
		t.Errorf("bad json: want 400, got %d", code)
	}
	// 인증 없음 → 401 (/me 그룹).
	if code, _ := do(t, "POST", srv.URL+"/me/metrics?kind=metric", "", `{}`); code != 401 {
		t.Errorf("no auth: want 401, got %d", code)
	}
}

func TestPostMetricsAcceptsLargeBody(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	// 일반 라우트 4KB 상한을 넘는 페이로드도 metrics 는 받아야 한다(크래시 콜스택).
	// ~20KB 본문 — 일반 라우트 maxBodyBytes(4KB)는 넘고 metrics 1MB 상한 안.
	big := `{"crashDiagnostics":[{"diagnosticMetaData":{"terminationReason":"` +
		strings.Repeat("X", 20000) + `"}}]}`
	code, resp := do(t, "POST", srv.URL+"/me/metrics?kind=diagnostic", "nnt_x", big)
	if code != 200 {
		t.Fatalf("large body: want 200, got %d body=%q", code, resp)
	}
}

func TestAdminMetricsRequiresKey(t *testing.T) {
	t.Setenv("NUNTING_ADMIN_KEY", "s3cret")
	store := dbtest.New(t)
	defer store.Close()
	srv := httptest.NewServer(NewRouter(store))
	defer srv.Close()

	// payload 하나 넣어두고(FK 충족 위해 user 먼저).
	if err := store.UpsertUser(t.Context(), "nnt_x"); err != nil {
		t.Fatalf("upsert user: %v", err)
	}
	// 키는 실제 MetricKit jsonRepresentation() 과 동일하게 복수형
	// "applicationExitMetrics" — 단수형 픽스처를 쓰면 실기기 payload 와 달라
	// 파서의 키 불일치를 못 잡는다(실제로 그렇게 놓친 전적).
	if err := store.InsertMetricPayload(t.Context(), "nnt_x", "metric",
		`{"applicationExitMetrics":{"foregroundExitData":{"cumulativeMemoryResourceLimitExitCount":5}}}`); err != nil {
		t.Fatalf("insert: %v", err)
	}

	// key 없음/오답 → 404.
	if code, _ := do(t, "GET", srv.URL+"/admin/metrics", "", ""); code != 404 {
		t.Errorf("no key: want 404, got %d", code)
	}
	if code, _ := do(t, "GET", srv.URL+"/admin/metrics?key=wrong", "", ""); code != 404 {
		t.Errorf("wrong key: want 404, got %d", code)
	}

	// 정답 → 200 + 요약에 fg OOM 카운트 노출.
	code, body := do(t, "GET", srv.URL+"/admin/metrics?key=s3cret", "", "")
	if code != 200 {
		t.Fatalf("right key: want 200, got %d", code)
	}
	if !strings.Contains(body, "fg OOM") || !strings.Contains(body, ">5<") {
		t.Errorf("summary missing fg OOM count, body=%q", body)
	}
}

func TestAdminMetricsDisabledWithoutEnv(t *testing.T) {
	t.Setenv("NUNTING_ADMIN_KEY", "")
	store := dbtest.New(t)
	defer store.Close()
	srv := httptest.NewServer(NewRouter(store))
	defer srv.Close()

	// adminKey 빈 값이면 어떤 key 로도 404(기능 비활성).
	if code, _ := do(t, "GET", srv.URL+"/admin/metrics?key=anything", "", ""); code != 404 {
		t.Errorf("disabled admin: want 404, got %d", code)
	}
}

func TestPostMetricsRejectsOversizeBody(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	// maxMetricBodyBytes(1<<20 = 1MB)를 넘는 본문은 413 으로 거부돼야 한다.
	// +1000 으로 상한을 확실히 초과시킨다(본문 ≈ 1,049,584 bytes > 1MB).
	big := `{"x":"` + strings.Repeat("Z", (1<<20)+1000) + `"}`
	code, _ := do(t, "POST", srv.URL+"/me/metrics?kind=diagnostic", "nnt_x", big)
	if code != 413 {
		t.Errorf("oversize body: want 413, got %d", code)
	}
}

func TestAdminMetricsSummarizesDiagnostic(t *testing.T) {
	t.Setenv("NUNTING_ADMIN_KEY", "s3cret")
	store := dbtest.New(t)
	defer store.Close()
	srv := httptest.NewServer(NewRouter(store))
	defer srv.Close()

	if err := store.UpsertUser(t.Context(), "nnt_x"); err != nil {
		t.Fatalf("upsert user: %v", err)
	}
	diag := `{"crashDiagnostics":[{"diagnosticMetaData":{"terminationReason":"per-process-limit"}}],"hangDiagnostics":[{}]}`
	if err := store.InsertMetricPayload(t.Context(), "nnt_x", "diagnostic", diag); err != nil {
		t.Fatalf("insert: %v", err)
	}

	code, body := do(t, "GET", srv.URL+"/admin/metrics?key=s3cret", "", "")
	if code != 200 {
		t.Fatalf("admin: want 200, got %d", code)
	}
	// crash 카운트 카드(1)와 요약의 terminationReason 이 노출돼야 한다.
	if !strings.Contains(body, "crashes") || !strings.Contains(body, ">1<") {
		t.Errorf("crash count card missing, body=%q", body)
	}
	if !strings.Contains(body, "per-process-limit") {
		t.Errorf("termination reason missing from summary, body=%q", body)
	}
}

func TestPostFootprintStoresBatch(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	body := `{"samples":[{"ts":1718541600,"label":"board:뽐뿌","mb":312,"avail":1800},` +
		`{"ts":1718541605,"label":"post-open","mb":540,"avail":1500}]}`
	code, resp := do(t, "POST", srv.URL+"/me/footprint", "nnt_x", body)
	if code != 200 {
		t.Fatalf("post footprint: want 200, got %d body=%q", code, resp)
	}

	rows, err := store.ListFootprintSamples(t.Context(), 10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("want 2 rows, got %d", len(rows))
	}
	// 최신순(id DESC) — post-open 이 먼저.
	if rows[0].Label != "post-open" || rows[0].MB != 540 || rows[1].Label != "board:뽐뿌" {
		t.Errorf("unexpected rows: %+v", rows)
	}
}

func TestPostFootprintStoresMallocStats(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	// 새 진단 필드: live(=malloc size_in_use), alloc(=size_allocated).
	// gap(alloc-live)=단편화. client ts 는 timestamp 로 저장되어야 한다.
	body := `{"samples":[{"ts":1718541600,"label":"post-open","mb":540,"avail":1500,"live":420,"alloc":900}]}`
	code, resp := do(t, "POST", srv.URL+"/me/footprint", "nnt_x", body)
	if code != 200 {
		t.Fatalf("post footprint: want 200, got %d body=%q", code, resp)
	}

	rows, err := store.ListFootprintSamples(t.Context(), 10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("want 1 row, got %d", len(rows))
	}
	r := rows[0]
	if r.LiveMB != 420 || r.AllocMB != 900 {
		t.Errorf("malloc stats not stored: live=%d alloc=%d (want 420/900)", r.LiveMB, r.AllocMB)
	}
	if r.ClientTS.Unix() != 1718541600 {
		t.Errorf("client_ts not stored as timestamp: %v (want unix 1718541600)", r.ClientTS)
	}
}

func TestPostFootprintRejectsBad(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	// 깨진 JSON → 400.
	if code, _ := do(t, "POST", srv.URL+"/me/footprint", "nnt_x", `{bad`); code != 400 {
		t.Errorf("bad json: want 400, got %d", code)
	}
	// 빈 배치 → 200 (멱등 no-op).
	if code, _ := do(t, "POST", srv.URL+"/me/footprint", "nnt_x", `{"samples":[]}`); code != 200 {
		t.Errorf("empty batch: want 200, got %d", code)
	}
	// 인증 없음 → 401.
	if code, _ := do(t, "POST", srv.URL+"/me/footprint", "", `{"samples":[]}`); code != 401 {
		t.Errorf("no auth: want 401, got %d", code)
	}
}

func TestAdminMetricsRendersFootprint(t *testing.T) {
	t.Setenv("NUNTING_ADMIN_KEY", "s3cret")
	store := dbtest.New(t)
	defer store.Close()
	srv := httptest.NewServer(NewRouter(store))
	defer srv.Close()

	if err := store.UpsertUser(t.Context(), "nnt_x"); err != nil {
		t.Fatalf("upsert user: %v", err)
	}
	samples := []db.FootprintSample{
		{ClientTS: 1718541600, Label: "board:뽐뿌", MB: 300, AvailMB: 1800},
		{ClientTS: 1718541605, Label: "post-open", MB: 540, AvailMB: 1500},
	}
	if err := store.InsertFootprintSamples(t.Context(), "nnt_x", samples); err != nil {
		t.Fatalf("insert: %v", err)
	}

	code, body := do(t, "GET", srv.URL+"/admin/metrics?key=s3cret", "", "")
	if code != 200 {
		t.Fatalf("admin: want 200, got %d", code)
	}
	// footprint 섹션 + 피크(540) + Δ(+240) 노출.
	if !strings.Contains(body, "memory footprint") || !strings.Contains(body, "peak 540 MB") {
		t.Errorf("footprint section/peak missing, body=%q", body)
	}
	if !strings.Contains(body, "+240") {
		t.Errorf("delta missing, body=%q", body)
	}
}

func TestAdminMetricsFootprintDeltaPerDevice(t *testing.T) {
	t.Setenv("NUNTING_ADMIN_KEY", "s3cret")
	store := dbtest.New(t)
	defer store.Close()
	srv := httptest.NewServer(NewRouter(store))
	defer srv.Close()

	for _, u := range []string{"nnt_a", "nnt_b"} {
		if err := store.UpsertUser(t.Context(), u); err != nil {
			t.Fatalf("upsert %s: %v", u, err)
		}
	}
	// 두 기기를 시간상 교차로 삽입. b 의 첫 샘플(900)이 a 의 직전값(310)을
	// 기준으로 Δ 계산되면 +590 오탐이 난다 — UUID별 추적이면 b 첫 샘플 Δ=0.
	if err := store.InsertFootprintSamples(t.Context(), "nnt_a",
		[]db.FootprintSample{{ClientTS: 1, Label: "a1", MB: 300, AvailMB: 100}}); err != nil {
		t.Fatal(err)
	}
	if err := store.InsertFootprintSamples(t.Context(), "nnt_a",
		[]db.FootprintSample{{ClientTS: 2, Label: "a2", MB: 310, AvailMB: 100}}); err != nil {
		t.Fatal(err)
	}
	if err := store.InsertFootprintSamples(t.Context(), "nnt_b",
		[]db.FootprintSample{{ClientTS: 3, Label: "b1", MB: 900, AvailMB: 100}}); err != nil {
		t.Fatal(err)
	}

	_, body := do(t, "GET", srv.URL+"/admin/metrics?key=s3cret", "", "")
	// a2 는 a1 대비 +10, b1 은 기기 첫 샘플이라 0 — 590 오탐이 없어야 한다.
	if !strings.Contains(body, "+10") {
		t.Errorf("expected a-device delta +10, body=%q", body)
	}
	if strings.Contains(body, "590") {
		t.Errorf("cross-device delta leaked (+590), body=%q", body)
	}
}

// kind=hang — iOS HangWatchdog(인앱 메인스레드 감시)이 올리는 hang 리포트.
// MetricKit diagnostic 이 Xcode 설치 빌드에 안 와서 만든 직접 수집 채널.
func TestPostMetricsAcceptsHangKind(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	body := `{"ts":1752000000,"durationMs":3120,"label":"post:open",` +
		`"samples":[{"atMs":1000,"frames":["0 nunting decode + 12","1 nunting layout + 4"]}]}`
	code, resp := do(t, "POST", srv.URL+"/me/metrics?kind=hang", "nnt_x", body)
	if code != 200 {
		t.Fatalf("post hang metric: want 200, got %d body=%q", code, resp)
	}

	rows, err := store.ListMetricPayloads(t.Context(), 10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 || rows[0].Kind != "hang" {
		t.Fatalf("unexpected rows: %+v", rows)
	}
}

func TestAdminMetricsSummarizesHang(t *testing.T) {
	t.Setenv("NUNTING_ADMIN_KEY", "s3cret")
	store := dbtest.New(t)
	defer store.Close()
	srv := httptest.NewServer(NewRouter(store))
	defer srv.Close()

	if err := store.UpsertUser(t.Context(), "nnt_x"); err != nil {
		t.Fatalf("upsert user: %v", err)
	}
	hang := `{"ts":1752000000,"durationMs":3120,"label":"post:open",` +
		`"samples":[{"atMs":1000,"frames":["0 nunting decode + 12"]},{"atMs":2000,"frames":["0 nunting layout + 4"]}]}`
	if err := store.InsertMetricPayload(t.Context(), "nnt_x", "hang", hang); err != nil {
		t.Fatalf("insert: %v", err)
	}

	code, body := do(t, "GET", srv.URL+"/admin/metrics?key=s3cret", "", "")
	if code != 200 {
		t.Fatalf("admin: want 200, got %d", code)
	}
	// hangs 카드가 1 로 집계되고, 요약에 지속시간·라벨이 노출돼야 한다.
	if !strings.Contains(body, "hangs") || !strings.Contains(body, ">1<") {
		t.Errorf("hang count card missing, body=%q", body)
	}
	if !strings.Contains(body, "3.1s") || !strings.Contains(body, "post:open") {
		t.Errorf("hang summary missing duration/label, body=%q", body)
	}
}

// kind=hitch — iOS FrameHitchRecorder 가 올리는 인터랙션 구간 프레임 히치.
// hang 임계(1s) 아래로 새는 "몇 프레임 빠짐" 을 보기 위한 채널.
func TestPostMetricsAcceptsHitchKind(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	hitch := `{"ts":1753000000,"label":"backdrag","context":"comments 210/400",` +
		`"durationMs":900,"frameCount":72,"droppedFrames":9,"worstFrameMs":68.2,` +
		`"expectedFrameMs":8.3,"worstFrames":[68.2,41.7],"sessionDrags":13}`
	if code, _ := do(t, "POST", srv.URL+"/me/metrics?kind=hitch", "nnt_x", hitch); code != 200 {
		t.Fatalf("post hitch: want 200, got %d", code)
	}

	rows, err := store.ListMetricPayloads(t.Context(), 10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 || rows[0].Kind != "hitch" {
		t.Fatalf("unexpected rows: %+v", rows)
	}
}

func TestAdminMetricsSummarizesHitch(t *testing.T) {
	t.Setenv("NUNTING_ADMIN_KEY", "s3cret")
	store := dbtest.New(t)
	defer store.Close()
	srv := httptest.NewServer(NewRouter(store))
	defer srv.Close()

	if err := store.UpsertUser(t.Context(), "nnt_x"); err != nil {
		t.Fatalf("upsert user: %v", err)
	}
	hitch := `{"ts":1753000000,"label":"backdrag","context":"comments 210/400",` +
		`"durationMs":900,"frameCount":72,"droppedFrames":9,"worstFrameMs":68.2,` +
		`"expectedFrameMs":8.3,"worstFrames":[68.2,41.7],"sessionDrags":13}`
	if err := store.InsertMetricPayload(t.Context(), "nnt_x", "hitch", hitch); err != nil {
		t.Fatalf("insert: %v", err)
	}

	code, body := do(t, "GET", srv.URL+"/admin/metrics?key=s3cret", "", "")
	if code != 200 {
		t.Fatalf("admin: want 200, got %d", code)
	}
	// 요약에 원인 특정용 세 축(드랍 수, 최악 프레임, context)이 다 보여야 한다.
	for _, want := range []string{"9 dropped", "68ms", "backdrag", "comments 210/400"} {
		if !strings.Contains(body, want) {
			t.Errorf("hitch summary missing %q, body=%q", want, body)
		}
	}
	// dropped frames 카드에 누적된다.
	if !strings.Contains(body, "dropped frames") {
		t.Errorf("dropped frames card missing, body=%q", body)
	}
}

func TestPostMetricsAcceptsMediaKind(t *testing.T) {
	srv, store := newTestServer(t)
	defer srv.Close()
	defer store.Close()

	media := `{"events":[{"t":"net","ts":1753000000,"ms":950,"host":"img.fmkorea.com",` +
		`"link":"cell","bytes":812345,"dns":30,"conn":120,"tls":90,"ttfb":240,` +
		`"proto":"h2","reused":false,"status":200}]}`
	if code, _ := do(t, "POST", srv.URL+"/me/metrics?kind=media", "nnt_x", media); code != 200 {
		t.Fatalf("post media: want 200, got %d", code)
	}

	rows, err := store.ListMetricPayloads(t.Context(), 10)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 1 || rows[0].Kind != "media" {
		t.Fatalf("unexpected rows: %+v", rows)
	}
}

// 미디어 섹션은 "느린 게 회선이냐 캐시냐 서버냐"를 한 화면에서 갈라야 한다 —
// 계층별 분포, 캐시 출처, 링크별 비교, 느린 호스트가 모두 렌더돼야 한다.
func TestAdminMetricsRendersMediaSection(t *testing.T) {
	t.Setenv("NUNTING_ADMIN_KEY", "s3cret")
	store := dbtest.New(t)
	defer store.Close()
	srv := httptest.NewServer(NewRouter(store))
	defer srv.Close()

	if err := store.UpsertUser(t.Context(), "nnt_x"); err != nil {
		t.Fatalf("upsert user: %v", err)
	}
	media := `{"events":[` +
		`{"t":"net","ts":1753000000,"ms":950,"host":"img.fmkorea.com","link":"cell","bytes":800000,"ttfb":240,"proto":"h2","reused":false,"status":200},` +
		`{"t":"net","ts":1753000001,"ms":150,"host":"i.namu.wiki","link":"wifi","bytes":20000,"ttfb":80,"proto":"h2","reused":true,"status":200},` +
		`{"t":"show","ts":1753000002,"ms":12,"host":"img.fmkorea.com","link":"wifi","src":"mem","ctx":"body"},` +
		`{"t":"show","ts":1753000003,"ms":980,"host":"img.fmkorea.com","link":"cell","src":"net","ctx":"body","ok":false},` +
		`{"t":"video","ts":1753000004,"ms":1800,"host":"v.aagag.com","link":"wifi","kind":"webm","ctx":"body"}` +
		`]}`
	if err := store.InsertMetricPayload(t.Context(), "nnt_x", "media", media); err != nil {
		t.Fatalf("insert: %v", err)
	}

	code, body := do(t, "GET", srv.URL+"/admin/metrics?key=s3cret", "", "")
	if code != 200 {
		t.Fatalf("admin: want 200, got %d", code)
	}
	for _, want := range []string{
		"미디어 로딩",          // 섹션
		"img.fmkorea.com", // 느린 호스트
		"wifi", "cell",    // 링크별 비교
		"mem",   // 캐시 출처 분포
		"webm",  // 영상 컨테이너
		"950ms", // net p50(2건 중 느린 쪽이 p90, 여기선 값 노출 확인)
	} {
		if !strings.Contains(body, want) {
			t.Errorf("media section missing %q", want)
		}
	}
}

func TestPercentile(t *testing.T) {
	vals := []int{50, 10, 40, 20, 30} // 정렬 안 된 입력도 받는다

	if got := percentile(vals, 50); got != 30 {
		t.Errorf("p50: want 30, got %d", got)
	}
	if got := percentile(vals, 90); got != 50 {
		t.Errorf("p90: want 50, got %d", got)
	}
	if got := percentile(nil, 50); got != 0 {
		t.Errorf("빈 입력은 0: got %d", got)
	}
	if got := percentile([]int{7}, 90); got != 7 {
		t.Errorf("한 건이면 그 값: got %d", got)
	}
}

// 파이프라인 분해: 다운로드 슬롯 대기(queued)와 디코드(decode)가 표에 보여야
// "느린 게 큐냐 디코드냐"를 대시보드에서 바로 가른다.
func TestAdminMetricsSplitsMediaPipeline(t *testing.T) {
	t.Setenv("NUNTING_ADMIN_KEY", "s3cret")
	store := dbtest.New(t)
	defer store.Close()
	srv := httptest.NewServer(NewRouter(store))
	defer srv.Close()

	if err := store.UpsertUser(t.Context(), "nnt_x"); err != nil {
		t.Fatalf("upsert user: %v", err)
	}
	media := `{"events":[` +
		`{"t":"net","ts":1753000000,"ms":60,"host":"upload3.inven.co.kr","link":"wifi","bytes":150000,"queued":2500},` +
		`{"t":"net","ts":1753000001,"ms":70,"host":"upload3.inven.co.kr","link":"wifi","bytes":160000,"queued":4800},` +
		`{"t":"decode","ts":1753000002,"ms":180,"kind":"webpStatic","px":3110400,"bytes":214003},` +
		`{"t":"decode","ts":1753000003,"ms":950,"kind":"webpStatic","px":8294400,"bytes":512000}` +
		`]}`
	if err := store.InsertMetricPayload(t.Context(), "nnt_x", "media", media); err != nil {
		t.Fatalf("insert: %v", err)
	}

	code, body := do(t, "GET", srv.URL+"/admin/metrics?key=s3cret", "", "")
	if code != 200 {
		t.Fatalf("admin: want 200, got %d", code)
	}
	for _, want := range []string{
		"decode (디코드)", // 계층 행 라벨 — raw JSON 에도 "decode" 가 있어 라벨로 검사
		"webpStatic 2", // 코더별 건수
		"대기",           // net 행의 슬롯 대기
		"4.8s",         // 대기 p90
		"950ms",        // 디코드 p90
		"MP",           // 픽셀 규모 — 무거운 이미지인지 큐 적체인지 가르는 축
	} {
		if !strings.Contains(body, want) {
			t.Errorf("pipeline split missing %q", want)
		}
	}
}
