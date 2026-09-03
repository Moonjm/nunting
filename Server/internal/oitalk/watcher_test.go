package oitalk

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// fakeOitalk 핸들러가 다른 goroutine 에서도 불리므로 mutex 로 보호.
type fakeOitalk struct {
	mu            sync.Mutex
	registerCalls []struct{ start, end time.Time }
	registerErrs  []error // 호출 순서대로 소비. 비면 nil(성공).
	listRows      []Reservation
	listErrs      []error // 호출 순서대로 소비. 비면 nil.
	listCalls     int
}

func (f *fakeOitalk) List(context.Context, time.Time, time.Time) ([]Reservation, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.listCalls++
	if len(f.listErrs) > 0 {
		err := f.listErrs[0]
		f.listErrs = f.listErrs[1:]
		if err != nil {
			return nil, err
		}
	}
	return f.listRows, nil
}
func (f *fakeOitalk) Register(_ context.Context, start, end time.Time) (Reservation, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.registerCalls = append(f.registerCalls, struct{ start, end time.Time }{start, end})
	if len(f.registerErrs) > 0 {
		err := f.registerErrs[0]
		f.registerErrs = f.registerErrs[1:]
		if err != nil {
			return Reservation{}, err
		}
	}
	return Reservation{ID: []byte(`"r1"`), State: "ok"}, nil
}
func (f *fakeOitalk) counts() (register, list int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.registerCalls), f.listCalls
}

var testCfg = Config{CarNum: "12가3456"}

// newTestWatcher 2026-09-02 10:00 KST 고정 시계, 재시도 대기 0.
func newTestWatcher(t *testing.T, api API) (*Watcher, *time.Time) {
	t.Helper()
	now := time.Date(2026, 9, 2, 10, 0, 0, 0, KST)
	w := newWatcher(api, testCfg, MQTTConfig{Geofence: "일산"})
	w.now = func() time.Time { return now }
	w.retryDelay = 0
	return w, &now
}

func TestWatcher_LiveTargetRegistersThreeDaysFromToday(t *testing.T) {
	api := &fakeOitalk{}
	w, _ := newTestWatcher(t, api)
	w.HandleGeofence(context.Background(), "일산", false)
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1", len(api.registerCalls))
	}
	got := api.registerCalls[0]
	if FormatISO(got.start) != "2026-09-01T15:00:00.000Z" || FormatISO(got.end) != "2026-09-04T14:59:59.999Z" {
		t.Errorf("window = %s ~ %s", FormatISO(got.start), FormatISO(got.end))
	}
}

func TestWatcher_TrimsPayloadBeforeMatch(t *testing.T) {
	api := &fakeOitalk{}
	w, _ := newTestWatcher(t, api)
	w.HandleGeofence(context.Background(), " 일산 \n", false)
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1", len(api.registerCalls))
	}
}

func TestWatcher_RetainedTargetIsIgnored(t *testing.T) {
	// retained = 구독 시점 보관값 = 이미 안에 있음(재시작·재접속). 진입이 아니다.
	api := &fakeOitalk{}
	w, _ := newTestWatcher(t, api)
	w.HandleGeofence(context.Background(), "일산", true)
	if len(api.registerCalls) != 0 {
		t.Fatalf("register calls = %d, want 0", len(api.registerCalls))
	}
}

func TestWatcher_OtherValuesIgnored(t *testing.T) {
	api := &fakeOitalk{}
	w, _ := newTestWatcher(t, api)
	ctx := context.Background()
	w.HandleGeofence(ctx, "", false)
	w.HandleGeofence(ctx, "다른곳", false)
	w.HandleGeofence(ctx, "일산역", false)
	if len(api.registerCalls) != 0 {
		t.Fatalf("register calls = %d, want 0", len(api.registerCalls))
	}
}

func TestWatcher_CoverageCacheSkipsUntilWindowEnds(t *testing.T) {
	api := &fakeOitalk{}
	w, now := newTestWatcher(t, api)
	ctx := context.Background()
	w.HandleGeofence(ctx, "일산", false) // D → 등록
	*now = now.AddDate(0, 0, 1)
	w.HandleGeofence(ctx, "일산", false) // D+1 → skip
	*now = now.AddDate(0, 0, 1)
	w.HandleGeofence(ctx, "일산", false) // D+2 → skip
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1", len(api.registerCalls))
	}
	*now = now.AddDate(0, 0, 1)
	w.HandleGeofence(ctx, "일산", false) // D+3 → 새 등록
	if len(api.registerCalls) != 2 {
		t.Fatalf("register calls = %d, want 2", len(api.registerCalls))
	}
	if FormatISO(api.registerCalls[1].start) != "2026-09-04T15:00:00.000Z" {
		t.Errorf("second window start = %s", FormatISO(api.registerCalls[1].start))
	}
}

