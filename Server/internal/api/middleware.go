package api

import (
	"context"
	"net/http"
	"strings"

	"github.com/Moonjm/nunting/server/internal/db"
)

const (
	bearerPrefix = "Bearer "
	uuidPrefix   = "nnt_"
)

// BearerAuth 는 `Authorization: Bearer nnt_<UUID>` 헤더를 검증한다.
// - 헤더 누락 / 'Bearer ' prefix 없으면 401.
// - 토큰이 'nnt_' prefix 가 아니면 401.
// - 통과 시 users 테이블에 upsert (created_at 은 첫 INSERT 시각 고정) +
//   context 에 uuid 주입 → 다음 핸들러가 UUIDFrom(ctx) 로 사용.
func BearerAuth(store *db.Store) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			header := r.Header.Get("Authorization")
			if !strings.HasPrefix(header, bearerPrefix) {
				http.Error(w, "missing or invalid Authorization header", http.StatusUnauthorized)
				return
			}
			token := strings.TrimPrefix(header, bearerPrefix)
			if !strings.HasPrefix(token, uuidPrefix) {
				http.Error(w, "invalid token prefix", http.StatusUnauthorized)
				return
			}

			if err := store.UpsertUser(r.Context(), token); err != nil {
				http.Error(w, "internal error", http.StatusInternalServerError)
				return
			}

			ctx := context.WithValue(r.Context(), uuidContextKey, token)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}
