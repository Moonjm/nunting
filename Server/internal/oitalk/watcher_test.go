package oitalk

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// fakeOitalk 워커 goroutine 에서도 호출되므로 mutex 로 보호. 순차 테스트는 필드를
// 직접 읽어도 되지만 동시 테스트는 counts() 를 쓴다.
type fakeOitalk struct {
	mu            sync.Mutex
	registerCalls []struct{ start, end time.Time }
	registerErr   error
	listRows      []Reservation
	listErr       error
	listCalls     int
	ensureCalls   int
}

func (f *fakeOitalk) EnsureToken(context.Context) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ensureCalls++
	return "tok", nil
}
func (f *fakeOitalk) List(context.Context, time.Time, time.Time) ([]Reservation, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.listCalls++
	return f.listRows, f.listErr
}
func (f *fakeOitalk) Register(_ context.Context, start, end time.Time) (Reservation, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.registerCalls = append(f.registerCalls, struct{ start, end time.Time }{start, end})
	if f.registerErr != nil {
		return Reservation{}, f.registerErr
	}
	return Reservation{ID: "r1", State: "ok"}, nil
}
func (f *fakeOitalk) setRegisterErr(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.registerErr = err
}
func (f *fakeOitalk) counts() (register, ensure int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.registerCalls), f.ensureCalls
}

var testCfg = Config{CarNum: "12가3456", CoverageDays: 3}

// newTestWatcher 2026-09-02 10:00 KST 고정 시계, baseline 은 "밖"(빈 값)으로 잡힌 상태.
func newTestWatcher(t *testing.T, api *fakeOitalk) (*Watcher, *time.Time) {
	t.Helper()
	now := time.Date(2026, 9, 2, 10, 0, 0, 0, KST)
	w := newWatcher(api, testCfg, MQTTConfig{Geofence: "일산"})
	w.now = func() time.Time { return now }
	w.HandleGeofence(context.Background(), "", true) // retained baseline
	return w, &now
}

func TestWatcher_RisingEdgeRegistersThreeDaysFromToday(t *testing.T) {
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

func TestWatcher_NonRisingTransitionsDoNothing(t *testing.T) {
	api := &fakeOitalk{}
	w, _ := newTestWatcher(t, api)
	ctx := context.Background()
	w.HandleGeofence(ctx, "", false)    // 밖→밖
	w.HandleGeofence(ctx, "다른곳", false) // 밖→다른 지오펜스
	w.HandleGeofence(ctx, "", false)    // 다른곳→밖
	if len(api.registerCalls) != 0 {
		t.Fatalf("register calls = %d, want 0", len(api.registerCalls))
	}
	w.HandleGeofence(ctx, "일산", false) // 진입 1회
	w.HandleGeofence(ctx, "일산", false) // 집→집 (retained 재수신 등)
	w.HandleGeofence(ctx, "", false)   // 집→밖
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1", len(api.registerCalls))
	}
}

func TestWatcher_FirstValueIsBaselineOnly(t *testing.T) {
	api := &fakeOitalk{}
	w := newWatcher(api, testCfg, MQTTConfig{Geofence: "일산"})
	w.now = func() time.Time { return time.Date(2026, 9, 2, 10, 0, 0, 0, KST) }
	ctx := context.Background()
	w.HandleGeofence(ctx, "일산", true) // 재시작 직후 retained "집" — 이미 주차 중
	if len(api.registerCalls) != 0 {
		t.Fatalf("baseline must not register, got %d", len(api.registerCalls))
	}
	w.HandleGeofence(ctx, "", false)
	w.HandleGeofence(ctx, "일산", false)
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1", len(api.registerCalls))
	}
}

func TestWatcher_CoverageCacheSkipsUntilWindowEnds(t *testing.T) {
	api := &fakeOitalk{}
	w, now := newTestWatcher(t, api)
	ctx := context.Background()
	enter := func() {
		w.HandleGeofence(ctx, "", false)
		w.HandleGeofence(ctx, "일산", false)
	}
	enter() // D → 등록
	*now = now.AddDate(0, 0, 1)
	enter() // D+1 → skip
	*now = now.AddDate(0, 0, 1)
	enter() // D+2 → skip
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1 (D+1, D+2 covered)", len(api.registerCalls))
	}
	*now = now.AddDate(0, 0, 1)
	enter() // D+3 → 새 등록
	if len(api.registerCalls) != 2 {
		t.Fatalf("register calls = %d, want 2", len(api.registerCalls))
	}
	if FormatISO(api.registerCalls[1].start) != "2026-09-04T15:00:00.000Z" {
		t.Errorf("second window start = %s", FormatISO(api.registerCalls[1].start))
	}
}

