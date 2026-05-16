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

// APNs device token 은 64 hex chars (~200 bytes). 여유 두되 abuse 시 row
// 비대 막는 sanity bound. Swift 버전 PushTokenRoutes.maxTokenLength 와 동일.
const maxPushTokenLength = 256

// 키워드 길이 sanity bound. Swift KeywordRoutes.maxKeywordLength 와 동일.
const maxKeywordLength = 50

// PUT /me/push-token { "token": "<hex>" } | { "token": null }
func (h *handlers) putPushToken(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Token *string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	if body.Token != nil && len(*body.Token) > maxPushTokenLength {
		http.Error(w, "token too long", http.StatusBadRequest)
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
	// trim + lowercase 정규화 — Swift Store.normalizedKeyword 동일.
	// 한글은 ToLower 가 no-op 이지만 영문/숫자 키워드(iPhone vs iphone) 가
	// 같은 항목으로 저장/조회/삭제되게 보장 (SQLite PK 가 case-sensitive).
	normalized := strings.ToLower(strings.TrimSpace(body.Keyword))
	if normalized == "" {
		http.Error(w, "keyword empty", http.StatusBadRequest)
		return
	}
	if len(normalized) > maxKeywordLength {
		http.Error(w, "keyword too long", http.StatusBadRequest)
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
	decoded, err := url.PathUnescape(encoded)
	if err != nil {
		http.Error(w, "invalid keyword path", http.StatusBadRequest)
		return
	}
	// add 와 동일하게 정규화 — 그렇지 않으면 "iPhone" 으로 등록된 row 를
	// "iphone" 으로 삭제 요청 시 못 찾음 (혹은 그 반대).
	keyword := strings.ToLower(strings.TrimSpace(decoded))
	if err := h.store.RemoveKeyword(r.Context(), UUIDFrom(r.Context()), keyword); err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}