func TestWatcher_RegisterFailureRetriesThenSucceeds(t *testing.T) {
	api := &fakeOitalk{registerErrs: []error{errors.New("boom")}}
	w, _ := newTestWatcher(t, api)
	w.HandleGeofence(context.Background(), "일산", false)
	if len(api.registerCalls) != 2 {
		t.Fatalf("register calls = %d, want 2 (fail → retry → ok)", len(api.registerCalls))
	}
	if api.listCalls != 1 {
		t.Fatalf("list calls = %d, want 1 (verify before retry)", api.listCalls)
	}
}

func TestWatcher_RetryFindsExistingReservationInsteadOfPosting(t *testing.T) {
	// POST 는 서버에 커밋됐는데 응답만 유실 → 재시도 전 목록에서 발견 → 다시 POST 안 함.
	api := &fakeOitalk{
		registerErrs: []error{errors.New("timeout")},
		listRows:     []Reservation{{ID: []byte(`"srv"`), CarNum: "12가3456", StartDate: "20260902", EndDate: "20260904"}},
	}
	w, now := newTestWatcher(t, api)
	ctx := context.Background()
	w.HandleGeofence(ctx, "일산", false)
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1", len(api.registerCalls))
	}
	*now = now.AddDate(0, 0, 2)
	w.HandleGeofence(ctx, "일산", false) // 목록에서 찾은 커버리지가 캐시에 반영
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1 (coverage seeded from list)", len(api.registerCalls))
	}
}

func TestWatcher_RetrySkipsPostWhenListFails(t *testing.T) {
	// 확인 불가면 그 회차는 POST 하지 않는다(중복 위험). 다음 회차에 목록 OK → POST.
	api := &fakeOitalk{
		registerErrs: []error{errors.New("timeout")},
		listErrs:     []error{errors.New("down"), nil},
	}
	w, _ := newTestWatcher(t, api)
	w.HandleGeofence(context.Background(), "일산", false)
	if len(api.registerCalls) != 2 {
		t.Fatalf("register calls = %d, want 2 (attempt2 skipped, attempt3 posted)", len(api.registerCalls))
	}
	if api.listCalls != 2 {
		t.Fatalf("list calls = %d, want 2", api.listCalls)
	}
}

func TestWatcher_RetryGivesUpAfterMaxAttempts(t *testing.T) {
	errs := make([]error, maxRegisterAttempts) // 첫 진입의 시도 전부 실패, 그 뒤엔 성공
	for i := range errs {
		errs[i] = errors.New("boom")
	}
	api := &fakeOitalk{registerErrs: errs}
	w, _ := newTestWatcher(t, api)
	w.HandleGeofence(context.Background(), "일산", false)
	if len(api.registerCalls) != maxRegisterAttempts {
		t.Fatalf("register calls = %d, want %d", len(api.registerCalls), maxRegisterAttempts)
	}
	// 포기 후 캐시는 비어 있어 다음 진입에 다시 시도
	w.HandleGeofence(context.Background(), "일산", false)
	if len(api.registerCalls) != maxRegisterAttempts+1 {
		t.Fatalf("register calls = %d, want %d", len(api.registerCalls), maxRegisterAttempts+1)
	}
}

func TestWatcher_RetryStopsOnContextCancel(t *testing.T) {
	api := &fakeOitalk{registerErrs: []error{errors.New("boom"), errors.New("boom")}}
	w, _ := newTestWatcher(t, api)
	w.retryDelay = time.Hour
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		w.HandleGeofence(ctx, "일산", false)
		close(done)
	}()
	time.Sleep(10 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("HandleGeofence must return promptly after ctx cancel")
	}
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1", len(api.registerCalls))
	}
}

