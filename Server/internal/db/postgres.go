// Package db 는 PostgreSQL 단일 진입점이다. 모든 query 가 여기를 통과.
// 드라이버는 jackc/pgx/v5/stdlib (database/sql 호환, pure Go — Pi cross-compile 유지).
package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

const schemaSQL = `
CREATE TABLE IF NOT EXISTS users (
    uuid       TEXT PRIMARY KEY,
    push_token TEXT,
    created_at BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS keyword_subs (
    uuid    TEXT NOT NULL,
    keyword TEXT NOT NULL,
    exclude TEXT NOT NULL DEFAULT '',
    enabled INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (uuid, keyword),
    FOREIGN KEY (uuid) REFERENCES users(uuid) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_users_with_token
    ON users(uuid) WHERE push_token IS NOT NULL;
CREATE TABLE IF NOT EXISTS alert_history (
    id      BIGSERIAL PRIMARY KEY,
    uuid    TEXT NOT NULL,
    keyword TEXT NOT NULL,
    post_no TEXT NOT NULL,
    title   TEXT NOT NULL,
    url     TEXT NOT NULL,
    sent_at BIGINT NOT NULL,
    read_at BIGINT,
    FOREIGN KEY (uuid) REFERENCES users(uuid) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_alert_history_uuid_id
    ON alert_history(uuid, id DESC);
CREATE TABLE IF NOT EXISTS metric_payloads (
    id          BIGSERIAL PRIMARY KEY,
    uuid        TEXT NOT NULL,
    kind        TEXT NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    payload     TEXT NOT NULL,
    FOREIGN KEY (uuid) REFERENCES users(uuid) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_metric_payloads_id
    ON metric_payloads(id DESC);
CREATE TABLE IF NOT EXISTS footprint_samples (
    id          BIGSERIAL PRIMARY KEY,
    uuid        TEXT NOT NULL,
    client_ts   TIMESTAMPTZ NOT NULL,
    label       TEXT NOT NULL,
    mb          INTEGER NOT NULL,
    avail_mb    INTEGER NOT NULL,
    live_mb     INTEGER NOT NULL DEFAULT 0,
    alloc_mb    INTEGER NOT NULL DEFAULT 0,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (uuid) REFERENCES users(uuid) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_footprint_id
    ON footprint_samples(id DESC);
`

// Store 는 *sql.DB 래퍼. 모든 query method 가 context-aware.
type Store struct {
	db *sql.DB
}

// Open 은 dsn(예: postgres://user:pass@host:5432/db?sslmode=disable)으로 연결하고
// 스키마(CREATE TABLE IF NOT EXISTS)를 보장한다. 프로덕션 진입점.
func Open(dsn string) (*Store, error) {
	return openWithSchema(dsn, "")
}

// OpenSchema 는 테스트 격리용 — 지정한 Postgres schema 를 만들고 search_path 를
// 그쪽으로 고정해 테이블을 그 안에 생성한다. 한 DB 안에서 테스트별로 namespace 를
// 분리해 :memory: 시절의 격리를 대체한다. DropSchema 로 정리한다.
func OpenSchema(dsn, schema string) (*Store, error) {
	return openWithSchema(dsn, schema)
}

func openWithSchema(dsn, schema string) (*Store, error) {
	if schema != "" {
		dsn = withSearchPath(dsn, schema)
	}
	sqldb, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("sql.Open: %w", err)
	}
	// Pi 자원 한도 내 적당한 풀. SQLite 와 달리 동시 reader/writer 가능.
	sqldb.SetMaxOpenConns(10)
	sqldb.SetMaxIdleConns(2)
	sqldb.SetConnMaxIdleTime(5 * time.Minute)

	if schema != "" {
		if _, err := sqldb.Exec(`CREATE SCHEMA IF NOT EXISTS ` + quoteIdent(schema)); err != nil {
			sqldb.Close()
			return nil, fmt.Errorf("create schema: %w", err)
		}
	}
	if _, err := sqldb.Exec(schemaSQL); err != nil {
		sqldb.Close()
		return nil, fmt.Errorf("schema: %w", err)
	}
	return &Store{db: sqldb}, nil
}

