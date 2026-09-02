package oitalk

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// fakeJWT exp 클레임만 있는 unsigned JWT.
func fakeJWT(exp time.Time) string {
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	body := base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf(`{"exp":%d}`, exp.Unix())))
	return hdr + "." + body + ".sig"
}

type fakeAPI struct {
	t            *testing.T
	refreshCalls atomic.Int32
	token        string
	registerCode int32 // 첫 register 응답 코드(401 시뮬레이션용), 이후 200
	lastRefresh  map[string]any
	lastRegister map[string]any
	lastRegToken string
	lastListURL  string
}

func newFakeAPI(t *testing.T) (*fakeAPI, *Client) {
	f := &fakeAPI{t: t, token: fakeJWT(time.Now().Add(24 * time.Hour)), registerCode: 200}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /auth/refresh", func(w http.ResponseWriter, r *http.Request) {
		f.refreshCalls.Add(1)
		if err := json.NewDecoder(r.Body).Decode(&f.lastRefresh); err != nil {
			t.Errorf("refresh body: %v", err)
		}
		fmt.Fprintf(w, `{"data":{"token":%q,"client_secret":"sec","fb_access_token":"x"}}`, f.token)
	})
	mux.HandleFunc("POST /groups/grp/visit_cars", func(w http.ResponseWriter, r *http.Request) {
		f.lastRegToken = r.Header.Get("x-access-token")
		if err := json.NewDecoder(r.Body).Decode(&f.lastRegister); err != nil {
			t.Errorf("register body: %v", err)
		}
		if code := atomic.SwapInt32(&f.registerCode, 200); code != 200 {
			w.WriteHeader(int(code))
			fmt.Fprint(w, `{"error":"unauthorized"}`)
			return
		}
		fmt.Fprint(w, `{"data":{"row":{"_id":"abc123","car_num":"12가3456","start_date":"20260902","end_date":"20260904","state":"ok"}}}`)
	})
	mux.HandleFunc("GET /groups/grp/visit_cars", func(w http.ResponseWriter, r *http.Request) {
		f.lastListURL = r.URL.String()
		if r.Header.Get("x-access-token") == "" {
			w.WriteHeader(401)
			return
		}
		fmt.Fprint(w, `{"data":{"rows":[
			{"_id":1,"car_num":"12가3456","start_date":"20260902","end_date":"20260904","state":"ok"},
			{"_id":"2","car_num":"99하9999","start_date":"20260901","end_date":"20260901","state":"ok"}]}}`)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	cfg := Config{
		BaseURL: srv.URL, ClientSecret: "sec", AccountID: "acc", GroupID: "grp",
		DeviceID: "dev", MobiKey: "mobi", CarNum: "12가3456", RecvPhone: "+821012345678",
		VisitReason: "세대 방문", CoverageDays: 3,
	}
	return f, NewClient(cfg)
}

func TestClient_EnsureToken_RefreshesOnceThenCaches(t *testing.T) {
	f, c := newFakeAPI(t)
	ctx := context.Background()
	tok, err := c.EnsureToken(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if tok != f.token {
		t.Errorf("token = %q", tok)
	}
	if _, err := c.EnsureToken(ctx); err != nil {
		t.Fatal(err)
	}
	if n := f.refreshCalls.Load(); n != 1 {
		t.Errorf("refresh calls = %d, want 1", n)
	}
	// 요청 본문 규격
	if f.lastRefresh["account_id"] != "acc" || f.lastRefresh["client_secret"] != "sec" {
		t.Errorf("refresh body = %v", f.lastRefresh)
	}
	dev, _ := f.lastRefresh["device"].(map[string]any)
	if dev["id"] != "dev" || dev["mobi_key"] != "mobi" || dev["app_name"] != "net.gntalk.oitalk" || dev["os_type"] != "ios" {
		t.Errorf("device = %v", dev)
	}
}

func TestClient_EnsureToken_RefreshesWhenNearExpiry(t *testing.T) {
	f, c := newFakeAPI(t)
	f.token = fakeJWT(time.Now().Add(2 * time.Minute)) // 5분 여유 안쪽
	ctx := context.Background()
	if _, err := c.EnsureToken(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := c.EnsureToken(ctx); err != nil {
		t.Fatal(err)
	}
	if n := f.refreshCalls.Load(); n != 2 {
		t.Errorf("refresh calls = %d, want 2 (near-expiry token must be refreshed again)", n)
	}
}

func TestClient_Register_SendsSpecAndParsesRow(t *testing.T) {
	f, c := newFakeAPI(t)
	day := time.Date(2026, 9, 2, 0, 0, 0, 0, KST)
	start, end, _ := CoverageWindow(day, 3)
	row, err := c.Register(context.Background(), start, end)
	if err != nil {
		t.Fatal(err)
	}
	if f.lastRegToken != f.token {
		t.Errorf("x-access-token = %q", f.lastRegToken)
	}
	want := map[string]any{
		"start_dt": "2026-09-01T15:00:00.000Z", "end_dt": "2026-09-04T14:59:59.999Z",
		"car_num": "12가3456", "recv_phone_e164": "+821012345678", "visit_reason": "세대 방문",
	}
	for k, v := range want {
		if f.lastRegister[k] != v {
			t.Errorf("body[%s] = %v, want %v", k, f.lastRegister[k], v)
		}
	}
	if row.ID != "abc123" || row.State != "ok" || row.StartDate != "20260902" || row.EndDate != "20260904" {
		t.Errorf("row = %+v", row)
	}
}

func TestClient_Register_401RefreshesAndRetriesOnce(t *testing.T) {
	f, c := newFakeAPI(t)
	if _, err := c.EnsureToken(context.Background()); err != nil {
		t.Fatal(err)
	}
	f.registerCode = 401
	start, end, _ := CoverageWindow(time.Date(2026, 9, 2, 0, 0, 0, 0, KST), 3)
	if _, err := c.Register(context.Background(), start, end); err != nil {
		t.Fatalf("expected retry success, got %v", err)
	}
	if n := f.refreshCalls.Load(); n != 2 {
		t.Errorf("refresh calls = %d, want 2", n)
	}
}

func TestClient_Register_NonOKIsError(t *testing.T) {
	f, c := newFakeAPI(t)
	f.registerCode = 500
	start, end, _ := CoverageWindow(time.Date(2026, 9, 2, 0, 0, 0, 0, KST), 3)
	if _, err := c.Register(context.Background(), start, end); err == nil {
		t.Fatal("expected error on 500")
	}
}

func TestClient_List_QueryAndRows(t *testing.T) {
	f, c := newFakeAPI(t)
	start, end, _ := CoverageWindow(time.Date(2026, 9, 2, 0, 0, 0, 0, KST), 3)
	rows, err := c.List(context.Background(), start, end)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("rows = %d", len(rows))
	}
	if rows[0].ID != "1" || rows[1].ID != "2" {
		t.Errorf("_id number/string both → string: %q %q", rows[0].ID, rows[1].ID)
	}
	if rows[0].CarNum != "12가3456" || rows[0].StartDate != "20260902" || rows[0].EndDate != "20260904" {
		t.Errorf("row0 = %+v", rows[0])
	}
	for _, q := range []string{"ver=1", "offset=0", "limit=20", "start_dt=2026-09-01T15%3A00%3A00.000Z", "end_dt=2026-09-04T14%3A59%3A59.999Z"} {
		if !strings.Contains(f.lastListURL, q) {
			t.Errorf("list URL %q missing %q", f.lastListURL, q)
		}
	}
}
