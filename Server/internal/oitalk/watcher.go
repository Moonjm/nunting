package oitalk

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	mqtt "github.com/eclipse/paho.mqtt.golang"
)

const (
	topicGeofence = "teslamate/cars/+/geofence"
	topicState    = "teslamate/cars/+/state"

	// apiTimeout 진입 hot-path 의 등록·목록 호출 상한.
	apiTimeout = 15 * time.Second
	// tokenWarmInterval 저빈도 토큰 프리워밍 주기(driving 엣지와 별개 백스톱).
	tokenWarmInterval = time.Hour
	// 등록 실패 재시도: 최대 maxRegisterAttempts 회, 사이에 defaultRetryDelay.
	maxRegisterAttempts = 3
	defaultRetryDelay   = 10 * time.Second
)

// API watcher 가 쓰는 오이톡 클라이언트 표면. 테스트에서 fake 로 대체.
type API interface {
	EnsureToken(ctx context.Context) (string, error)
	List(ctx context.Context, start, end time.Time) ([]Reservation, error)
	Register(ctx context.Context, start, end time.Time) (Reservation, error)
}

// Watcher TeslaMate MQTT 지오펜스를 구독해 진입 순간 방문차량을 등록한다.
//
// 판정은 MQTT 의 retained 플래그 하나로 끝난다. TeslaMate 는 값이 바뀔 때만
// publish 하고, 브로커는 구독 직후 보관값을 줄 때만 retained 를 켠다. 따라서
//
//	retained "일산" = 구독 시점에 이미 안에 있음(재시작·재접속) → 무시
//	live     "일산" = 방금 들어옴                              → 등록
//
// 직전값을 기억하지 않으므로 재시작·재접속·끊김에 오염될 상태가 없다.
// 멱등성은 메모리 커버리지 캐시(coveredUntil)로 — 등록 1건이 3일을 덮으니
// 대부분의 진입은 네트워크 없이 여기서 끝난다. 재시작 시 Bootstrap 이 오이톡
// 목록으로 캐시를 seed 한다.
//
// 알려진 한계: TeslaMate 자체가 재시작되면 현재값을 live 로 다시 publish 할 수
// 있다. 차가 3일 넘게 주차돼 캐시가 만료된 상태에서 그게 겹치면 방문차량 1건이
// 헛되이 등록된다(로그 oitalk_registered 로 드러남). 드물고 피해가 작아 수용.
//
// 차 1대 전제 — 토픽 와일드카드(+)로 받지만 상태는 차량별로 나누지 않는다.
type Watcher struct {
	api        API
	cfg        Config
	mqttCfg    MQTTConfig
	now        func() time.Time
	retryDelay time.Duration

	// mu 는 핸들러를 직렬화하고, Bootstrap 동안 잡혀 있어 그 사이 온 진입이
	// seed 가 끝난 뒤 처리되게 한다.
	mu           sync.Mutex
	coveredUntil time.Time // 이 날짜(KST 자정)까지 등록됨. zero 면 미상.
}

// NewWatcher main.go 배선용.
func NewWatcher(client *Client, m MQTTConfig) *Watcher {
	return newWatcher(client, client.Config(), m)
}

func newWatcher(api API, cfg Config, m MQTTConfig) *Watcher {
	return &Watcher{api: api, cfg: cfg, mqttCfg: m, now: time.Now, retryDelay: defaultRetryDelay}
}

// Bootstrap 오이톡 목록으로 오늘 기준 커버리지를 1회 조회해 캐시를 seed 한다.
// 실패해도 치명적이지 않다 — 캐시가 비면 다음 진입에 등록을 시도할 뿐이다.
func (w *Watcher) Bootstrap(ctx context.Context) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.bootstrapLocked(ctx)
}

