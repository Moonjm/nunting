package api

import (
	"context"
	"net/http"

	"github.com/Moonjm/nunting/server/internal/db"
	"github.com/go-chi/chi/v5"
)

// TestPusher /test-push 디버그 라우트에서 호출. main.go 가 *apns.Client 를 주입.
// 임시 — PR 머지 전 제거 예정.
type TestPusher interface {
	SendTest(ctx context.Context, deviceToken string) error
	IsStub() bool
}

// NewRouter 라이브 서버용 chi 라우터. 핸들러는 store 만 의존(APNs/poll 분리).
// `/health` 는 unauth, `/me/*` 는 BearerAuth 그룹.
//
// testPusher 가 nil 이 아니면 /test-push (unauth) 디버그 라우트 등록 — push 제대로
// 도착하는지 즉시 검증용. nil 이면 등록 안 함.
func NewRouter(store *db.Store, testPusher TestPusher) http.Handler {
	r := chi.NewRouter()

	h := &handlers{store: store, testPusher: testPusher}

	r.Get("/health", h.health)
	if testPusher != nil {
		r.Get("/test-push", h.testPush)
	}

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
