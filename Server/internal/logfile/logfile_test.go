package logfile

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNewDailyRotator_CreatesDirAndFirstFile(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "logs")
	now := time.Date(2026, 5, 17, 10, 0, 0, 0, time.UTC)

	r, err := newWithClock(dir, 30, func() time.Time { return now })
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	defer r.Close()

	expected := filepath.Join(dir, "nunting-2026-05-17.log")
	if _, err := os.Stat(expected); err != nil {
		t.Errorf("expected file %q: %v", expected, err)
	}
}

func TestWrite_AppendsAndRotates(t *testing.T) {
	dir := t.TempDir()
	clock := time.Date(2026, 5, 17, 10, 0, 0, 0, time.UTC)
	tick := func() time.Time { return clock }

	r, err := newWithClock(dir, 30, tick)
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	defer r.Close()

	r.Write([]byte("day1-line1\n"))
	r.Write([]byte("day1-line2\n"))

	// 다음 날로 시계 이동.
	clock = clock.Add(24 * time.Hour)
	r.Write([]byte("day2-line1\n"))

	day1 := filepath.Join(dir, "nunting-2026-05-17.log")
	day2 := filepath.Join(dir, "nunting-2026-05-18.log")

	b1, _ := os.ReadFile(day1)
	if string(b1) != "day1-line1\nday1-line2\n" {
		t.Errorf("day1 content: %q", string(b1))
	}
	b2, _ := os.ReadFile(day2)
	if string(b2) != "day2-line1\n" {
		t.Errorf("day2 content: %q", string(b2))
	}
}

func TestCleanup_RemovesFilesOlderThanRetention(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 5, 17, 10, 0, 0, 0, time.UTC)

	// 가짜 파일들 생성. cutoff = now - 30 일 = 2026-04-17 10:00 UTC.
	// 파일 타임스탬프는 파일명의 자정(00:00) 으로 parse 되므로 정확히 30일
	// 전 파일도 t.Before(cutoff) 참 → 삭제. 즉 "30 일 이전" 보존 contract.
	files := map[string]bool{
		"nunting-2026-05-16.log": true,  // 1일 전 — 유지
		"nunting-2026-04-18.log": true,  // 29일 전 — 유지
		"nunting-2026-04-17.log": false, // 30일 전 자정 (cutoff 보다 10시간 이전) — 삭제
		"nunting-2026-04-16.log": false, // 31일 전 — 삭제
		"nunting-2026-03-18.log": false, // 60일 전 — 삭제
		"other-2026-04-16.log":   true,  // prefix 다름 — 무시
		"nunting-not-a-date.log": true,  // 파싱 실패 — 무시
		"nunting-2026-05-15.txt": true,  // suffix 다름 — 무시
	}
	for name := range files {
		path := filepath.Join(dir, name)
		os.WriteFile(path, []byte("x"), 0o644)
	}

	if err := cleanupOldFiles(dir, 30, now); err != nil {
		t.Fatalf("cleanup: %v", err)
	}

	for name, shouldExist := range files {
		_, err := os.Stat(filepath.Join(dir, name))
		exists := err == nil
		if exists != shouldExist {
			t.Errorf("%s: expected exists=%v, got %v (err=%v)", name, shouldExist, exists, err)
		}
	}
}

func TestWrite_AfterCloseReturnsErrClosed(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 5, 17, 10, 0, 0, 0, time.UTC)
	r, err := newWithClock(dir, 30, func() time.Time { return now })
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	if err := r.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	n, err := r.Write([]byte("x"))
	if n != 0 || !errors.Is(err, os.ErrClosed) {
		t.Errorf("Write after Close: got (n=%d, err=%v), want (0, os.ErrClosed)", n, err)
	}
}

func TestCleanup_NoOpWhenRetainDaysZeroOrNegative(t *testing.T) {
	dir := t.TempDir()
	now := time.Date(2026, 5, 17, 10, 0, 0, 0, time.UTC)
	old := filepath.Join(dir, "nunting-2020-01-01.log")
	os.WriteFile(old, []byte("x"), 0o644)

	cleanupOldFiles(dir, 0, now)
	if _, err := os.Stat(old); err != nil {
		t.Error("retainDays=0 should not delete anything")
	}

	cleanupOldFiles(dir, -1, now)
	if _, err := os.Stat(old); err != nil {
		t.Error("retainDays=-1 should not delete anything")
	}
}
