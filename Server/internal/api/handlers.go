package api

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strings"

	"github.com/Moonjm/nunting/server/internal/db"
	"github.com/go-chi/chi/v5"
)

type handlers struct {
	store      *db.Store
	testPusher TestPusher // nil 이면 /test-push 미등록
}

func (h *handlers) health(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write([]byte("ok"))
}

func (h *handlers) echo(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write([]byte(UUIDFrom(r.Context())))
}

// PUT /me/push-token { "token": "<hex>" } | { "token": null }
func (h *handlers) putPushToken(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Token *string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	uuid := UUIDFrom(r.Context())
	token := ""
	if body.Token != nil {
		token = *body.Token
	}
	if err := h.store.SetPushToken(r.Context(), uuid, token); err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (h *handlers) listKeywords(w http.ResponseWriter, r *http.Request) {
	keys, err := h.store.ListKeywords(r.Context(), UUIDFrom(r.Context()))
	if err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}
	// nil → []string{} 보장 ("null" 대신 "[]" 응답).
	if keys == nil {
		keys = []string{}
	}
	// json.Marshal 사용 — json.Encoder.Encode 가 trailing newline 을 붙여
	// strict-equal 테스트와 일부 클라이언트 디코더가 까다로워질 수 있음.
	b, _ := json.Marshal(keys)
	w.Header().Set("Content-Type", "application/json")
	w.Write(b)
}

// POST /me/keywords { "keyword": "<raw>" } → 200 "<normalized>" (JSON string)
func (h *handlers) addKeyword(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Keyword string `json:"keyword"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	normalized := strings.TrimSpace(body.Keyword)
	if normalized == "" {
		http.Error(w, "keyword empty", http.StatusBadRequest)
		return
	}
	if err := h.store.AddKeyword(r.Context(), UUIDFrom(r.Context()), normalized); err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}
	// JSON string ("\"갤럭시\"") — Marshal 이 안전한 quoting/escaping 보장.
	b, _ := json.Marshal(normalized)
	w.Header().Set("Content-Type", "application/json")
	w.Write(b)
}

func (h *handlers) removeKeyword(w http.ResponseWriter, r *http.Request) {
	encoded := chi.URLParam(r, "keyword")
	keyword, err := url.PathUnescape(encoded)
	if err != nil {
		http.Error(w, "invalid keyword path", http.StatusBadRequest)
		return
	}
	if err := h.store.RemoveKeyword(r.Context(), UUIDFrom(r.Context()), keyword); err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// GET /test-push — 디버그 전용 임시 라우트. push_token 있는 첫 user 한 명에게
// 합성 페이로드로 푸시 한 발. real APNs 응답(403/410 등) 그대로 surface.
// PR 머지 전 함께 revert 예정.
func (h *handlers) testPush(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if h.testPusher == nil {
		http.Error(w, `{"error":"test pusher unavailable"}`, http.StatusServiceUnavailable)
		return
	}
	if h.testPusher.IsStub() {
		// APNS_* env 누락 → real mode 아님. push 안 옴.
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"result":"stub_mode — APNS_* env 누락. real mode 로 띄워야 push 가 실제로 감"}`))
		return
	}

	uuid, token, err := h.store.AnyUserWithToken(r.Context())
	if err != nil {
		b, _ := json.Marshal(map[string]string{"error": "db: " + err.Error()})
		w.WriteHeader(http.StatusInternalServerError)
		w.Write(b)
		return
	}
	if token == "" {
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte(`{"error":"no user with push_token — register on iPhone first (앱에서 키워드 한 번 추가하면 토큰 등록)"}`))
		return
	}

	if err := h.testPusher.SendTest(r.Context(), token); err != nil {
		// APNs 403/410 등 — 그대로 보여줌
		resp := map[string]string{
			"result":       "fail",
			"target_uuid":  uuid,
			"token_prefix": token[:min(8, len(token))] + "...",
			"error":        err.Error(),
		}
		b, _ := json.Marshal(resp)
		w.WriteHeader(http.StatusInternalServerError)
		w.Write(b)
		return
	}

	resp := map[string]string{
		"result":       "sent",
		"target_uuid":  uuid,
		"token_prefix": token[:min(8, len(token))] + "...",
	}
	b, _ := json.Marshal(resp)
	w.Write(b)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
