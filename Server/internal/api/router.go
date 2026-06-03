package api

import (
	"net/http"

	"github.com/Moonjm/nunting/server/internal/db"
	"github.com/go-chi/chi/v5"
)

// maxBodyBytes JSON body 상한 — push token(<256B) / keyword(<50B) 모두 여기 안에.
// 다중 GB POST 로 Pi RAM 고갈 방지.
const maxBodyBytes = 4096

// limitBody 모든 핸들러 진입 전 r.Body 를 MaxBytesReader 로 감싼다.
// 초과 시 핸들러의 json.Decode 가 자연스럽게 EOF/limit 에러로 400 반환.
func limitBody(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
		next.ServeHTTP(w, r)
	})
}

// NewRouter 라이브 서버용 chi 라우터. 핸들러는 store 만 의존(APNs/poll 분리).
// `/health` 는 unauth, `/me/*` 는 BearerAuth 그룹.
func NewRouter(store *db.Store) http.Handler {
	r := chi.NewRouter()
	r.Use(limitBody)

	h := &handlers{store: store}

	r.Get("/health", h.health)

	r.Route("/me", func(r chi.Router) {
		r.Use(BearerAuth(store))
		r.Get("/_echo", h.echo)
		r.Put("/push-token", h.putPushToken)
		r.Get("/keywords", h.listKeywords)
		r.Post("/keywords", h.addKeyword)
		r.Delete("/keywords/{keyword}", h.removeKeyword)
		r.Get("/alert-history", h.listAlertHistory)
		r.Post("/alert-history/{id}/read", h.markAlertRead)
	})

	return r
}
