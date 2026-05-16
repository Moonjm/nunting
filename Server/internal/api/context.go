package api

import "context"

// contextKey 패키지 외부에서 context 키를 부딪치지 않도록 unexported type.
type contextKey string

const uuidContextKey contextKey = "uuid"

// UUIDFrom 핸들러가 context 에서 uuid 를 꺼낼 때 사용.
// Bearer 미들웨어가 통과시킨 요청만 빈 문자열이 아닌 값을 가짐.
func UUIDFrom(ctx context.Context) string {
	if v, ok := ctx.Value(uuidContextKey).(string); ok {
		return v
	}
	return ""
}
