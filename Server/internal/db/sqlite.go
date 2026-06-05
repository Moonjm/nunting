// Package db 는 SQLite 단일 진입점이다. 모든 query 가 여기를 통과.
// modernc.org/sqlite 는 pure Go (CGO 없음) — Pi cross-compile 자명.
package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const schemaSQL = `
CREATE TABLE IF NOT EXISTS users (
    uuid       TEXT PRIMARY KEY,
    push_token TEXT,
    created_at INTEGER NOT NULL
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
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    uuid    TEXT NOT NULL,
    keyword TEXT NOT NULL,
    post_no TEXT NOT NULL,
    title   TEXT NOT NULL,
    url     TEXT NOT NULL,
    sent_at INTEGER NOT NULL,
    read_at INTEGER,
    FOREIGN KEY (uuid) REFERENCES users(uuid) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_alert_history_uuid_id
    ON alert_history(uuid, id DESC);
`

// Store 는 *sql.DB 래퍼. 모든 query method 가 context-aware.
type Store struct {
	db *sql.DB
}

// Open path 가 ":memory:" 면 in-memory(테스트용). 그 외엔 디스크 파일.
// WAL + foreign_keys 는 connection-scoped 라 _pragma URL 옵션으로 강제.
func Open(path string) (*Store, error) {
	// modernc.org/sqlite 는 ?_pragma=foo=bar 형태 query 옵션 지원.
	dsn := path + "?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("sql.Open: %w", err)
	}
	// 단일 connection 강제 — SQLite single-writer 라 multi-conn 이 BUSY 만 늘림.
	db.SetMaxOpenConns(1)

	if _, err := db.Exec(schemaSQL); err != nil {
		db.Close()
		return nil, fmt.Errorf("schema: %w", err)
	}
	// read_at 없던 시절(초기 alert_history) 배포 DB 마이그레이션. 이미 컬럼이
	// 있으면 "duplicate column name" 만 무시하고, 그 외 에러는 전파.
	if _, err := db.Exec(`ALTER TABLE alert_history ADD COLUMN read_at INTEGER`); err != nil {
		if !strings.Contains(err.Error(), "duplicate column name") {
			db.Close()
			return nil, fmt.Errorf("migrate read_at: %w", err)
		}
	}
	// keyword_subs.exclude 없던 시절(제외 키워드 도입 전) 배포 DB 마이그레이션.
	// 기존 행은 ''(제외 없음)이 되어 도입 전과 동일하게 동작.
	if _, err := db.Exec(`ALTER TABLE keyword_subs ADD COLUMN exclude TEXT NOT NULL DEFAULT ''`); err != nil {
		if !strings.Contains(err.Error(), "duplicate column name") {
			db.Close()
			return nil, fmt.Errorf("migrate exclude: %w", err)
		}
	}
	// keyword_subs.enabled 없던 시절(키워드별 토글 도입 전) 배포 DB 마이그레이션.
	// 기존 행은 1(켜짐)이 되어 도입 전과 동일하게 모두 push 대상.
	if _, err := db.Exec(`ALTER TABLE keyword_subs ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1`); err != nil {
		if !strings.Contains(err.Error(), "duplicate column name") {
			db.Close()
			return nil, fmt.Errorf("migrate enabled: %w", err)
		}
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

// UpsertUser 는 INSERT-or-nothing. created_at 은 첫 INSERT 시각으로 고정.
// Bearer 미들웨어가 매 요청마다 호출해도 created_at 안 변함.
func (s *Store) UpsertUser(ctx context.Context, uuid string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO users (uuid, push_token, created_at) VALUES (?, NULL, ?)
		 ON CONFLICT(uuid) DO NOTHING`,
		uuid, time.Now().Unix())
	return err
}

// SetPushToken token == "" 이면 NULL (clear).
func (s *Store) SetPushToken(ctx context.Context, uuid, token string) error {
	if token == "" {
		_, err := s.db.ExecContext(ctx, `UPDATE users SET push_token = NULL WHERE uuid = ?`, uuid)
		return err
	}
	_, err := s.db.ExecContext(ctx, `UPDATE users SET push_token = ? WHERE uuid = ?`, token, uuid)
	return err
}

// GetPushToken nil pointer 면 토큰 없음(또는 NULL). 토큰 있으면 *string.
func (s *Store) GetPushToken(ctx context.Context, uuid string) (*string, error) {
	var token sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT push_token FROM users WHERE uuid = ?`, uuid).Scan(&token)
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
		`SELECT keyword, exclude, enabled FROM keyword_subs WHERE uuid = ? ORDER BY keyword`, uuid)
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
// DEFAULT '' 로 채워진다. 제외까지 다루는 경로는 UpsertKeyword 를 쓴다.
func (s *Store) AddKeyword(ctx context.Context, uuid, keyword string) error {
	// 빈 키워드는 silent reject — INSTR(LOWER(title), "") 는 모든 글에 매칭되어
	// 사용자에게 폴 사이클마다 push 폭격이 됨. API 계층(Task 5)도 trim 후
	// 거부하지만 DB 계층에서도 방어선 추가.
	if keyword == "" {
		return nil
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT OR IGNORE INTO keyword_subs (uuid, keyword) VALUES (?, ?)`, uuid, keyword)
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
		INSERT INTO keyword_subs (uuid, keyword, exclude) VALUES (?, ?, ?)
		ON CONFLICT(uuid, keyword) DO UPDATE SET exclude = excluded.exclude
		RETURNING enabled`,
		uuid, keyword, exclude).Scan(&enabled)
	if err != nil {
		return false, err
	}
	return enabled != 0, nil
}

func (s *Store) RemoveKeyword(ctx context.Context, uuid, keyword string) error {
	_, err := s.db.ExecContext(ctx,
		`DELETE FROM keyword_subs WHERE uuid = ? AND keyword = ?`, uuid, keyword)
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
		`UPDATE keyword_subs SET enabled = ? WHERE uuid = ? AND keyword = ?`, v, uuid, keyword)
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
	res, err := s.db.ExecContext(ctx,
		`INSERT INTO alert_history (uuid, keyword, post_no, title, url, sent_at)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		uuid, keyword, postNo, title, url, time.Now().Unix())
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// ListAlertHistory 유저의 알림 이력을 최신순으로 limit 건 반환.
func (s *Store) ListAlertHistory(ctx context.Context, uuid string, limit int) ([]AlertHistoryItem, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, keyword, post_no, title, url, sent_at, read_at
		 FROM alert_history WHERE uuid = ? ORDER BY id DESC LIMIT ?`, uuid, limit)
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
		`UPDATE alert_history SET read_at = ?
		 WHERE uuid = ? AND id = ? AND read_at IS NULL`,
		time.Now().Unix(), uuid, id)
	return err
}

// ClearPushTokenByValue APNs 410 self-heal — 토큰 값으로 user 찾아 NULL.
// 한 token 이 한 user 에게만 매핑된다는 invariant 가정.
func (s *Store) ClearPushTokenByValue(ctx context.Context, token string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE users SET push_token = NULL WHERE push_token = ?`, token)
	return err
}

// UserExists 테스트용 헬퍼. UpsertUser 가 실제로 row 를 만들었는지 검증.
func (s *Store) UserExists(ctx context.Context, uuid string) (bool, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users WHERE uuid = ?`, uuid).Scan(&n)
	if err != nil {
		return false, err
	}
	return n > 0, nil
}