// DropSchema 테스트 격리 schema 를 통째로 제거(CASCADE). 테스트 cleanup 용.
func (s *Store) DropSchema(ctx context.Context, schema string) error {
	_, err := s.db.ExecContext(ctx, `DROP SCHEMA IF EXISTS `+quoteIdent(schema)+` CASCADE`)
	return err
}

func (s *Store) Close() error {
	return s.db.Close()
}

// withSearchPath dsn 에 search_path 런타임 옵션을 얹는다(libpq options). pgx 가
// 모든 풀 connection 에 적용하므로 unqualified 테이블 참조가 해당 schema 로 간다.
func withSearchPath(dsn, schema string) string {
	u, err := url.Parse(dsn)
	if err != nil {
		return dsn
	}
	q := u.Query()
	q.Set("options", "-c search_path="+schema)
	u.RawQuery = q.Encode()
	return u.String()
}

// quoteIdent SQL 식별자(schema 명)를 안전하게 따옴표 처리.
func quoteIdent(s string) string {
	return `"` + strings.ReplaceAll(s, `"`, `""`) + `"`
}

// UpsertUser 는 INSERT-or-nothing. created_at 은 첫 INSERT 시각으로 고정.
// Bearer 미들웨어가 매 요청마다 호출해도 created_at 안 변함.
func (s *Store) UpsertUser(ctx context.Context, uuid string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO users (uuid, push_token, created_at) VALUES ($1, NULL, $2)
		 ON CONFLICT (uuid) DO NOTHING`,
		uuid, time.Now().Unix())
	return err
}

// SetPushToken token == "" 이면 NULL (clear).
func (s *Store) SetPushToken(ctx context.Context, uuid, token string) error {
	if token == "" {
		_, err := s.db.ExecContext(ctx, `UPDATE users SET push_token = NULL WHERE uuid = $1`, uuid)
		return err
	}
	_, err := s.db.ExecContext(ctx, `UPDATE users SET push_token = $1 WHERE uuid = $2`, token, uuid)
	return err
}

// GetPushToken nil pointer 면 토큰 없음(또는 NULL). 토큰 있으면 *string.
func (s *Store) GetPushToken(ctx context.Context, uuid string) (*string, error) {
	var token sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT push_token FROM users WHERE uuid = $1`, uuid).Scan(&token)
	if errors.Is(err, sql.ErrNoRows) {
		// user 가 존재하지 않으면 "토큰 없음" 으로 동등 처리 — caller 가
		// 별도 분기할 필요 없게. 진짜 DB 에러는 그대로 전파.
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !token.Valid {
		return nil, nil
	}
	return &token.String, nil
}

// Match 는 폴러가 한 번에 처리할 (uuid, push_token, matched_keyword) tuple.
// Enabled 는 매칭된 키워드의 토글 상태 — false 면 폴러가 이력만 남기고 push 는 건너뛴다.
type Match struct {
	UUID      string
	PushToken string
	Keyword   string
	Enabled   bool
}

// KeywordSub 한 구독 행: 포함 키워드(CSV AND 토큰)와 제외 단어(CSV OR 토큰).
// 둘 다 정규화된 CSV(소문자/trim/dedup/정렬). exclude == "" 면 제외 없음.
// Enabled 는 알림 토글 — false 면 매칭돼도 push 안 가고 이력만 쌓인다.
// JSON 태그는 iOS KeywordSub 디코더와 합의된 형태.
type KeywordSub struct {
	Keyword string `json:"keyword"`
	Exclude string `json:"exclude"`
	Enabled bool   `json:"enabled"`
}

