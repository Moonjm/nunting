package api

import (
	"net/http"

	"github.com/Moonjm/nunting/server/internal/db"
	"github.com/go-chi/chi/v5"
)

// NewRouter 라이브 서버용 chi 라우터. 핸들러는 store 만 의존(APNs/poll 분리).
// `/health` 는 unauth, `/me/*` 는 BearerAuth 그룹.
func NewRouter(store *db.Store) http.Handler {
	r := chi.NewRouter()

	h := &handlers{store: store}

	r.Get("/health", h.health)

	r.Route("/me", func(r chi.Router) {
		r.Use(BearerAuth(store))
		r.Get("/_echo", h.echo)
		r.Put("/push-token", h.putPushToken)
		r.Get("/keywords", h.listKeywords)
		r.Post("/keywords", h.addKeyword)
		r.Delete("/keywords/{keyword}", h.removeKeyword)
	})

	return r
}
