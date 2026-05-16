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
