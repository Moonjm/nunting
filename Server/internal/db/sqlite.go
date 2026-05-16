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
