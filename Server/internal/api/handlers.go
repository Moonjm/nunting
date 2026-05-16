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
	store *db.Store
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
