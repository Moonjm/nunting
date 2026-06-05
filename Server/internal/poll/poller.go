package poll

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
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
	Send(ctx context.Context, deviceToken, matchedKeyword string, alertID int64, post Post) error
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

// Poller numeric-cutoff walk + APNs 디스패치. 메모리에 lastPostNo
// (=마지막으로 본 newest post no, ppomppu 의 ?no= 쿼리값) 만 유지.
// 컨테이너 재시작 시 0 으로 리셋되어 첫 tick 은 알림 skip — page=1
// 의 최대 PostNo 를 baseline 으로 잡고 종료.
//
// 이전 구현은 sentinel 을 ID 문자열로 들고 walk 에서 ID 동등 비교
// 만 했는데, sentinel post 가 maxPages 안에서 사라지면 (글 흐름이
// 빠른 시간대) walk 가 break 못 해 newPosts 에 옛 글까지 누적,
// 키워드 매치 시 옛 글에 push 가 발송되던 회귀가 있었다.
// PostNo 가 단조증가 numeric 이라는 사실을 이용해 cutoff 를
// numeric 비교로 바꾸면 sentinel post 가 list 에 없어도 정확히
// baseline 보다 큰 글만 push 대상이 된다.
//
// 동시성: `lastPostNo` 는 mutex 로 보호하지 않는다. `Tick` 는 외부
// 노출되어 있지만 본 코드베이스의 유일한 호출자는 `Run` 의 단일
// goroutine (초기 tick + ticker 루프 모두 같은 루프) 이고, 다른
// 진입점은 없다. 향후 admin 핸들러 등에서 동시 호출이 생기면 그
// 시점에 sync.Mutex 또는 atomic 도입.
type Poller struct {
	store      *db.Store
	fetcher    Fetcher
	apns       APNsSender
	lastPostNo int
	maxPages   int
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
	if p.lastPostNo == 0 {
		// 첫 tick — page=1 top 의 PostNo 를 baseline 으로 저장하고
		// 종료. 옛 글에 푸시 폭격 방지를 위한 cold-start 가드.
		posts, err := p.fetcher.FetchAndParse(ctx, 1)
		if err != nil {
			return err
		}
		// baseline 으로 page 1 의 최대 PostNo 를 선택한다. first valid
		// 만 잡으면 정렬 흔들림이나 공지 핀(보통 더 옛 ID)이 page 1 의
		// 첫 행에 있을 때 그 위에 있는 더 큰 ID 글들이 다음 tick 에서
		// '새 글' 로 잡혀 옛 글 push 폭격이 cold-start 직후에 다시
		// 재현된다.
		max := 0
		for _, post := range posts {
			if n, ok := postNoInt(post); ok && n > max {
				max = n
			}
		}
		if max > 0 {
			p.lastPostNo = max
			slog.Info("poller_first_tick", "last_post_no", max)
			return nil
		}
		// page 1 의 어떤 글도 PostNo 를 못 파싱 — parser 회귀나
		// 사이트 포맷 변경 신호. baseline 이 0 인 채로 끝나서
		// 다음 tick 도 다시 이 분기에 들어오므로, silent 가 아니라
		// 운영자에게 보이는 warning 으로 남긴다.
		slog.Warn("poller_first_tick_no_parseable_post", "page1_count", len(posts))
		return nil
	}

	// 이후 tick — postNo numeric cutoff walk + tick 내 dedupe.
	//
	// dedupe 가 왜 필요한가: page fetch 사이에 새 글이 들어오면
	// page 1 끝의 글이 page 2 top 으로 밀려 같은 PostNo 가 두 번
	// 보일 수 있다. 그대로 newPosts 에 누적하면 동일 글에 push 가
	// 두 번 발송되므로, postNo 를 키로 한 tick-local 집합으로 막는다.
	var newPosts []Post
	seen := make(map[int]struct{})
	maxSeen := p.lastPostNo
walk:
	for page := 1; page <= p.maxPages; page++ {
		posts, err := p.fetcher.FetchAndParse(ctx, page)
		if err != nil {
			slog.Warn("poller_fetch_failed", "page", page, "err", err)
			return nil // 이번 tick 만 skip, lastPostNo 갱신 안 함
		}
		for _, post := range posts {
			n, ok := postNoInt(post)
			if !ok {
				// 파싱 회귀가 들어와도 그 글만 skip 하고 walk 는 계속.
				slog.Warn("poller_post_no_unparseable", "post_id", post.ID)
				continue
			}
			if n <= p.lastPostNo {
				// newest-first 정렬 가정 — 첫 옛 글을 만나는 순간
				// 그 이후는 모두 옛 글이므로 walk 중단.
				break walk
			}
			if _, dup := seen[n]; dup {
				continue
			}
			seen[n] = struct{}{}
			newPosts = append(newPosts, post)
			if n > maxSeen {
				maxSeen = n
			}
		}
	}

	if len(newPosts) == 0 {
		// 신규 글 없어도 현재 baseline 은 로그에 남김.
		slog.Info("poller_tick_no_new", "last_post_no", p.lastPostNo)
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
			// 알림 이력은 발송 시도 전에 기록 — 토큰 만료 등으로 push 가
			// 실패해도 "키워드가 매칭됐다" 는 사실은 남긴다. 기록 실패는
			// 폴 사이클을 막지 않게 로그만 남기고 진행(alertID=0 → 클라 무시).
			alertID, err := p.store.RecordAlert(ctx, m.UUID, m.Keyword, post.PostNo, post.Title, post.URL)
			if err != nil {
				slog.Error("poller_history_error", "uuid", m.UUID, "post_id", post.ID, "err", err)
				alertID = 0
			}
			// 토글이 꺼진 키워드면 이력만 남기고 push 는 건너뛴다(앱에서 "받은
			// 알림"으로는 보이지만 푸시 배너/소리는 없음).
			if !m.Enabled {
				continue
			}
			if err := p.apns.Send(ctx, m.PushToken, m.Keyword, alertID, post); err != nil {
				slog.Error("poller_apns_error", "uuid", m.UUID, "post_id", post.ID, "err", err)
				continue
			}
			sent++
		}
	}

	p.lastPostNo = maxSeen
	slog.Info("poller_tick_done", "new_posts", len(newPosts), "apns_sent", sent, "last_post_no", p.lastPostNo)
	return nil
}

// postNoInt Post.PostNo 를 int 로 변환. 빈 문자열 / 비숫자는 (0, false).
func postNoInt(post Post) (int, bool) {
	if post.PostNo == "" {
		return 0, false
	}
	n, err := strconv.Atoi(post.PostNo)
	if err != nil || n <= 0 {
		return 0, false
	}
	return n, true
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