func (w *Watcher) bootstrapLocked(ctx context.Context) {
	today := DayOf(w.now())
	start, end, err := CoverageWindow(today, MaxCoverageDays)
	if err != nil {
		return
	}
	t0 := time.Now()
	lctx, cancel := context.WithTimeout(ctx, apiTimeout)
	rows, err := w.api.List(lctx, start, end)
	cancel()
	if err != nil {
		slog.Warn("oitalk_bootstrap_list_failed", "err", err, "elapsed_ms", ms(t0))
		return
	}
	w.coveredUntil = coverageEnd(rows, w.cfg.CarNum, today)
	slog.Info("oitalk_bootstrap", "today", ymd(today), "covered_until", ymd(w.coveredUntil),
		"rows", len(rows), "car_rows", countCar(rows, w.cfg.CarNum), "elapsed_ms", ms(t0))
}

// HandleGeofence MQTT geofence 페이로드 1건 처리(hot-path).
func (w *Watcher) HandleGeofence(ctx context.Context, payload string, retained bool) {
	value := strings.TrimSpace(payload)
	target := w.mqttCfg.Geofence
	switch {
	case value != target:
		slog.Info("oitalk_geofence", "value", value, "retained", retained, "action", "ignore_other")
		return
	case retained:
		slog.Info("oitalk_geofence", "value", value, "retained", true, "action", "ignore_retained",
			"reason", "구독 시점 보관값 — 이미 안에 있음")
		return
	}
	slog.Info("oitalk_geofence", "value", value, "retained", false, "action", "entry")

	w.mu.Lock()
	defer w.mu.Unlock()
	w.registerLocked(ctx)
}

// registerLocked 오늘 기준 커버리지 확인 후 등록. 실패하면 같은 자리에서 재시도.
// 재시도 전엔 목록으로 먼저 확인한다 — 실패한 POST 가 서버엔 커밋됐는데 응답만
// 유실됐을 수 있고, 등록은 비멱등이라 그대로 다시 쏘면 중복 예약 + 월 주차한도
// 소모. 목록 조회마저 실패한 회차는 POST 를 건너뛴다. mu 보유 전제.
func (w *Watcher) registerLocked(ctx context.Context) {
	today := DayOf(w.now())
	if !w.coveredUntil.IsZero() && !today.After(w.coveredUntil) {
		slog.Info("oitalk_entry_covered", "today", ymd(today), "covered_until", ymd(w.coveredUntil))
		return
	}
	start, end, err := CoverageWindow(today, w.cfg.CoverageDays)
	if err != nil {
		slog.Error("oitalk_register_skipped", "err", err, "coverage_days", w.cfg.CoverageDays)
		return
	}

	for attempt := 1; attempt <= maxRegisterAttempts; attempt++ {
		if attempt > 1 {
			if !sleepCtx(ctx, w.retryDelay) {
				slog.Warn("oitalk_register_aborted", "reason", "context cancelled", "attempt", attempt)
				return
			}
			if found, ok := w.verifyExistingLocked(ctx, today); !ok {
				continue // 확인 불가 → 이 회차 POST 생략
			} else if found {
				return
			}
		}
		t0 := time.Now()
		rctx, cancel := context.WithTimeout(ctx, apiTimeout)
		row, err := w.api.Register(rctx, start, end)
		cancel()
		if err != nil {
			slog.Error("oitalk_register_failed", "attempt", attempt, "max", maxRegisterAttempts,
				"err", err, "elapsed_ms", ms(t0), "start_date", ymd(start), "end_date", ymd(DayOf(end)))
			continue
		}
		w.coveredUntil = DayOf(end)
		slog.Info("oitalk_registered", "attempt", attempt, "id", string(row.ID), "state", row.State,
			"car_num", row.CarNum, "start_date", ymd(start), "end_date", ymd(w.coveredUntil), "elapsed_ms", ms(t0))
		return
	}
	slog.Error("oitalk_register_gave_up", "attempts", maxRegisterAttempts,
		"hint", "다음 진입 때 다시 시도함. 오이톡 앱에서 수동 등록 필요할 수 있음")
}