func (s *Store) ListKeywords(ctx context.Context, uuid string) ([]KeywordSub, error) {
	rows, err := s.db.QueryContext(ctx,
		// COLLATE "C": libc 로케일 정렬은 플랫폼마다 달라(특히 macOS 는 한글이
		// 가나다순이 아님) 코드포인트 순으로 고정 — 완성형 한글은 곧 가나다순.
		`SELECT keyword, exclude, enabled FROM keyword_subs WHERE uuid = $1 ORDER BY keyword COLLATE "C"`, uuid)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []KeywordSub{}
	for rows.Next() {
		var k KeywordSub
		var enabled int
		if err := rows.Scan(&k.Keyword, &k.Exclude, &enabled); err != nil {
			return nil, err
		}
		k.Enabled = enabled != 0
		out = append(out, k)
	}
	return out, rows.Err()
}

// AddKeyword 제외 없는 포함 키워드만 추가(중복은 PK 충돌 무시). exclude 컬럼은
// DEFAULT ” 로 채워진다. 제외까지 다루는 경로는 UpsertKeyword 를 쓴다.
func (s *Store) AddKeyword(ctx context.Context, uuid, keyword string) error {
	// 빈 키워드는 silent reject — 모든 글에 매칭되어 push 폭격이 됨. API 계층도
	// trim 후 거부하지만 DB 계층에서도 방어선 추가.
	if keyword == "" {
		return nil
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO keyword_subs (uuid, keyword) VALUES ($1, $2) ON CONFLICT DO NOTHING`, uuid, keyword)
	return err
}

// UpsertKeyword 포함 키워드 행을 추가하거나, 이미 있으면 그 행의 제외 단어를
// 갱신한다. keyword 가 행 식별자(PK)이므로 같은 keyword 로 다시 호출하면
// exclude 만 덮어쓴다 — 클라의 "행 편집(제외 수정)" 통로. enabled 는 손대지
// 않는다(신규 행은 DEFAULT 1, 기존 행은 토글 상태 보존). 반환된 enabled 로
// 클라가 응답만으로 토글 상태를 정확히 반영한다(편집이 토글을 뒤집지 않음).
func (s *Store) UpsertKeyword(ctx context.Context, uuid, keyword, exclude string) (bool, error) {
	if keyword == "" {
		return false, nil
	}
	var enabled int
	err := s.db.QueryRowContext(ctx, `
		INSERT INTO keyword_subs (uuid, keyword, exclude) VALUES ($1, $2, $3)
		ON CONFLICT (uuid, keyword) DO UPDATE SET exclude = excluded.exclude
		RETURNING enabled`,
		uuid, keyword, exclude).Scan(&enabled)
	if err != nil {
		return false, err
	}
	return enabled != 0, nil
}

func (s *Store) RemoveKeyword(ctx context.Context, uuid, keyword string) error {
	_, err := s.db.ExecContext(ctx,
		`DELETE FROM keyword_subs WHERE uuid = $1 AND keyword = $2`, uuid, keyword)
	return err
}

// SetKeywordEnabled 키워드 행의 알림 토글만 갱신(exclude 등은 그대로). 없는
// keyword 면 no-op — uuid 스코프라 남의 행은 못 건드린다. exclude 편집(Upsert)과
// 분리된 통로라, 토글이 제외 단어를 덮어쓰는 일이 없다.
func (s *Store) SetKeywordEnabled(ctx context.Context, uuid, keyword string, enabled bool) error {
	v := 0
	if enabled {
		v = 1
	}
	_, err := s.db.ExecContext(ctx,
		`UPDATE keyword_subs SET enabled = $1 WHERE uuid = $2 AND keyword = $3`, v, uuid, keyword)
	return err
}

// MatchedUsersForTitle 글 제목에 user 의 키워드(CSV AND 토큰)가 모두 substring
// 으로 포함되어 있고 그 user 에게 push_token 이 있으면 (uuid, token, keyword) 반환.
// AND 매칭: keyword 가 "500ml,삼다수" 이면 두 토큰이 **모두** title 에 있어야 매칭.
// case-insensitive: title 을 1회 ToLower. keyword 토큰은 이미 lowercase 저장.
//
// 한 user 가 같은 글에 두 개 이상 키워드로 매칭되어도 **한 번만 알림**:
// user 당 한 행만 반환. 단, 토글(enabled) 우선 — enabled 키워드가 하나라도
// 매칭되면 그 행을 반환(push 대상)하고, enabled 매칭이 전무하고 disabled 만
// 매칭되면 disabled 행을 반환한다(폴러가 이력만 남기고 push 는 건너뜀).
// 예: '삼성'(끔) + '갤럭시'(켬) 구독 → "삼성 갤럭시" 글은 갤럭시 행으로 push,
// 둘 다 껐다면 한 행만 이력으로 남고 push 는 없음.
func (s *Store) MatchedUsersForTitle(ctx context.Context, title string) ([]Match, error) {
	lowerTitle := strings.ToLower(title)
	rows, err := s.db.QueryContext(ctx, `
		SELECT u.uuid, u.push_token, k.keyword, k.exclude, k.enabled
		FROM keyword_subs k
		JOIN users u ON u.uuid = k.uuid
		WHERE u.push_token IS NOT NULL
		ORDER BY u.uuid, k.keyword`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Match
	idxByUser := map[string]int{} // user 당 현재까지의 대표 매칭 행 위치
	for rows.Next() {
		var m Match
		var exclude string
		var enabled int
		if err := rows.Scan(&m.UUID, &m.PushToken, &m.Keyword, &exclude, &enabled); err != nil {
			return nil, err
		}
		m.Enabled = enabled != 0
		// 이미 enabled 매칭을 확보했으면 더 볼 필요 없음(최선).
		if idx, ok := idxByUser[m.UUID]; ok && out[idx].Enabled {
			continue
		}
		if !titleContainsAllTokens(lowerTitle, m.Keyword) {
			continue
		}
		// 제외 단어가 하나라도 제목에 있으면 이 행은 탈락. 같은 user 의 다음
		// 행(다른 포함 키워드)은 계속 평가된다 — 포함O·제외X 인 행이 대상.
		if excludeHitAnyToken(lowerTitle, exclude) {
			continue
		}
		idx, have := idxByUser[m.UUID]
		if !have {
			idxByUser[m.UUID] = len(out)
			out = append(out, m)
			continue
		}
		// 기존 대표는 disabled 매칭 — 이 행이 enabled 면 교체(push 우선).
		if m.Enabled {
			out[idx] = m
		}
	}
	return out, rows.Err()
}

// excludeHitAnyToken: lowerTitle 에 exclude(정규화된 CSV)의 토큰이 **하나라도**
// substring 으로 들어있으면 true (OR — 포함의 AND 와 반대). 빈 exclude 는
// false(제외 없음). exclude 는 이미 lowercase 저장이라 토큰 ToLower 불필요.
func excludeHitAnyToken(lowerTitle, exclude string) bool {
	for _, t := range strings.Split(exclude, ",") {
		t = strings.TrimSpace(t)
		if t == "" {
			continue
		}
		if strings.Contains(lowerTitle, t) {
			return true
		}
	}
	return false
}

// titleContainsAllTokens: lowerTitle 에 keyword(정규화된 CSV)의 모든 토큰이
// substring 으로 들어있는지. 토큰 0개면 false (방어선 — 정규화에서 막혔지만
// DB가 corrupt 한 경우 폭격 방지).
//
// keyword 는 이미 lowercase 로 저장되므로 토큰 자체는 ToLower 불필요.
func titleContainsAllTokens(lowerTitle, keyword string) bool {
	tokens := strings.Split(keyword, ",")
	hadAny := false
	for _, t := range tokens {
		t = strings.TrimSpace(t)
		if t == "" {
			continue
		}
		hadAny = true
		if !strings.Contains(lowerTitle, t) {
			return false
		}
	}
	return hadAny
}

// AlertHistoryItem 클라이언트에 노출하는 알림 이력 한 건. JSON 태그는
// iOS AlertHistoryItem (snake_case) 디코더와 합의된 형태. Read 는 read_at
// 컬럼이 set 됐는지(=글을 열어 읽음 처리됐는지) 여부.
type AlertHistoryItem struct {
	ID      int64  `json:"id"`
	Keyword string `json:"keyword"`
	PostNo  string `json:"post_no"`
	Title   string `json:"title"`
	URL     string `json:"url"`
	SentAt  int64  `json:"sent_at"` // Unix seconds
	Read    bool   `json:"read"`
}

// RecordAlert 매칭된 글을 유저 이력에 한 줄 추가하고 새 row id 를 반환한다
// (read_at = NULL → 안 읽음). 반환 id 는 APNs payload 에 실어 푸시-탭 시 읽음
// 처리에 쓴다. 보관 개수 제한 없음 — 전부 누적. 푸시 발송 성공/실패와 무관하게
// "매칭됨" 시점을 기록하며, 실패해도 폴 사이클을 막지 않게 caller 가 로그만 남김.
func (s *Store) RecordAlert(ctx context.Context, uuid, keyword, postNo, title, url string) (int64, error) {
	// Postgres 드라이버는 LastInsertId 미지원 → RETURNING 으로 새 id 회수.
	var id int64
	err := s.db.QueryRowContext(ctx,
		`INSERT INTO alert_history (uuid, keyword, post_no, title, url, sent_at)
		 VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
		uuid, keyword, postNo, title, url, time.Now().Unix()).Scan(&id)
	if err != nil {
		return 0, err
	}
	return id, nil
}

