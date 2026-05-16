// Package db 는 SQLite 단일 진입점이다. 모든 query 가 여기를 통과.
// modernc.org/sqlite 는 pure Go (CGO 없음) — Pi cross-compile 자명.
package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
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
    PRIMARY KEY (uuid, keyword),
    FOREIGN KEY (uuid) REFERENCES users(uuid) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_users_with_token
    ON users(uuid) WHERE push_token IS NOT NULL;
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
type Match struct {
	UUID      string
	PushToken string
	Keyword   string
}

func (s *Store) ListKeywords(ctx context.Context, uuid string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT keyword FROM keyword_subs WHERE uuid = ? ORDER BY keyword`, uuid)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

// AddKeyword 중복은 PK 충돌 무시(INSERT OR IGNORE).
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

func (s *Store) RemoveKeyword(ctx context.Context, uuid, keyword string) error {
	_, err := s.db.ExecContext(ctx,
		`DELETE FROM keyword_subs WHERE uuid = ? AND keyword = ?`, uuid, keyword)
	return err
}

// MatchedUsersForTitle 글 제목에 user 의 키워드가 substring 으로 박혀 있고
// 그 user 에게 push_token 이 있으면 (uuid, token, keyword) 를 반환.
// case-insensitive 매칭을 위해 LOWER() 비교. 매칭은 SQL 단에서 처리해
// 메모리 폭증을 막는다(사용자 수 < 10 가정이지만 키워드 수 제한 없음).
func (s *Store) MatchedUsersForTitle(ctx context.Context, title string) ([]Match, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT u.uuid, u.push_token, k.keyword
		FROM keyword_subs k
		JOIN users u ON u.uuid = k.uuid
		WHERE u.push_token IS NOT NULL
		  AND INSTR(LOWER(?), LOWER(k.keyword)) > 0
		ORDER BY u.uuid, k.keyword`, title)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []Match
	seen := map[string]bool{} // user 당 첫 매칭 키워드만 (중복 push 방지)
	for rows.Next() {
		var m Match
		if err := rows.Scan(&m.UUID, &m.PushToken, &m.Keyword); err != nil {
			return nil, err
		}
		if seen[m.UUID] {
			continue
		}
		seen[m.UUID] = true
		out = append(out, m)
	}
	return out, rows.Err()
}

// ClearPushTokenByValue APNs 410 self-heal — 토큰 값으로 user 찾아 NULL.
// 한 token 이 한 user 에게만 매핑된다는 invariant 가정.
func (s *Store) ClearPushTokenByValue(ctx context.Context, token string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE users SET push_token = NULL WHERE push_token = ?`, token)
	return err
}