func TestWatcher_RegisterFailureDoesNotCacheCoverage(t *testing.T) {
	api := &fakeOitalk{registerErr: errors.New("boom")}
	w, _ := newTestWatcher(t, api)
	ctx := context.Background()
	w.HandleGeofence(ctx, "일산", false)
	api.registerErr = nil
	w.HandleGeofence(ctx, "", false)
	w.HandleGeofence(ctx, "일산", false)
	if len(api.registerCalls) != 2 {
		t.Fatalf("register calls = %d, want 2 (retry after failure)", len(api.registerCalls))
	}
}

func TestWatcher_BootstrapSeedsCoverageFromList(t *testing.T) {
	api := &fakeOitalk{listRows: []Reservation{
		{ID: "x", CarNum: "12가3456", StartDate: "20260901", EndDate: "20260903", State: "ok"},
		{ID: "y", CarNum: "99하9999", StartDate: "20260901", EndDate: "20260930", State: "ok"}, // 다른 차량
	}}
	w, now := newTestWatcher(t, api)
	ctx := context.Background()
	w.Bootstrap(ctx)
	w.HandleGeofence(ctx, "일산", false) // 9/2 — 9/3 까지 커버됨
	*now = now.AddDate(0, 0, 1)
	w.HandleGeofence(ctx, "", false)
	w.HandleGeofence(ctx, "일산", false) // 9/3 — 커버됨
	if len(api.registerCalls) != 0 {
		t.Fatalf("register calls = %d, want 0", len(api.registerCalls))
	}
	*now = now.AddDate(0, 0, 1)
	w.HandleGeofence(ctx, "", false)
	w.HandleGeofence(ctx, "일산", false) // 9/4 — 새 등록
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1", len(api.registerCalls))
	}
}

