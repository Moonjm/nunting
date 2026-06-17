// nunting-server entry point.
// 부팅 순서:
//  1. env 읽기 (NUNTING_*, APNS_*)
//  2. DB open (NUNTING_DB_PATH)
//  3. APNs 클라이언트 (env 누락 시 stub 모드)
//  4. HTTP 서버 (NUNTING_BIND_HOST:NUNTING_BIND_PORT)
//  5. 폴러 goroutine (NUNTING_POLL_INTERVAL_SECONDS)
//  6. SIGINT/SIGTERM 시 graceful: ctx cancel → 서버 Shutdown(5s) → db Close
package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/Moonjm/nunting/server/internal/api"
	"github.com/Moonjm/nunting/server/internal/apns"
	"github.com/Moonjm/nunting/server/internal/db"
	"github.com/Moonjm/nunting/server/internal/logfile"
	"github.com/Moonjm/nunting/server/internal/poll"
)

func main() {
	// 1) env
	dbDSN := postgresDSN()
	bindHost := envOr("NUNTING_BIND_HOST", "127.0.0.1")
	bindPort := envOr("NUNTING_BIND_PORT", "8080")
	pollIntervalSec, _ := strconv.Atoi(envOr("NUNTING_POLL_INTERVAL_SECONDS", "180"))
	if pollIntervalSec <= 0 {
		pollIntervalSec = 180
	}
	logDir := os.Getenv("NUNTING_LOG_DIR")
	retainDays := 30
	if v := os.Getenv("NUNTING_LOG_RETENTION_DAYS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			retainDays = n
		}
	}

	// log handler — stdout 항상. NUNTING_LOG_DIR 있으면 dir 안에 날짜별 파일
	// 생성 + N 일 이전 자동 삭제. 호스트 bind mount 면 컨테이너 lifecycle 과 독립.
	var logWriter io.Writer = os.Stdout
	if logDir != "" {
		rot, err := logfile.NewDailyRotator(logDir, retainDays)
		if err != nil {
			slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
			slog.Warn("log_dir_open_failed", "dir", logDir, "err", err)
		} else {
			logWriter = io.MultiWriter(os.Stdout, rot)
			defer rot.Close()
		}
	}
	slog.SetDefault(slog.New(slog.NewJSONHandler(logWriter, nil)))
	if logDir != "" {
		slog.Info("log_dir_enabled", "dir", logDir, "retain_days", retainDays)
	}

	// 2) DB (PostgreSQL)
	store, err := db.Open(dbDSN)
	if err != nil {
		// DSN 은 password 포함이라 로그에 그대로 안 남긴다.
		slog.Error("db_open_failed", "host", envOr("NUNTING_DB_HOST", "localhost"), "err", err)
		os.Exit(1)
	}
	defer store.Close()

	// 3) APNs
	apnsClient, err := apns.New(apns.Config{
		KeyPath: os.Getenv("APNS_KEY_PATH"),
		KeyID:   os.Getenv("APNS_KEY_ID"),
		TeamID:  os.Getenv("APNS_TEAM_ID"),
		Topic:   os.Getenv("APNS_TOPIC"),
		Host:    envOr("APNS_HOST", "api.sandbox.push.apple.com"),
	})
	if err != nil {
		slog.Error("apns_init_failed", "err", err)
		os.Exit(1)
	}
	apnsClient.SetTokenClearer(store)

	// 4) HTTP server — slow-write DoS 와 connection leak 방지용 타임아웃.
	// 외부 노출 (Cloudflare proxy) 전제 하에 보수적 값.
	srv := &http.Server{
		Addr:              bindHost + ":" + bindPort,
		Handler:           api.NewRouter(store),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	// 5) Poller goroutine
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	fetcher := &poll.HTTPFetcher{Client: &http.Client{Timeout: 15 * time.Second}}
	poller := poll.New(store, fetcher, apnsClient)
	go poller.Run(ctx, time.Duration(pollIntervalSec)*time.Second)

	// 6) Run + graceful shutdown
	serveErr := make(chan error, 1)
	go func() {
		slog.Info("http_serving", "addr", srv.Addr,
			"db_host", envOr("NUNTING_DB_HOST", "localhost"),
			"db_name", envOr("NUNTING_DB_NAME", "nnt"), "poll_sec", pollIntervalSec)
		serveErr <- srv.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
		slog.Info("shutdown_signal_received")
	case err := <-serveErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("serve_failed", "err", err)
		}
	}

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("shutdown_failed", "err", err)
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// postgresDSN NUNTING_DB_* env 로 Postgres DSN 을 조립한다. host/port/password 는
// 환경별로 다르고(.env 로 주입), user/db 는 로컬·Pi 동일(기본 nnt). password 가
// 특수문자를 포함해도 깨지지 않게 url.Userinfo 로 인코딩한다.
func postgresDSN() string {
	host := envOr("NUNTING_DB_HOST", "localhost")
	port := envOr("NUNTING_DB_PORT", "5432")
	name := envOr("NUNTING_DB_NAME", "nnt")
	user := envOr("NUNTING_DB_USER", "nnt")
	pass := os.Getenv("NUNTING_DB_PASSWORD")
	sslmode := envOr("NUNTING_DB_SSLMODE", "disable")

	u := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(user, pass),
		Host:     net.JoinHostPort(host, port),
		Path:     "/" + name,
		RawQuery: "sslmode=" + url.QueryEscape(sslmode),
	}
	return u.String()
}