func TestWatcher_BootstrapSeedsCoverageFromList(t *testing.T) {
	api := &fakeOitalk{listRows: []Reservation{
		{ID: []byte(`"x"`), CarNum: "12가3456", StartDate: "20260901", EndDate: "20260903", State: "ok"},
		{ID: []byte(`"y"`), CarNum: "99하9999", StartDate: "20260901", EndDate: "20260930", State: "ok"}, // 다른 차량
	}}
	w, now := newTestWatcher(t, api)
	ctx := context.Background()
	w.Bootstrap(ctx)
	w.HandleGeofence(ctx, "일산", false) // 9/2 — 9/3 까지 커버됨
	*now = now.AddDate(0, 0, 1)
	w.HandleGeofence(ctx, "일산", false) // 9/3 — 커버됨
	if len(api.registerCalls) != 0 {
		t.Fatalf("register calls = %d, want 0", len(api.registerCalls))
	}
	*now = now.AddDate(0, 0, 1)
	w.HandleGeofence(ctx, "일산", false) // 9/4 — 새 등록
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1", len(api.registerCalls))
	}
}

func TestWatcher_BootstrapIgnoresGapCoverage(t *testing.T) {
	// 오늘(9/2)은 비고 9/4 만 커버된 행 → 오늘 진입 시 등록해야 한다.
	api := &fakeOitalk{listRows: []Reservation{
		{ID: []byte(`"x"`), CarNum: "12가3456", StartDate: "20260904", EndDate: "20260904"},
	}}
	w, _ := newTestWatcher(t, api)
	ctx := context.Background()
	w.Bootstrap(ctx)
	w.HandleGeofence(ctx, "일산", false)
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1", len(api.registerCalls))
	}
}

func TestWatcher_BootstrapListFailureLeavesCacheEmpty(t *testing.T) {
	api := &fakeOitalk{listErrs: []error{errors.New("down")}}
	w, _ := newTestWatcher(t, api)
	ctx := context.Background()
	w.Bootstrap(ctx)
	w.HandleGeofence(ctx, "일산", false)
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1", len(api.registerCalls))
	}
}

// blockingList List 가 release 될 때까지 막힌다 — 부트스트랩 중 진입 검증용.
type blockingList struct {
	fakeOitalk
	release chan struct{}
	entered chan struct{}
}

func (b *blockingList) List(ctx context.Context, s, e time.Time) ([]Reservation, error) {
	b.entered <- struct{}{}
	<-b.release
	return b.fakeOitalk.List(ctx, s, e)
}

func runBootstrapEntry(t *testing.T, api *blockingList) {
	t.Helper()
	w, _ := newTestWatcher(t, api)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- w.runWith(ctx, func(context.Context) (func(), error) { return func() {}, nil })
	}()
	<-api.entered // 부트스트랩 목록 조회 진행 중 — 이 사이 진입
	handled := make(chan struct{})
	go func() {
		w.HandleGeofence(ctx, "일산", false)
		close(handled)
	}()
	select {
	case <-handled:
		t.Fatal("entry must wait until bootstrap seed completes")
	case <-time.After(20 * time.Millisecond):
	}
	if reg, _ := api.counts(); reg != 0 {
		t.Fatalf("must not register before seed, got %d", reg)
	}
	close(api.release)
	select {
	case <-handled:
	case <-time.After(time.Second):
		t.Fatal("entry not processed after seed")
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("runWith: %v", err)
	}
}

func TestWatcher_EntryDuringBootstrapRegistersAfterSeed(t *testing.T) {
	api := &blockingList{release: make(chan struct{}), entered: make(chan struct{}, 1)}
	runBootstrapEntry(t, api)
	if reg, _ := api.counts(); reg != 1 {
		t.Fatalf("register calls = %d, want 1", reg)
	}
}

func TestWatcher_EntryDuringBootstrapSkippedWhenSeedCoversToday(t *testing.T) {
	api := &blockingList{release: make(chan struct{}), entered: make(chan struct{}, 1)}
	api.listRows = []Reservation{{ID: []byte(`"x"`), CarNum: "12가3456", StartDate: "20260902", EndDate: "20260904"}}
	runBootstrapEntry(t, api)
	if reg, _ := api.counts(); reg != 0 {
		t.Fatalf("register calls = %d, want 0 (seed covers today)", reg)
	}
}

func TestWatcher_RunWithReturnsSubscribeError(t *testing.T) {
	api := &fakeOitalk{}
	w, _ := newTestWatcher(t, api)
	err := w.runWith(context.Background(), func(context.Context) (func(), error) {
		return nil, errors.New("connect refused")
	})
	if err == nil {
		t.Fatal("expected error")
	}
	if api.listCalls != 0 {
		t.Fatalf("bootstrap must not run when subscribe fails, list calls = %d", api.listCalls)
	}
}
