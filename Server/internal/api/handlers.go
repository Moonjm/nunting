package api

import (
	"encoding/json"
	"net/http"
	"net/url"
	"sort"
	"strconv"
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

// 정규화 *전* raw 입력 캡. normalizeKeyword 가 strings.Split 으로 콤마 단위
// 분리하므로, 콤마 폭탄(예: 10MB ",,,,...") 이 들어오면 메모리 폭발.
// 최종 normalized 는 50자 캡이지만 그 전에 막아야 의미가 있다.
const maxRawKeywordLength = 500

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
	// nil → [] 보장 ("null" 대신 "[]" 응답).
	if keys == nil {
		keys = []db.KeywordSub{}
	}
	// json.Marshal 사용 — json.Encoder.Encode 가 trailing newline 을 붙여
	// strict-equal 테스트와 일부 클라이언트 디코더가 까다로워질 수 있음.
	b, _ := json.Marshal(keys)
	w.Header().Set("Content-Type", "application/json")
	w.Write(b)
}

// POST /me/keywords { "keyword": "<raw>", "exclude": "<raw>" }
//   → 200 {"keyword":"<norm>","exclude":"<norm>"} (upsert)
//
// keyword 가 행 식별자(PK)이고 exclude 는 갱신 대상이라, 같은 keyword 로 다시
// POST 하면 제외만 덮어쓴다(클라의 행 편집 통로). exclude 누락/빈값은 "제외
// 없음". 포함(AND)과 제외(OR) 둘 다 normalizeKeyword 로 정규화한다.
func (h *handlers) addKeyword(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Keyword string `json:"keyword"`
		Exclude string `json:"exclude"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	// raw 입력 길이 캡 — normalizeKeyword 의 strings.Split DoS 방어(양쪽 다).
	if len(body.Keyword) > maxRawKeywordLength || len(body.Exclude) > maxRawKeywordLength {
		http.Error(w, "keyword too long", http.StatusBadRequest)
		return
	}
	// normalizeKeyword: split → trim+lower → dedup → sort → join. 상세는 함수 doc 참조.
	keyword := normalizeKeyword(body.Keyword)
	if keyword == "" {
		http.Error(w, "keyword empty", http.StatusBadRequest)
		return
	}
	// 제외는 비어도 됨(제외 없음). 정규화 후 빈 문자열이면 그대로 "".
	exclude := normalizeKeyword(body.Exclude)
	if len(keyword) > maxKeywordLength || len(exclude) > maxKeywordLength {
		http.Error(w, "keyword too long", http.StatusBadRequest)
		return
	}
	if err := h.store.UpsertKeyword(r.Context(), UUIDFrom(r.Context()), keyword, exclude); err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}
	b, _ := json.Marshal(db.KeywordSub{Keyword: keyword, Exclude: exclude})
	w.Header().Set("Content-Type", "application/json")
	w.Write(b)
}

// alertHistoryDefaultLimit / alertHistoryMaxLimit GET /me/alert-history 의
// limit 쿼리 기본값과 상한. DB 보관 개수는 무제한이지만 한 응답의 payload 가
// 비대해지지 않게 API 페이지 상한만 둔다(1인 도구라 넉넉히).
const (
	alertHistoryDefaultLimit = 200
	alertHistoryMaxLimit     = 1000
)

// GET /me/alert-history?limit=100 → 최신순 AlertHistoryItem 배열(JSON).
func (h *handlers) listAlertHistory(w http.ResponseWriter, r *http.Request) {
	limit := alertHistoryDefaultLimit
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 {
			limit = n
		}
	}
	if limit > alertHistoryMaxLimit {
		limit = alertHistoryMaxLimit
	}
	items, err := h.store.ListAlertHistory(r.Context(), UUIDFrom(r.Context()), limit)
	if err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}
	// nil → [] 보장 ("null" 대신 "[]").
	if items == nil {
		items = []db.AlertHistoryItem{}
	}
	b, _ := json.Marshal(items)
	w.Header().Set("Content-Type", "application/json")
	w.Write(b)
}

// POST /me/alert-history/{id}/read → 해당 알림을 읽음 처리. 클라가 알림 행을
// 탭해 글을 열 때 호출. 멱등(이미 읽음이면 no-op).
func (h *handlers) markAlertRead(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil {
		http.Error(w, "invalid id", http.StatusBadRequest)
		return
	}
	if err := h.store.MarkAlertRead(r.Context(), UUIDFrom(r.Context()), id); err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (h *handlers) removeKeyword(w http.ResponseWriter, r *http.Request) {
	encoded := chi.URLParam(r, "keyword")
	decoded, err := url.PathUnescape(encoded)
	if err != nil {
		http.Error(w, "invalid keyword path", http.StatusBadRequest)
		return
	}
	// add 와 동일 normalize — "iPhone" 으로 등록된 row 를 "iphone" 으로
	// 삭제 요청 시에도, 콤마 다른 순서로 등록된 AND 키워드도 같은 키로 변환.
	if len(decoded) > maxRawKeywordLength {
		http.Error(w, "keyword too long", http.StatusBadRequest)
		return
	}
	keyword := normalizeKeyword(decoded)
	if err := h.store.RemoveKeyword(r.Context(), UUIDFrom(r.Context()), keyword); err != nil {
		http.Error(w, "db error", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// normalizeKeyword: raw 입력을 정규화된 CSV 키워드로 변환.
//
//	"삼다수, 500ML" → "500ml,삼다수"
//
// 규칙: split by "," → 토큰별 trim + ToLower → 빈 토큰 drop → dedup
// → 알파벳 정렬 → join with "," (no space).
//
// "500ml, 삼다수" 와 "삼다수, 500ml" 가 같은 키로 저장되게 정렬한다.
// 빈 결과(empty/whitespace/콤마만)는 ""를 반환 — caller 가 400 처리.
func normalizeKeyword(raw string) string {
	parts := strings.Split(raw, ",")
	seen := map[string]bool{}
	tokens := make([]string, 0, len(parts))
	for _, p := range parts {
		t := strings.ToLower(strings.TrimSpace(p))
		if t == "" || seen[t] {
			continue
		}
		seen[t] = true
		tokens = append(tokens, t)
	}
	sort.Strings(tokens)
	return strings.Join(tokens, ",")
}
