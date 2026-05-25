package poll

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/Moonjm/nunting/server/internal/db"
)

type stubFetcher struct {
	pages map[int][]Post
}

func (f *stubFetcher) FetchAndParse(ctx context.Context, page int) ([]Post, error) {
	return f.pages[page], nil
}

type recordedAPNs struct {
	calls []apnsCall
}
type apnsCall struct {
	Token   string
	Keyword string
	PostID  string
}

func (a *recordedAPNs) Send(ctx context.Context, token, keyword string, post Post) error {
	a.calls = append(a.calls, apnsCall{token, keyword, post.ID})
	return nil
}

func TestPoller_FirstTickStoresSentinelOnly(t *testing.T) {
	store, _ := db.Open(":memory:")
	defer store.Close()
	store.UpsertUser(context.Background(), "nnt_a")
	store.SetPushToken(context.Background(), "nnt_a", "tok_a")
	store.AddKeyword(context.Background(), "nnt_a", "갤럭시")

	fetcher := &stubFetcher{pages: map[int][]Post{
		1: {{ID: "ppomppu-2", Title: "갤럭시 신상", PostNo: "2", URL: "u2"}},
	}}
	apns := &recordedAPNs{}

	p := New(store, fetcher, apns)
	if err := p.Tick(context.Background()); err != nil {
		t.Fatalf("tick: %v", err)
	}

	if len(apns.calls) != 0 {
		t.Errorf("first tick must not send: got %+v", apns.calls)
	}
	if p.lastPostNo != 2 {
		t.Errorf("lastPostNo: want 2, got %d", p.lastPostNo)
	}
}

func TestPoller_SecondTickSendsNewPosts(t *testing.T) {
	store, _ := db.Open(":memory:")
	defer store.Close()
	store.UpsertUser(context.Background(), "nnt_a")
	store.SetPushToken(context.Background(), "nnt_a", "tok_a")
	store.AddKeyword(context.Background(), "nnt_a", "갤럭시")

	fetcher := &stubFetcher{pages: map[int][]Post{
		1: {{ID: "ppomppu-2", Title: "갤럭시 1", PostNo: "2", URL: "u2"}},
	}}
	apns := &recordedAPNs{}
	p := New(store, fetcher, apns)
	p.Tick(context.Background())

	fetcher.pages[1] = []Post{
		{ID: "ppomppu-4", Title: "신규 갤럭시 4", PostNo: "4", URL: "u4"},
		{ID: "ppomppu-3", Title: "관계없음", PostNo: "3", URL: "u3"},
		{ID: "ppomppu-2", Title: "갤럭시 1", PostNo: "2", URL: "u2"},
	}
	if err := p.Tick(context.Background()); err != nil {
		t.Fatalf("second tick: %v", err)
	}

	if len(apns.calls) != 1 || apns.calls[0].PostID != "ppomppu-4" {
		t.Errorf("want 1 call for ppomppu-4, got %+v", apns.calls)
	}

	if p.lastPostNo != 4 {
		t.Errorf("lastPostNo: want 4, got %d", p.lastPostNo)
	}
}

func TestPoller_SkipsPostsOlderThanSentinel(t *testing.T) {
	// 회귀 방지: 이전 구현은 sentinel 을 ID 문자열로만 들고 동등 비교만
	// 했기 때문에 sentinel post 가 maxPages 안에서 사라지면 (글 흐름이
	// 빨라 11+ 페이지로 밀려난 경우) walk 가 break 못 해서 newPosts 에
	// 옛 글까지 누적, 키워드 매치 시 옛 글에 푸시가 발송됐다. 사용자
	// 보고: ppomppu no=706467 같은 옛 글에서 알람.
	//
	// 수정 후 정책 — postNo numeric cutoff: 가지고 있는 lastPostNo
	// 보다 큰 글만 push 대상. 같은 페이지에 옛/새 글이 섞여도 옛 글
	// 은 skip.
	store, _ := db.Open(":memory:")
	defer store.Close()
	store.UpsertUser(context.Background(), "nnt_a")
	store.SetPushToken(context.Background(), "nnt_a", "tok_a")
	store.AddKeyword(context.Background(), "nnt_a", "갤럭시")

	fetcher := &stubFetcher{pages: map[int][]Post{
		1: {
			{ID: "ppomppu-1010", Title: "갤럭시 신상", PostNo: "1010", URL: "u1010"},
			{ID: "ppomppu-998", Title: "갤럭시 옛글", PostNo: "998", URL: "u998"},
		},
	}}
	apns := &recordedAPNs{}
	p := New(store, fetcher, apns)
	p.lastPostNo = 1000

	if err := p.Tick(context.Background()); err != nil {
		t.Fatalf("tick: %v", err)
	}

	if len(apns.calls) != 1 || apns.calls[0].PostID != "ppomppu-1010" {
		t.Errorf("want exactly 1 push for ppomppu-1010, got %+v", apns.calls)
	}
	if p.lastPostNo != 1010 {
		t.Errorf("lastPostNo: want 1010, got %d", p.lastPostNo)
	}
}

