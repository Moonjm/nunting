// Package logfile 은 날짜별 로그 파일 rotation + N 일 이전 자동 삭제.
// io.Writer 인터페이스라 slog.NewJSONHandler 의 출력으로 그대로 꽂힘.
//
// 파일명: nunting-YYYY-MM-DD.log
// 회전: 첫 Write 의 날짜와 다른 날짜의 Write 가 들어오면 다음 파일로 switch.
// 삭제: rotation 시점에 dir 을 한 번 훑어 retainDays 보다 오래된 파일 unlink.
package logfile

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	filePrefix = "nunting-"
	fileSuffix = ".log"
	dateFmt    = "2006-01-02"
)

// DailyRotator io.Writer + Closer. 동시 Write 안전 (mutex).
type DailyRotator struct {
	dir        string
	retainDays int
	now        func() time.Time // 테스트 주입 가능

	mu      sync.Mutex
	cur     *os.File
	curDate string
}

// NewDailyRotator dir 이 없으면 생성. 첫 파일 open + 오래된 파일 cleanup 도 수행.
func NewDailyRotator(dir string, retainDays int) (*DailyRotator, error) {
	return newWithClock(dir, retainDays, time.Now)
}

func newWithClock(dir string, retainDays int, now func() time.Time) (*DailyRotator, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("mkdir log dir: %w", err)
	}
	r := &DailyRotator{dir: dir, retainDays: retainDays, now: now}
	if err := r.rotateLocked(now()); err != nil {
		return nil, err
	}
	return r, nil
}

// Write today 가 변했으면 회전 후 append. Close 이후 호출되면 os.ErrClosed.
func (r *DailyRotator) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cur == nil {
		return 0, os.ErrClosed
	}
	now := r.now()
	today := now.Format(dateFmt)
	if today != r.curDate {
		if err := r.rotateLocked(now); err != nil {
			return 0, err
		}
	}
	return r.cur.Write(p)
}

func (r *DailyRotator) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cur == nil {
		return nil
	}
	err := r.cur.Close()
	r.cur = nil
	return err
}

// rotateLocked 호출자가 mu 잡고 있다는 전제. 새 파일을 먼저 열고 성공 시에만
// 기존 파일을 닫는다 — open 실패 시 dead-state(nil cur)로 떨어지지 않게.
// cleanup 은 별도 goroutine — disk I/O 가 lock 잡힌 write 들을 막지 않도록.
func (r *DailyRotator) rotateLocked(now time.Time) error {
	date := now.Format(dateFmt)
	path := filepath.Join(r.dir, filePrefix+date+fileSuffix)
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("open log file: %w", err)
	}
	if r.cur != nil {
		_ = r.cur.Close()
	}
	r.cur = f
	r.curDate = date
	// cleanup 실패는 무시 (logging 자체는 살려야 함). goroutine 으로 분리.
	go func(dir string, retain int, t time.Time) {
		_ = cleanupOldFiles(dir, retain, t)
	}(r.dir, r.retainDays, now)
	return nil
}

// cleanupOldFiles dir 안에서 nunting-YYYY-MM-DD.log 매칭 파일들 중
// (now - retainDays) 이전 것 unlink. retainDays <= 0 이면 no-op.
func cleanupOldFiles(dir string, retainDays int, now time.Time) error {
	if retainDays <= 0 {
		return nil
	}
	cutoff := now.AddDate(0, 0, -retainDays)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, filePrefix) || !strings.HasSuffix(name, fileSuffix) {
			continue
		}
		dateStr := strings.TrimSuffix(strings.TrimPrefix(name, filePrefix), fileSuffix)
		t, err := time.Parse(dateFmt, dateStr)
		if err != nil {
			continue
		}
		if t.Before(cutoff) {
			_ = os.Remove(filepath.Join(dir, name))
		}
	}
	return nil
}