func TestWatcher_BootstrapIgnoresGapCoverage(t *testing.T) {
	// 오늘(9/2)은 비고 9/4 만 커버된 행 → 오늘 진입 시 등록해야 한다.
	api := &fakeOitalk{listRows: []Reservation{
		{ID: "x", CarNum: "12가3456", StartDate: "20260904", EndDate: "20260904", State: "ok"},
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
	api := &fakeOitalk{listErr: errors.New("down")}
	w, _ := newTestWatcher(t, api)
	ctx := context.Background()
	w.Bootstrap(ctx)
	w.HandleGeofence(ctx, "일산", false)
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1", len(api.registerCalls))
	}
}

func TestWatcher_DrivingStatePrewarmsToken(t *testing.T) {
	api := &fakeOitalk{}
	w, _ := newTestWatcher(t, api)
	ctx := context.Background()
	w.HandleState(ctx, "online")
	if api.ensureCalls != 0 {
		t.Fatalf("online must not prewarm, got %d", api.ensureCalls)
	}
	w.HandleState(ctx, "driving")
	w.HandleState(ctx, "driving") // 같은 상태 반복 → 재호출 안 함
	if api.ensureCalls != 1 {
		t.Fatalf("ensure calls = %d, want 1", api.ensureCalls)
	}
	w.HandleState(ctx, "online")
	w.HandleState(ctx, "driving")
	if api.ensureCalls != 2 {
		t.Fatalf("ensure calls = %d, want 2", api.ensureCalls)
	}
}

func TestWatcher_InvalidCoverageDaysRefusesRegister(t *testing.T) {
	api := &fakeOitalk{}
	cfg := testCfg
	cfg.CoverageDays = 4
	w := newWatcher(api, cfg, MQTTConfig{Geofence: "일산"})
	w.now = func() time.Time { return time.Date(2026, 9, 2, 10, 0, 0, 0, KST) }
	ctx := context.Background()
	w.HandleGeofence(ctx, "", false)
	w.HandleGeofence(ctx, "일산", false)
	if len(api.registerCalls) != 0 {
		t.Fatalf("register calls = %d, want 0", len(api.registerCalls))
	}
}

func TestWatcher_FirstLiveMessageIsRealEntry(t *testing.T) {
	// 차가 밖에 있어 retained 값이 없는 상태로 시작 → 첫 메시지(live "일산")는 진입이다.
	api := &fakeOitalk{}
	w := newWatcher(api, testCfg, MQTTConfig{Geofence: "일산"})
	w.now = func() time.Time { return time.Date(2026, 9, 2, 10, 0, 0, 0, KST) }
	w.HandleGeofence(context.Background(), "일산", false)
	if len(api.registerCalls) != 1 {
		t.Fatalf("first live entry must register, got %d", len(api.registerCalls))
	}
}

// blockingOitalk Register 가 release 될 때까지 막힌다 — 콜백 비블로킹 검증용.
type blockingOitalk struct {
	fakeOitalk
	release chan struct{}
	entered chan struct{}
}

func (b *blockingOitalk) Register(ctx context.Context, start, end time.Time) (Reservation, error) {
	b.entered <- struct{}{}
	<-b.release
	return b.fakeOitalk.Register(ctx, start, end)
}

func TestWatcher_EnqueueDoesNotBlockWhileRegisterInFlight(t *testing.T) {
	api := &blockingOitalk{release: make(chan struct{}), entered: make(chan struct{}, 1)}
	w := newWatcher(api, testCfg, MQTTConfig{Geofence: "일산"})
	w.now = func() time.Time { return time.Date(2026, 9, 2, 10, 0, 0, 0, KST) }
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() { w.serve(ctx); close(done) }()

	w.enqueue(ctx, "teslamate/cars/1/geofence", "", true)
	w.enqueue(ctx, "teslamate/cars/1/geofence", "일산", false)
	<-api.entered // Register 진행 중

	// 진행 중에도 enqueue 는 즉시 돌아와야 한다(paho 콜백을 막지 않는다).
	returned := make(chan struct{})
	go func() {
		w.enqueue(ctx, "teslamate/cars/1/state", "online", false)
		close(returned)
	}()
	select {
	case <-returned:
	case <-time.After(time.Second):
		t.Fatal("enqueue blocked while Register in flight")
	}
	close(api.release)
	cancel()
	<-done
	if reg, _ := api.counts(); reg != 1 {
		t.Fatalf("register calls = %d, want 1", reg)
	}
}

func TestWatcher_ServeProcessesInOrder(t *testing.T) {
	api := &fakeOitalk{}
	w := newWatcher(api, testCfg, MQTTConfig{Geofence: "일산"})
	w.now = func() time.Time { return time.Date(2026, 9, 2, 10, 0, 0, 0, KST) }
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { w.serve(ctx); close(done) }()
	// retained baseline "집" → 밖 → 집: 순서대로면 정확히 1회 등록.
	w.enqueue(ctx, "teslamate/cars/1/geofence", "일산", true)
	w.enqueue(ctx, "teslamate/cars/1/geofence", "", false)
	w.enqueue(ctx, "teslamate/cars/1/geofence", "일산", false)
	w.enqueue(ctx, "teslamate/cars/1/state", "driving", false)
	deadline := time.After(2 * time.Second)
	for {
		reg, ens := api.counts()
		if reg >= 1 && ens >= 1 {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("timeout: register=%d ensure=%d", reg, ens)
		case <-time.After(5 * time.Millisecond):
		}
	}
	cancel()
	<-done
	if reg, _ := api.counts(); reg != 1 {
		t.Fatalf("register calls = %d, want 1", reg)
	}
}

func TestWatcher_RetryAfterFailureRegistersWithoutReentry(t *testing.T) {
	api := &fakeOitalk{registerErr: errors.New("boom")}
	w, _ := newTestWatcher(t, api)
	ctx := context.Background()
	w.HandleGeofence(ctx, "일산", false) // 진입, 실패
	api.registerErr = nil
	w.HandleRetry(ctx, w.entryGen) // 재진입 없이 재시도 → 성공
	if len(api.registerCalls) != 2 {
		t.Fatalf("register calls = %d, want 2", len(api.registerCalls))
	}
	w.HandleRetry(ctx, w.entryGen) // 성공 후 남은 재시도 이벤트는 무동작
	if len(api.registerCalls) != 2 {
		t.Fatalf("register calls after success = %d, want 2", len(api.registerCalls))
	}
}

func TestWatcher_RetryStopsAfterExit(t *testing.T) {
	api := &fakeOitalk{registerErr: errors.New("boom")}
	w, _ := newTestWatcher(t, api)
	ctx := context.Background()
	w.HandleGeofence(ctx, "일산", false) // 진입, 실패
	w.HandleGeofence(ctx, "", false)   // 나감
	api.registerErr = nil
	w.HandleRetry(ctx, w.entryGen)
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1 (no retry after exit)", len(api.registerCalls))
	}
}

