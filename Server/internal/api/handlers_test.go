package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Moonjm/nunting/server/internal/db"
)

func newTestServer(t *testing.T) (*httptest.Server, *db.Store) {
	t.Helper()
	store, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("db: %v", err)
	}
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
	var added string
	json.Unmarshal([]byte(body), &added)
	if added != "갤럭시" {
		t.Errorf("want '갤럭시', got %q", added)
	}

	code, body = do(t, "GET", srv.URL+"/me/keywords", "nnt_x", "")
	if code != 200 || body != `["갤럭시"]` {
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

	// 1) 입력 "삼다수, 500ML" → 응답 "500ml,삼다수"
	code, body := do(t, "POST", srv.URL+"/me/keywords", "nnt_x", `{"keyword":"삼다수, 500ML"}`)
	if code != 200 {
		t.Fatalf("add AND: want 200, got %d body=%q", code, body)
	}
	var added string
	json.Unmarshal([]byte(body), &added)
	if added != "500ml,삼다수" {
		t.Errorf("normalized: want %q, got %q", "500ml,삼다수", added)
	}

	// 2) 순서만 다른 입력 → 같은 키 (중복 row 생성 안 됨)
	code, _ = do(t, "POST", srv.URL+"/me/keywords", "nnt_x", `{"keyword":"500ml,삼다수"}`)
	if code != 200 {
		t.Fatalf("add reorder: want 200, got %d", code)
	}
	code, body = do(t, "GET", srv.URL+"/me/keywords", "nnt_x", "")
	if code != 200 || body != `["500ml,삼다수"]` {
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
