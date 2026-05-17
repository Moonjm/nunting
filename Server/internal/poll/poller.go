package poll

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/Moonjm/nunting/server/internal/db"
)

const (
	defaultMaxPages = 10
)

// Fetcher 와 APNsSender 는 테스트 mock 을 위해 인터페이스로 분리.
type Fetcher interface {
	FetchAndParse(ctx context.Context, page int) ([]Post, error)
}
type APNsSender interface {
	Send(ctx context.Context, deviceToken, matchedKeyword string, post Post) error
}

// HTTPFetcher 실 ppomppu 호출 — FetchListPage + ParseList 를 묶음.
type HTTPFetcher struct {
	Client *http.Client
}

func (h *HTTPFetcher) FetchAndParse(ctx context.Context, page int) ([]Post, error) {
	html, err := FetchListPage(ctx, h.Client, page)
	if err != nil {
		return nil, fmt.Errorf("fetch page %d: %w", page, err)
	}
	return ParseList(html)
}

// Poller sentinel walk + APNs 디스패치. 메모리에 sentinel(=마지막으로 본
// newest post id) 만 유지. 컨테이너 재시작 시 sentinel 리셋되어 첫 tick 은
// 알림 skip.
type Poller struct {
	store    *db.Store
	fetcher  Fetcher
	apns     APNsSender
	sentinel string
	maxPages int
}

func New(store *db.Store, fetcher Fetcher, apns APNsSender) *Poller {
	return &Poller{
		store:    store,
		fetcher:  fetcher,
		apns:     apns,
		maxPages: defaultMaxPages,
	}
}

// Tick 한 사이클. 외부에서 timer 가 호출.
func (p *Poller) Tick(ctx context.Context) error {
	if p.sentinel == "" {
		// 첫 tick — page=1 top 만 sentinel 로 저장하고 종료.
		posts, err := p.fetcher.FetchAndParse(ctx, 1)
		if err != nil {
			return err
		}
		if len(posts) > 0 {
			p.sentinel = posts[0].ID
			slog.Info("poller_first_tick", "sentinel", p.sentinel)
		}
		return nil
	}

	// 이후 tick — sentinel walk.
	var newPosts []Post
walk:
	for page := 1; page <= p.maxPages; page++ {
		posts, err := p.fetcher.FetchAndParse(ctx, page)
		if err != nil {
			slog.Warn("poller_fetch_failed", "page", page, "err", err)
			return nil // 이번 tick 만 skip, sentinel 갱신 안 함
		}
		for _, post := range posts {
			if post.ID == p.sentinel {
				break walk
			}
			newPosts = append(newPosts, post)
		}
	}

	if len(newPosts) == 0 {
		// 신규 글 없어도 현재 sentinel 은 로그에 남김 — 운영자가 "지금 마지막
		// 으로 본 글이 뭐지" 즉시 확인 가능.
		slog.Info("poller_tick_no_new", "sentinel", p.sentinel)
		return nil
	}

	// 시간순(오래된 것부터)으로 처리.
	for i, j := 0, len(newPosts)-1; i < j; i, j = i+1, j-1 {
		newPosts[i], newPosts[j] = newPosts[j], newPosts[i]
	}

	sent := 0
	for _, post := range newPosts {
		matches, err := p.store.MatchedUsersForTitle(ctx, post.Title)
		if err != nil {
			slog.Error("poller_match_error", "post_id", post.ID, "err", err)
			continue
		}
		for _, m := range matches {
			if err := p.apns.Send(ctx, m.PushToken, m.Keyword, post); err != nil {
				slog.Error("poller_apns_error", "uuid", m.UUID, "post_id", post.ID, "err", err)
				continue
			}
			sent++
		}
	}

	// sentinel 은 newest = newPosts.last (reverse 후 마지막).
	p.sentinel = newPosts[len(newPosts)-1].ID
	slog.Info("poller_tick_done", "new_posts", len(newPosts), "apns_sent", sent, "new_sentinel", p.sentinel)
	return nil
}

// Run 외부에서 호출하는 ticker 루프. ctx Done 시 종료.
func (p *Poller) Run(ctx context.Context, interval time.Duration) {
	// 시작 직후 첫 tick (sentinel 잡기) — interval 기다리지 않음.
	if err := p.Tick(ctx); err != nil {
		slog.Error("poller_initial_tick_error", "err", err)
	}

	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := p.Tick(ctx); err != nil {
				slog.Error("poller_tick_error", "err", err)
			}
		}
	}
}
