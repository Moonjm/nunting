// nunting-server entry point.
// 부팅 순서:
//   1) env 읽기 (NUNTING_*, APNS_*)
//   2) DB open (NUNTING_DB_PATH)
//   3) APNs 클라이언트 (env 누락 시 stub 모드)
//   4) HTTP 서버 (NUNTING_BIND_HOST:NUNTING_BIND_PORT)
//   5) 폴러 goroutine (NUNTING_POLL_INTERVAL_SECONDS)
//   6) SIGINT/SIGTERM 시 graceful: ctx cancel → 서버 Shutdown(5s) → db Close
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/Moonjm/nunting/server/internal/apns"
	"github.com/Moonjm/nunting/server/internal/api"
	"github.com/Moonjm/nunting/server/internal/db"
	"github.com/Moonjm/nunting/server/internal/poll"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

	// 1) env
	dbPath := envOr("NUNTING_DB_PATH", "/var/lib/nunting/state.db")
	bindHost := envOr("NUNTING_BIND_HOST", "127.0.0.1")
	bindPort := envOr("NUNTING_BIND_PORT", "8080")
	pollIntervalSec, _ := strconv.Atoi(envOr("NUNTING_POLL_INTERVAL_SECONDS", "180"))
	if pollIntervalSec <= 0 {
		pollIntervalSec = 180
	}

	// 2) DB
	store, err := db.Open(dbPath)
	if err != nil {
		slog.Error("db_open_failed", "path", dbPath, "err", err)
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

	// 4) HTTP server
	srv := &http.Server{
		Addr:              bindHost + ":" + bindPort,
		Handler:           api.NewRouter(store),
		ReadHeaderTimeout: 10 * time.Second,
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
		slog.Info("http_serving", "addr", srv.Addr, "db_path", dbPath, "poll_sec", pollIntervalSec)
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