// verifyExistingLocked 재시도 전 목록 확인. found=이미 커버됨(캐시 반영), ok=조회 성공.
func (w *Watcher) verifyExistingLocked(ctx context.Context, today time.Time) (found, ok bool) {
	start, end, _ := CoverageWindow(today, MaxCoverageDays)
	t0 := time.Now()
	lctx, cancel := context.WithTimeout(ctx, apiTimeout)
	rows, err := w.api.List(lctx, start, end)
	cancel()
	if err != nil {
		slog.Warn("oitalk_retry_verify_failed", "err", err, "elapsed_ms", ms(t0),
			"action", "skip_post_this_attempt")
		return false, false
	}
	until := coverageEnd(rows, w.cfg.CarNum, today)
	if until.IsZero() {
		slog.Info("oitalk_retry_verify", "existing", false, "rows", len(rows), "elapsed_ms", ms(t0))
		return false, true
	}
	w.coveredUntil = until
	slog.Info("oitalk_retry_verify", "existing", true, "covered_until", ymd(until),
		"reason", "이전 POST 가 서버에 반영돼 있었음", "elapsed_ms", ms(t0))
	return true, true
}

// HandleState 차량 state 페이로드. driving 이면 토큰을 미리 데워 진입 순간엔
// register POST 한 방만 나가게 한다.
func (w *Watcher) HandleState(ctx context.Context, payload string) {
	value := strings.TrimSpace(payload)
	slog.Info("oitalk_state", "value", value)
	if value != "driving" {
		return
	}
	t0 := time.Now()
	if _, err := w.api.EnsureToken(ctx); err != nil {
		slog.Warn("oitalk_token_prewarm_failed", "trigger", "driving", "err", err, "elapsed_ms", ms(t0))
		return
	}
	slog.Info("oitalk_token_prewarm", "trigger", "driving", "elapsed_ms", ms(t0))
}

// Run 브로커 접속 + 구독 후 ctx 취소까지 유지.
func (w *Watcher) Run(ctx context.Context) error {
	return w.runWith(ctx, w.connectMQTT)
}

// runWith 기동 순서: mu 잠금 → 구독 → 부트스트랩(seed) → mu 해제. 구독이 먼저라
// 부트스트랩 중 진입도 콜백에 잡히고, 콜백은 mu 에서 기다리다 seed 뒤에 처리된다.
func (w *Watcher) runWith(ctx context.Context, subscribe func(context.Context) (func(), error)) error {
	w.mu.Lock()
	closeFn, err := subscribe(ctx)
	if err != nil {
		w.mu.Unlock()
		return err
	}
	defer closeFn()
	w.bootstrapLocked(ctx)
	w.mu.Unlock()
	slog.Info("oitalk_watcher_ready", "geofence", w.mqttCfg.Geofence, "coverage_days", w.cfg.CoverageDays)

	ticker := time.NewTicker(tokenWarmInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			slog.Info("oitalk_watcher_stopped")
			return nil
		case <-ticker.C:
			t0 := time.Now()
			if _, err := w.api.EnsureToken(ctx); err != nil {
				slog.Warn("oitalk_token_prewarm_failed", "trigger", "timer", "err", err, "elapsed_ms", ms(t0))
			}
		}
	}
}