func TestPoller_BreaksWalkOnceOlderPostSeen(t *testing.T) {
	// page 1 의 모든 글이 sentinel 보다 옛 글이면 walk 가 page 2 이상
	// 으로 더 깊이 들어가지 않아야 함 — newest-first 정렬 가정.
	store, _ := db.Open(":memory:")
	defer store.Close()
	store.UpsertUser(context.Background(), "nnt_a")
	store.SetPushToken(context.Background(), "nnt_a", "tok_a")
	store.AddKeyword(context.Background(), "nnt_a", "갤럭시")

	calls := 0
	fetcher := &stubFetcher{pages: map[int][]Post{
		1: {{ID: "ppomppu-990", Title: "갤럭시", PostNo: "990", URL: "u"}},
		2: {{ID: "ppomppu-980", Title: "갤럭시", PostNo: "980", URL: "u"}},
	}}
	wrapped := &countingFetcher{inner: fetcher, count: &calls}
	apns := &recordedAPNs{}
	p := New(store, wrapped, apns)
	p.lastPostNo = 1000

	if err := p.Tick(context.Background()); err != nil {
		t.Fatalf("tick: %v", err)
	}

	if len(apns.calls) != 0 {
		t.Errorf("want no pushes for all-old page, got %+v", apns.calls)
	}
	if calls != 1 {
		t.Errorf("want exactly 1 fetch (break after page 1), got %d", calls)
	}
}

type countingFetcher struct {
	inner Fetcher
	count *int
}

func (c *countingFetcher) FetchAndParse(ctx context.Context, page int) ([]Post, error) {
	*c.count++
	return c.inner.FetchAndParse(ctx, page)
}

func TestPoller_SkipsUnparseablePostNoWithoutBreakingWalk(t *testing.T) {
	// PostNo 가 int 변환 실패하는 글이 page 안에 끼어 있어도 — 그 글
	// 만 skip 하고 walk 자체는 계속. 파싱 회귀가 push 누락 으로 번지지
	// 않게 보호.
	store, _ := db.Open(":memory:")
	defer store.Close()
	store.UpsertUser(context.Background(), "nnt_a")
	store.SetPushToken(context.Background(), "nnt_a", "tok_a")
	store.AddKeyword(context.Background(), "nnt_a", "갤럭시")

	fetcher := &stubFetcher{pages: map[int][]Post{
		1: {
			{ID: "ppomppu-1010", Title: "갤럭시 정상", PostNo: "1010", URL: "u1010"},
			{ID: "ppomppu-XYZ", Title: "갤럭시 깨진id", PostNo: "XYZ", URL: "ux"},
		},
	}}
	apns := &recordedAPNs{}
	p := New(store, fetcher, apns)
	p.lastPostNo = 1000

	if err := p.Tick(context.Background()); err != nil {
		t.Fatalf("tick: %v", err)
	}

	if len(apns.calls) != 1 || apns.calls[0].PostID != "ppomppu-1010" {
		t.Errorf("want only ppomppu-1010, got %+v", apns.calls)
	}
}

func TestPoller_SentinelWalk_StopsAtMaxPages(t *testing.T) {
	store, _ := db.Open(":memory:")
	defer store.Close()

	// 매 페이지에 유일한 PostNo 를 가진 글을 둬서 cutoff 비교는 통과
	// 시키고 walk 가 maxPages cap 에 의해서만 멈추는지 검증. PostNo 는
	// page 가 깊어질수록 작아지지만 (newest-first 정렬 시뮬) 모두 baseline(=1)
	// 보다는 크다 — 그래서 break 안 되고 maxPages 까지 walk.
	fetcher := &stubFetcher{pages: map[int][]Post{}}
	for i := 1; i <= 20; i++ {
		no := 100000 - i
		fetcher.pages[i] = []Post{{
			ID:     fmt.Sprintf("ppomppu-%d", no),
			Title:  "t",
			PostNo: fmt.Sprintf("%d", no),
			URL:    "u",
		}}
	}
	apns := &recordedAPNs{}
	p := New(store, fetcher, apns)
	p.lastPostNo = 1
	start := time.Now()
	if err := p.Tick(context.Background()); err != nil {
		t.Fatalf("tick: %v", err)
	}
	if time.Since(start) > 2*time.Second {
		t.Error("tick took too long — likely no maxPages cap")
	}
}
