// Package dbtest 는 격리된 Postgres schema 위에 *db.Store 를 여는 테스트 헬퍼.
// db 패키지를 import 하므로 db 자신의 테스트(package db)에서는 못 쓰고(순환 import),
// 그 외 패키지(api, poll)의 테스트에서 SQLite :memory: 격리를 대체하는 용도다.
//
// 각 New 호출은 유일한 schema 를 만들어 그 안에서만 테이블을 쓰므로 테스트끼리,
// 그리고 실제 데이터(public schema)와도 섞이지 않는다. cleanup 은 별도 admin
// connection 으로 schema 를 DROP 한다(테스트가 store 를 먼저 닫아도 누수 없음).
package dbtest

import (
	"database/sql"
	"fmt"
	"os"
	"sync/atomic"
	"testing"

	"github.com/Moonjm/nunting/server/internal/db"
	_ "github.com/jackc/pgx/v5/stdlib"
)

var counter int64

// baseDSN 테스트가 붙을 로컬 Postgres. NUNTING_TEST_DATABASE_URL 로 덮어쓸 수 있고,
// 기본은 로컬 nnt/nnt00.
func baseDSN() string {
	if v := os.Getenv("NUNTING_TEST_DATABASE_URL"); v != "" {
		return v
	}
	return "postgres://nnt:nnt00@localhost:5432/nnt?sslmode=disable"
}

// New 격리 schema 위에 Store 를 연다. PG 미연결이면 t.Skip.
func New(t *testing.T) *db.Store {
	t.Helper()
	base := baseDSN()
	schema := fmt.Sprintf("t_%d_%d", os.Getpid(), atomic.AddInt64(&counter, 1))
	store, err := db.OpenSchema(base, schema)
	if err != nil {
		t.Skipf("postgres 미연결(%v) — NUNTING_TEST_DATABASE_URL 설정 또는 로컬 PG 필요", err)
	}
	t.Cleanup(func() {
		_ = store.Close()
		if admin, err := sql.Open("pgx", base); err == nil {
			_, _ = admin.Exec(`DROP SCHEMA IF EXISTS "` + schema + `" CASCADE`)
			_ = admin.Close()
		}
	})
	return store
}