// ListAlertHistory 유저의 알림 이력을 최신순으로 limit 건 반환.
func (s *Store) ListAlertHistory(ctx context.Context, uuid string, limit int) ([]AlertHistoryItem, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, keyword, post_no, title, url, sent_at, read_at
		 FROM alert_history WHERE uuid = $1 ORDER BY id DESC LIMIT $2`, uuid, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AlertHistoryItem{}
	for rows.Next() {
		var it AlertHistoryItem
		var readAt sql.NullInt64
		if err := rows.Scan(&it.ID, &it.Keyword, &it.PostNo, &it.Title, &it.URL, &it.SentAt, &readAt); err != nil {
			return nil, err
		}
		it.Read = readAt.Valid
		out = append(out, it)
	}
	return out, rows.Err()
}

// MarkAlertRead 해당 유저의 알림 한 건을 읽음 처리(read_at = now). uuid 조건으로
// 남의 알림은 못 건드린다. 이미 읽음이면 no-op(read_at IS NULL 가드, idempotent).
// 매칭 row 가 없어도(없는 id/남의 id) 에러 없이 통과 — uuid 스코프로 데이터는
// 보호되고, 멱등 의도라 caller(핸들러)는 항상 200 을 돌려준다.
func (s *Store) MarkAlertRead(ctx context.Context, uuid string, id int64) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE alert_history SET read_at = $1
		 WHERE uuid = $2 AND id = $3 AND read_at IS NULL`,
		time.Now().Unix(), uuid, id)
	return err
}