// connectMQTT paho 접속 + 구독. 최초 구독이 끝날 때까지 기다렸다 돌아온다
// (OnConnect 는 별도 goroutine 이라 Connect() 완료 ≠ 구독 완료). 재접속 시에도
// OnConnect 가 다시 불려 재구독된다. 콜백은 goroutine 으로 돌려(OrderMatters=false)
// 핸들러가 mu 나 HTTP 에서 기다려도 paho 수신 루프를 막지 않는다.
func (w *Watcher) connectMQTT(ctx context.Context) (func(), error) {
	firstSub := make(chan error, 1)
	var firstOnce sync.Once

	opts := mqtt.NewClientOptions().
		AddBroker(w.mqttCfg.Broker).
		SetClientID(w.mqttCfg.ClientID).
		SetUsername(w.mqttCfg.Username).
		SetPassword(w.mqttCfg.Password).
		SetAutoReconnect(true).
		SetConnectRetry(true).
		SetConnectRetryInterval(10 * time.Second).
		SetKeepAlive(30 * time.Second).
		SetOrderMatters(false)
	opts.SetOnConnectHandler(func(c mqtt.Client) {
		slog.Info("oitalk_mqtt_connected", "broker", w.mqttCfg.Broker, "client_id", w.mqttCfg.ClientID)
		subs := map[string]byte{topicGeofence: 1, topicState: 1}
		tok := c.SubscribeMultiple(subs, func(_ mqtt.Client, msg mqtt.Message) {
			w.dispatch(ctx, msg.Topic(), string(msg.Payload()), msg.Retained())
		})
		tok.Wait()
		if err := tok.Error(); err != nil {
			slog.Error("oitalk_mqtt_subscribe_failed", "err", err,
				"hint", "브로커가 접속은 받고 구독을 거부함 — 재접속 전까지 이벤트 없음")
			firstOnce.Do(func() { firstSub <- err })
			return
		}
		slog.Info("oitalk_mqtt_subscribed", "topics", []string{topicGeofence, topicState})
		firstOnce.Do(func() { firstSub <- nil })
	})
	opts.SetConnectionLostHandler(func(_ mqtt.Client, err error) {
		slog.Warn("oitalk_mqtt_connection_lost", "err", err, "hint", "자동 재접속 대기")
	})
	opts.SetReconnectingHandler(func(_ mqtt.Client, _ *mqtt.ClientOptions) {
		slog.Info("oitalk_mqtt_reconnecting")
	})

	cli := mqtt.NewClient(opts)
	slog.Info("oitalk_mqtt_connecting", "broker", w.mqttCfg.Broker)
	if tok := cli.Connect(); tok.Wait() && tok.Error() != nil {
		return nil, fmt.Errorf("mqtt connect: %w", tok.Error())
	}
	select {
	case err := <-firstSub:
		if err != nil {
			cli.Disconnect(250)
			return nil, fmt.Errorf("mqtt subscribe: %w", err)
		}
	case <-ctx.Done():
		cli.Disconnect(250)
		return nil, ctx.Err()
	}
	return func() { cli.Disconnect(250) }, nil
}

func (w *Watcher) dispatch(ctx context.Context, topic, payload string, retained bool) {
	switch {
	case strings.HasSuffix(topic, "/geofence"):
		w.HandleGeofence(ctx, payload, retained)
	case strings.HasSuffix(topic, "/state"):
		w.HandleState(ctx, payload)
	}
}

// coverageEnd today 부터 연속으로 carNum 예약이 덮는 마지막 날. 오늘이 비면 zero.
func coverageEnd(rows []Reservation, carNum string, today time.Time) time.Time {
	type span struct{ s, e time.Time }
	var spans []span
	for _, r := range rows {
		if r.CarNum != carNum {
			continue
		}
		s, err1 := ParseYMD(r.StartDate)
		e, err2 := ParseYMD(r.EndDate)
		if err1 != nil || err2 != nil {
			slog.Warn("oitalk_row_date_unparsable", "id", string(r.ID), "start_date", r.StartDate, "end_date", r.EndDate)
			continue
		}
		spans = append(spans, span{s, e})
	}
	var until time.Time
	for day := today; ; day = day.AddDate(0, 0, 1) {
		covered := false
		for _, sp := range spans {
			if !day.Before(sp.s) && !day.After(sp.e) {
				covered = true
				break
			}
		}
		if !covered {
			return until
		}
		until = day
	}
}

func countCar(rows []Reservation, carNum string) int {
	n := 0
	for _, r := range rows {
		if r.CarNum == carNum {
			n++
		}
	}
	return n
}

// sleepCtx d 만큼 기다린다. ctx 취소 시 false.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	if d <= 0 {
		return ctx.Err() == nil
	}
	select {
	case <-ctx.Done():
		return false
	case <-time.After(d):
		return true
	}
}

func ymd(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.In(KST).Format("2006-01-02")
}

func ms(t0 time.Time) int64 { return time.Since(t0).Milliseconds() }