func TestWatcher_RetryGivesUpAfterMaxAttempts(t *testing.T) {
	api := &fakeOitalk{registerErr: errors.New("boom")}
	w, _ := newTestWatcher(t, api)
	ctx := context.Background()
	w.HandleGeofence(ctx, "일산", false)
	for i := 0; i < maxRegisterRetries+5; i++ {
		w.HandleRetry(ctx, w.entryGen)
	}
	if len(api.registerCalls) != 1+maxRegisterRetries {
		t.Fatalf("register calls = %d, want %d", len(api.registerCalls), 1+maxRegisterRetries)
	}
}

func TestWatcher_RetryIsScheduledThroughWorker(t *testing.T) {
	api := &fakeOitalk{registerErr: errors.New("boom")}
	w := newWatcher(api, testCfg, MQTTConfig{Geofence: "일산"})
	w.now = func() time.Time { return time.Date(2026, 9, 2, 10, 0, 0, 0, KST) }
	w.retryDelay = 5 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { w.serve(ctx); close(done) }()
	w.enqueue(ctx, "teslamate/cars/1/geofence", "", true)
	w.enqueue(ctx, "teslamate/cars/1/geofence", "일산", false)
	deadline := time.After(2 * time.Second)
	for {
		if reg, _ := api.counts(); reg >= 1 {
			break
		}
		select {
		case <-deadline:
			t.Fatal("timeout waiting first register")
		case <-time.After(time.Millisecond):
		}
	}
	api.setRegisterErr(nil)
	for {
		if reg, _ := api.counts(); reg >= 2 {
			break
		}
		select {
		case <-deadline:
			t.Fatal("timeout waiting scheduled retry")
		case <-time.After(time.Millisecond):
		}
	}
	cancel()
	<-done
}

func TestWatcher_RetryFindsExistingReservationInsteadOfPosting(t *testing.T) {
	// POST 가 서버엔 커밋됐는데 응답만 유실된 경우 — 재시도 전 목록으로 확인해 중복 POST 방지.
	api := &fakeOitalk{registerErr: errors.New("timeout")}
	w, now := newTestWatcher(t, api)
	ctx := context.Background()
	w.HandleGeofence(ctx, "일산", false) // 진입, 실패(모호)
	api.listRows = []Reservation{{ID: "srv", CarNum: "12가3456", StartDate: "20260902", EndDate: "20260904", State: "ok"}}
	api.registerErr = nil
	w.HandleRetry(ctx, w.entryGen)
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1 (existing reservation found)", len(api.registerCalls))
	}
	if api.listCalls != 1 {
		t.Fatalf("list calls = %d, want 1", api.listCalls)
	}
	// 목록에서 찾은 커버리지가 캐시에 반영돼 다음날 진입도 skip
	*now = now.AddDate(0, 0, 1)
	w.HandleGeofence(ctx, "", false)
	w.HandleGeofence(ctx, "일산", false)
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1 (coverage seeded from list)", len(api.registerCalls))
	}
}

func TestWatcher_RetryDefersWhenListFails(t *testing.T) {
	api := &fakeOitalk{registerErr: errors.New("timeout")}
	w, _ := newTestWatcher(t, api)
	ctx := context.Background()
	w.HandleGeofence(ctx, "일산", false)
	api.listErr = errors.New("down")
	api.registerErr = nil
	w.HandleRetry(ctx, w.entryGen) // 확인 불가 → POST 하지 않고 다음 재시도로
	if len(api.registerCalls) != 1 {
		t.Fatalf("register calls = %d, want 1 (must not POST blindly)", len(api.registerCalls))
	}
	api.listErr = nil
	w.HandleRetry(ctx, w.entryGen) // 목록 OK(비어 있음) → 등록
	if len(api.registerCalls) != 2 {
		t.Fatalf("register calls = %d, want 2", len(api.registerCalls))
	}
}