// ClearPushTokenByValue APNs 410 self-heal — 토큰 값으로 user 찾아 NULL.
// 한 token 이 한 user 에게만 매핑된다는 invariant 가정.
func (s *Store) ClearPushTokenByValue(ctx context.Context, token string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE users SET push_token = NULL WHERE push_token = $1`, token)
	return err
}

// MetricPayloadRow 저장된 MetricKit payload 한 건. Payload 는 가공 안 한 raw JSON
// (MXMetricPayload / MXDiagnosticPayload 의 jsonRepresentation). 해석은 admin 뷰에서.
type MetricPayloadRow struct {
	ID         int64
	UUID       string
	Kind       string    // "metric" | "diagnostic"
	ReceivedAt time.Time // 수신 시각(서버). 컬럼 DEFAULT now() 가 채운다.
	Payload    string
}

// InsertMetricPayload raw payload 를 저장한다. 보관 개수 제한 없음 — 전부 누적
// (alert_history 와 동일 방침). MetricKit 은 하루 1건가량이라 비대해지지 않는다.
// received_at 은 컬럼 DEFAULT now() 가 채운다(timestamptz).
func (s *Store) InsertMetricPayload(ctx context.Context, uuid, kind, payload string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO metric_payloads (uuid, kind, payload) VALUES ($1, $2, $3)`,
		uuid, kind, payload)
	return err
}

