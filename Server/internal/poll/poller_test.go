package poll

import (
	"context"
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
	if p.sentinel != "ppomppu-2" {
		t.Errorf("sentinel: want ppomppu-2, got %q", p.sentinel)
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

	if p.sentinel != "ppomppu-4" {
		t.Errorf("sentinel: want ppomppu-4, got %q", p.sentinel)
	}
}

func TestPoller_SentinelWalk_StopsAtMaxPages(t *testing.T) {
	store, _ := db.Open(":memory:")
	defer store.Close()

	fetcher := &stubFetcher{pages: map[int][]Post{}}
	for i := 1; i <= 20; i++ {
		fetcher.pages[i] = []Post{{ID: "x", Title: "t", PostNo: "x", URL: "u"}}
	}
	apns := &recordedAPNs{}
	p := New(store, fetcher, apns)
	p.sentinel = "ppomppu-NEVER"
	start := time.Now()
	if err := p.Tick(context.Background()); err != nil {
		t.Fatalf("tick: %v", err)
	}
	if time.Since(start) > 2*time.Second {
		t.Error("tick took too long — likely no maxPages cap")
	}
}