func TestWatcher_StaleRetryFromPreviousEntryIgnored(t *testing.T) {
	api := &fakeOitalk{registerErr: errors.New("boom")}
	w, _ := newTestWatcher(t, api)
	ctx := context.Background()
	w.HandleGeofence(ctx, "일산", false) // 진입 1(실패)
	oldGen := w.entryGen
	w.HandleGeofence(ctx, "", false)
	w.HandleGeofence(ctx, "일산", false) // 진입 2(실패)
	if w.entryGen == oldGen {
		t.Fatal("entry generation must advance on re-entry")
	}
	api.registerErr = nil
	w.HandleRetry(ctx, oldGen) // 이전 진입의 타이머 → 무시
	if len(api.registerCalls) != 2 {
		t.Fatalf("register calls = %d, want 2 (stale retry ignored)", len(api.registerCalls))
	}
	w.HandleRetry(ctx, w.entryGen)
	if len(api.registerCalls) != 3 {
		t.Fatalf("register calls = %d, want 3", len(api.registerCalls))
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

func TestWatcher_EntryDuringBootstrapIsProcessedAfterSeed(t *testing.T) {
	// 부트스트랩(목록 조회)이 느린 동안 차가 진입: 구독은 이미 돼 있어 이벤트가
	// 큐에 잡히고, 캐시 seed 가 끝난 뒤 순서대로 처리돼 등록된다.
	api := &blockingList{release: make(chan struct{}), entered: make(chan struct{}, 1)}
	w := newWatcher(api, testCfg, MQTTConfig{Geofence: "일산"})
	w.now = func() time.Time { return time.Date(2026, 9, 2, 10, 0, 0, 0, KST) }
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	subscribed := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		done <- w.runWith(ctx, func(ctx context.Context) (func(), error) {
			close(subscribed)
			return func() {}, nil
		})
	}()
	<-subscribed
	<-api.entered // 부트스트랩 목록 조회 진행 중 — 이 사이 진입
	w.enqueue(ctx, "teslamate/cars/1/geofence", "", true)
	w.enqueue(ctx, "teslamate/cars/1/geofence", "일산", false)
	if reg, _ := api.counts(); reg != 0 {
		t.Fatalf("must not process before seed, got %d", reg)
	}
	close(api.release)
	deadline := time.After(2 * time.Second)
	for {
		if reg, _ := api.counts(); reg == 1 {
			break
		}
		select {
		case <-deadline:
			reg, _ := api.counts()
			t.Fatalf("register calls = %d, want 1", reg)
		case <-time.After(time.Millisecond):
		}
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("runWith: %v", err)
	}
}

func TestWatcher_EntryDuringBootstrapSkippedWhenSeedCoversToday(t *testing.T) {
	api := &blockingList{release: make(chan struct{}), entered: make(chan struct{}, 1)}
	api.listRows = []Reservation{{ID: "x", CarNum: "12가3456", StartDate: "20260902", EndDate: "20260904"}}
	w := newWatcher(api, testCfg, MQTTConfig{Geofence: "일산"})
	w.now = func() time.Time { return time.Date(2026, 9, 2, 10, 0, 0, 0, KST) }
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- w.runWith(ctx, func(context.Context) (func(), error) { return func() {}, nil })
	}()
	<-api.entered
	w.enqueue(ctx, "teslamate/cars/1/geofence", "", true)
	w.enqueue(ctx, "teslamate/cars/1/geofence", "일산", false)
	close(api.release)
	time.Sleep(50 * time.Millisecond)
	cancel()
	<-done
	if reg, _ := api.counts(); reg != 0 {
		t.Fatalf("register calls = %d, want 0 (seed covers today)", reg)
	}
}

func TestWatcher_RunWithReturnsSubscribeError(t *testing.T) {
	api := &fakeOitalk{}
	w := newWatcher(api, testCfg, MQTTConfig{Geofence: "일산"})
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