// ListMetricPayloads 전 사용자의 payload 를 최신순으로 limit 건 반환(admin 뷰용).
func (s *Store) ListMetricPayloads(ctx context.Context, limit int) ([]MetricPayloadRow, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, uuid, kind, received_at, payload
		 FROM metric_payloads ORDER BY id DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []MetricPayloadRow{}
	for rows.Next() {
		var r MetricPayloadRow
		if err := rows.Scan(&r.ID, &r.UUID, &r.Kind, &r.ReceivedAt, &r.Payload); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// FootprintSample iOS 가 보낸 메모리 footprint 한 점. ClientTS 는 클라 epoch
// seconds, MB 는 phys_footprint(jetsam 이 보는 값), AvailMB 는 한도까지 남은 여유.
// Label 은 그 시점 이벤트("board:…", "post-open:…", "tick", "scenePhase:…" 등).
type FootprintSample struct {
	ClientTS int64  `json:"ts"`
	Label    string `json:"label"`
	MB       int    `json:"mb"`
	AvailMB  int    `json:"avail"`
	LiveMB   int    `json:"live"`  // malloc size_in_use(살아있는 힙). gap=단편화 진단용
	AllocMB  int    `json:"alloc"` // malloc size_allocated(OS 에서 예약). alloc-live=단편화
}

// InsertFootprintSamples 배치를 단일 트랜잭션으로 저장. 보관 제한 없이 누적
// (footprint 는 변화량 기반 샘플링이라 평상시엔 거의 안 쌓인다). 빈 배치는 no-op.
func (s *Store) InsertFootprintSamples(ctx context.Context, uuid string, samples []FootprintSample) error {
	if len(samples) == 0 {
		return nil
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // commit 성공 시 Rollback 은 no-op
	// client_ts 는 클라 epoch seconds → to_timestamp 로 timestamptz 저장.
	// received_at 은 컬럼 DEFAULT now() 가 채운다.
	stmt, err := tx.PrepareContext(ctx,
		`INSERT INTO footprint_samples (uuid, client_ts, label, mb, avail_mb, live_mb, alloc_mb)
		 VALUES ($1, to_timestamp($2), $3, $4, $5, $6, $7)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, s := range samples {
		if _, err := stmt.ExecContext(ctx, uuid, s.ClientTS, s.Label, s.MB, s.AvailMB, s.LiveMB, s.AllocMB); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// FootprintRow 저장된 샘플 한 줄(admin 뷰용).
type FootprintRow struct {
	UUID     string
	ClientTS time.Time
	Label    string
	MB       int
	AvailMB  int
	LiveMB   int
	AllocMB  int
}

// ListFootprintSamples 최신순으로 limit 건 반환(전 사용자).
func (s *Store) ListFootprintSamples(ctx context.Context, limit int) ([]FootprintRow, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT uuid, client_ts, label, mb, avail_mb, live_mb, alloc_mb
		 FROM footprint_samples ORDER BY id DESC LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FootprintRow{}
	for rows.Next() {
		var r FootprintRow
		if err := rows.Scan(&r.UUID, &r.ClientTS, &r.Label, &r.MB, &r.AvailMB, &r.LiveMB, &r.AllocMB); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// UserExists 테스트용 헬퍼. UpsertUser 가 실제로 row 를 만들었는지 검증.
func (s *Store) UserExists(ctx context.Context, uuid string) (bool, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users WHERE uuid = $1`, uuid).Scan(&n)
	if err != nil {
		return false, err
	}
	return n > 0, nil
}
