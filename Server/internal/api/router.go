package api

import (
	"net/http"
	"os"

	"github.com/Moonjm/nunting/server/internal/db"
	"github.com/go-chi/chi/v5"
)

// maxBodyBytes 작은 JSON body 상한 — push token(<256B) / keyword(<50B) 모두 여기 안에.
// 다중 GB POST 로 Pi RAM 고갈 방지.
const maxBodyBytes = 4096

// maxMetricBodyBytes MetricKit payload 전용 상한. 크래시 콜스택을 포함한
// MXDiagnosticPayload.jsonRepresentation 은 수십~수백 KB 라 일반 라우트의 4KB
// 로는 못 받는다. 1 MB 면 다중 진단 payload 도 여유.
const maxMetricBodyBytes = 1 << 20

// maxBody r.Body 를 n 바이트 MaxBytesReader 로 감싸는 미들웨어 팩토리.
// 초과 시 핸들러의 본문 read 가 limit 에러로 400/413 을 유발.
func maxBody(n int64) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			r.Body = http.MaxBytesReader(w, r.Body, n)
			next.ServeHTTP(w, r)
		})
	}
}

// NewRouter 라이브 서버용 chi 라우터. 핸들러는 store 만 의존(APNs/poll 분리).
// `/health`·`/admin/*` 은 unauth(admin 은 ?key= 로 자체 검증), `/me/*` 는 BearerAuth 그룹.
// body 상한은 라우트별로: 일반 4KB, `/me/metrics` 만 1MB.
func NewRouter(store *db.Store) http.Handler {
	r := chi.NewRouter()

	h := &handlers{store: store, adminKey: os.Getenv("NUNTING_ADMIN_KEY")}

	r.Get("/health", h.health)
	// MetricKit 요약 뷰 — 브라우저로 직접 열어 봄. ?key= 로 약한 비밀 검증(1인 도구).
	r.Get("/admin/metrics", h.adminMetrics)

	r.Route("/me", func(r chi.Router) {
		r.Use(BearerAuth(store))
		// 작은 본문 라우트 — 기존 4KB 상한 유지.
		r.Group(func(r chi.Router) {
			r.Use(maxBody(maxBodyBytes))
			r.Get("/_echo", h.echo)
			r.Put("/push-token", h.putPushToken)
			r.Get("/keywords", h.listKeywords)
			r.Post("/keywords", h.addKeyword)
			r.Post("/keywords/{keyword}/enabled", h.setKeywordEnabled)
			r.Delete("/keywords/{keyword}", h.removeKeyword)
			r.Get("/alert-history", h.listAlertHistory)
			r.Post("/alert-history/{id}/read", h.markAlertRead)
		})
		// MetricKit payload — 크래시 콜스택 포함이라 큰 상한.
		r.With(maxBody(maxMetricBodyBytes)).Post("/metrics", h.postMetrics)
	})

	return r
}
