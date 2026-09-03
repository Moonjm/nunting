package oitalk

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	mqtt "github.com/eclipse/paho.mqtt.golang"
)

const (
	topicGeofence = "teslamate/cars/+/geofence"
	topicState    = "teslamate/cars/+/state"

	// registerTimeout 진입 hot-path 의 등록 POST 상한.
	registerTimeout = 15 * time.Second
	// tokenWarmInterval 저빈도 토큰 프리워밍 주기(driving 엣지와 별개 백스톱).
	tokenWarmInterval = time.Hour
	// eventQueueSize paho 콜백 → 워커 사이 버퍼. 지오펜스·state 는 분당 몇 건이라 넉넉.
	eventQueueSize = 64

	// 등록 실패 재시도. TeslaMate 는 값이 바뀔 때만 publish 하므로 실패 후 차가 주차된
	// 채면 이벤트가 더 오지 않는다 — 진입 상태가 유지되는 동안 스스로 재시도한다.
	topicRetry         = "nunting/oitalk/retry"
	defaultRetryDelay  = 30 * time.Second
	maxRegisterRetries = 10

	// topicReconnect 접속 세대 경계. 재접속 시 구독보다 먼저 큐에 넣어, 뒤따르는
	// retained 값이 새 baseline 이 되게 한다.
	topicReconnect     = "nunting/oitalk/reconnect"
	subscribeRetryWait = 5 * time.Second
)

// event MQTT 메시지 1건. paho 콜백은 이것만 큐에 넣고 즉시 반환한다.
type event struct {
	topic    string
	payload  string
	retained bool
}

// API watcher 가 쓰는 오이톡 클라이언트 표면. 테스트에서 fake 로 대체.
type API interface {
	EnsureToken(ctx context.Context) (string, error)
	List(ctx context.Context, start, end time.Time) ([]Reservation, error)
	Register(ctx context.Context, start, end time.Time) (Reservation, error)
}

// Watcher TeslaMate MQTT 지오펜스를 구독해 "밖→집" 상승엣지에 방문차량을 등록한다.
//
// 멱등성은 DB 없이 메모리 커버리지 캐시(coveredUntil)로 처리한다. 등록 1건이
// 3일을 덮으므로 대부분의 진입은 네트워크 없이 여기서 끝난다. 재시작 시엔
// Bootstrap 이 오이톡 목록으로 캐시를 seed 하고, 첫 지오펜스 값(retained)은
// baseline 으로만 저장해 이미 주차 중인 차를 진입으로 오인하지 않는다.
//
// 차 1대 전제 — 토픽 와일드카드(+)로 받지만 상태는 차량별로 나누지 않는다.
type Watcher struct {
	api     API
	cfg     Config
	mqttCfg MQTTConfig
	now     func() time.Time

	events     chan event
	retryDelay time.Duration

	mu           sync.Mutex
	hasBaseline  bool
	lastGeo      string
	lastState    string
	coveredUntil time.Time // 이 날짜(KST 자정)까지 등록됨. zero 면 미상.
	retryPending bool      // 진입 등록 실패 → 재시도 대기 중
	retryCount   int       // 이번 진입에서 소진한 재시도 횟수
	entryGen     int       // 진입 세대. 재시도 타이머가 어느 진입 것인지 태깅.
}

// NewWatcher main.go 배선용.
func NewWatcher(client *Client, m MQTTConfig) *Watcher {
	return newWatcher(client, client.Config(), m)
}

func newWatcher(api API, cfg Config, m MQTTConfig) *Watcher {
	return &Watcher{
		api: api, cfg: cfg, mqttCfg: m, now: time.Now,
		events: make(chan event, eventQueueSize), retryDelay: defaultRetryDelay,
	}
}

// Bootstrap 오이톡 목록으로 오늘 기준 커버리지를 1회 조회해 캐시를 seed 한다.
// 실패해도 치명적이지 않다 — 캐시가 비면 다음 진입에 등록을 시도할 뿐이다.
func (w *Watcher) Bootstrap(ctx context.Context) {
	today := DayOf(w.now())
	start, end, err := CoverageWindow(today, MaxCoverageDays)
	if err != nil {
		return
	}
	rows, err := w.api.List(ctx, start, end)
	if err != nil {
		slog.Warn("oitalk_bootstrap_list_failed", "err", err)
		return
	}
	until := coverageEnd(rows, w.cfg.CarNum, today)
	w.mu.Lock()
	w.coveredUntil = until
	w.mu.Unlock()
	if until.IsZero() {
		slog.Info("oitalk_bootstrap", "covered_until", "", "rows", len(rows))
		return
	}
	slog.Info("oitalk_bootstrap", "covered_until", until.Format("2006-01-02"), "rows", len(rows))
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

// HandleGeofence MQTT geofence 페이로드 1건 처리(hot-path).
//
// retained 는 브로커가 보관하던 과거 값(구독 직후 즉시 도착)이라 baseline 으로만
// 쓴다 — 이미 주차 중인 차를 진입으로 오인하지 않기 위해. 반대로 첫 메시지가
// live 면(차가 밖에 있어 retained 값이 없던 상태) 그 자체가 실제 변화이므로
// 직전값을 "밖"(빈 값)으로 놓고 엣지 판정을 그대로 태운다.
func (w *Watcher) HandleGeofence(ctx context.Context, payload string, retained bool) {
	cur := strings.TrimSpace(payload)
	target := w.mqttCfg.Geofence

	w.mu.Lock()
	defer w.mu.Unlock()

	if !w.hasBaseline {
		w.hasBaseline = true
		if retained {
			w.lastGeo = cur
			slog.Info("oitalk_geofence_baseline", "geofence", cur)
			return
		}
		w.lastGeo = ""
		slog.Info("oitalk_geofence_baseline", "geofence", "", "reason", "no retained value")
	}
	prev := w.lastGeo
	w.lastGeo = cur
	if cur != target {
		// 나감(또는 다른 지오펜스) — 이번 진입의 재시도는 의미 없어 폐기.
		w.retryPending = false
		w.retryCount = 0
		return
	}
	if prev == target {
		return
	}
	w.entryGen++
	w.retryCount = 0
	w.registerLocked(ctx)
}

// HandleReconnect 접속 세대 경계. 끊긴 사이 차가 나가면 TeslaMate 의 빈 값이
// retained 메시지를 지워 재접속 후 아무것도 오지 않는다 — lastGeo 가 "집" 으로
// 굳어 다음 진입이 집→집으로 보여 영구히 등록을 놓친다. 그래서 세대마다 baseline
// 을 다시 잡는다: 재접속 후 retained 가 오면 baseline, live 가 오면 "밖" 에서의
// 진입으로 판정한다. 재시도 상태는 건드리지 않는다(진입 중 재시도는 계속).
func (w *Watcher) HandleReconnect() {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.hasBaseline = false
	w.lastGeo = ""
	w.lastState = ""
	slog.Info("oitalk_geofence_rebaseline")
}

// HandleRetry 등록 실패 후 스케줄된 재시도. gen 이 현재 진입 세대와 다르면(그 사이
// 나갔다 다시 들어옴) 옛 타이머이므로 무시. 여전히 진입 상태이고 대기 중일 때만.
//
// 실패한 POST 가 서버엔 커밋됐는데 응답만 유실됐을 수 있다(타임아웃 등). 등록은
// 비멱등이라 그대로 다시 쏘면 중복 예약 + 월 주차한도 소모 — 재시도 전에 목록으로
// 현재 커버리지를 먼저 확인한다. 목록 조회마저 실패하면 POST 하지 않고 다음
// 재시도로 미룬다.
func (w *Watcher) HandleRetry(ctx context.Context, gen int) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.retryPending || gen != w.entryGen || w.lastGeo != w.mqttCfg.Geofence {
		return
	}
	today := DayOf(w.now())
	start, end, err := CoverageWindow(today, MaxCoverageDays)
	if err != nil {
		w.retryPending = false
		return
	}
	lctx, cancel := context.WithTimeout(ctx, registerTimeout)
	rows, err := w.api.List(lctx, start, end)
	cancel()
	if err != nil {
		slog.Warn("oitalk_retry_list_failed", "err", err)
		w.scheduleRetryLocked(ctx)
		return
	}
	if until := coverageEnd(rows, w.cfg.CarNum, today); !until.IsZero() {
		w.coveredUntil = until
		w.retryPending = false
		w.retryCount = 0
		slog.Info("oitalk_retry_found_existing", "covered_until", until.Format("2006-01-02"))
		return
	}
	w.registerLocked(ctx)
}

// registerLocked 오늘 기준 커버리지 확인 후 등록. 실패하면 재시도 예약. mu 보유 전제.
func (w *Watcher) registerLocked(ctx context.Context) {
	today := DayOf(w.now())
	if !w.coveredUntil.IsZero() && !today.After(w.coveredUntil) {
		w.retryPending = false
		slog.Debug("oitalk_entry_covered", "today", today.Format("2006-01-02"),
			"covered_until", w.coveredUntil.Format("2006-01-02"))
		return
	}

	start, end, err := CoverageWindow(today, w.cfg.CoverageDays)
	if err != nil {
		w.retryPending = false
		slog.Error("oitalk_register_skipped", "err", err)
		return
	}
	rctx, cancel := context.WithTimeout(ctx, registerTimeout)
	defer cancel()
	row, err := w.api.Register(rctx, start, end)
	if err != nil {
		slog.Error("oitalk_register_failed", "err", err, "attempt", w.retryCount+1)
		w.scheduleRetryLocked(ctx)
		return
	}
	w.coveredUntil = DayOf(end)
	w.retryPending = false
	w.retryCount = 0
	slog.Info("oitalk_registered", "start_date", DayOf(start).Format("2006-01-02"),
		"end_date", w.coveredUntil.Format("2006-01-02"), "id", string(row.ID), "state", row.State)
}

// scheduleRetryLocked 예산이 남았으면 현재 진입 세대를 태깅한 재시도 이벤트를
// retryDelay 뒤 큐에 넣는다. mu 보유 전제.
func (w *Watcher) scheduleRetryLocked(ctx context.Context) {
	if w.retryCount >= maxRegisterRetries {
		w.retryPending = false
		slog.Error("oitalk_register_gave_up", "attempts", w.retryCount+1)
		return
	}
	w.retryCount++
	w.retryPending = true
	gen := w.entryGen
	slog.Info("oitalk_retry_scheduled", "retry", w.retryCount, "in", w.retryDelay.String())
	time.AfterFunc(w.retryDelay, func() { w.enqueue(ctx, topicRetry, strconv.Itoa(gen), false) })
}

// HandleState 차량 state 페이로드. driving 으로 바뀌면 토큰을 미리 데워
// 진입 순간엔 register POST 한 방만 나가게 한다.
func (w *Watcher) HandleState(ctx context.Context, payload string) {
	cur := strings.TrimSpace(payload)
	w.mu.Lock()
	prev := w.lastState
	w.lastState = cur
	w.mu.Unlock()
	if cur != "driving" || prev == "driving" {
		return
	}
	if _, err := w.api.EnsureToken(ctx); err != nil {
		slog.Warn("oitalk_token_prewarm_failed", "err", err)
	}
}

// Run 브로커 접속 + 구독 후 ctx 취소까지 유지. 자동 재접속, 재접속 시 재구독.
func (w *Watcher) Run(ctx context.Context) error {
	return w.runWith(ctx, w.connectMQTT)
}

// runWith 기동 순서가 핵심이다:
//
//  1. 구독(subscribe) — 콜백은 큐에 넣기만 한다.
//  2. 부트스트랩 — 오이톡 목록으로 커버리지 캐시 seed(네트워크, 느릴 수 있음).
//  3. 워커(serve) 시작 — 그제서야 큐를 순서대로 소비.
//
// 부트스트랩이 느린 동안 차가 진입해도 이벤트는 이미 큐에 잡혀 있고(retained
// baseline → live 진입 순서 그대로), seed 가 끝난 뒤 처리되므로 놓치지 않는다.
// 구독을 부트스트랩 뒤로 미루면 그 사이 진입은 retained 값 하나로만 도착해
// baseline 으로 삼켜진다.
//
// paho 는 기본(OrderMatters) 모드에서 메시지 핸들러가 블로킹하지 않기를 요구한다
// — 핸들러가 막히면 뒤이은 QoS1 메시지·ack 가 직렬화돼 keepalive 끊김까지 갈 수
// 있다. 그래서 콜백은 큐에 넣기만 하고, 단일 워커가 처리한다. 워커가 하나라
// 엣지 판정 순서는 그대로 보존된다.
func (w *Watcher) runWith(ctx context.Context, subscribe func(context.Context) (func(), error)) error {
	closeFn, err := subscribe(ctx)
	if err != nil {
		return err
	}
	defer closeFn()

	w.Bootstrap(ctx)
	go w.serve(ctx)

	ticker := time.NewTicker(tokenWarmInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			if _, err := w.api.EnsureToken(ctx); err != nil {
				slog.Warn("oitalk_token_prewarm_failed", "err", err)
			}
		}
	}
}

// connectMQTT paho 접속 + 구독. 반환 함수는 접속 해제.
//
// paho 는 OnConnect 를 별도 goroutine 에서 부르므로 Connect() 완료 ≠ 구독 완료.
// 최초 구독이 실제로 성공할 때까지 기다렸다가 돌아온다 — 그래야 이어지는
// Bootstrap 동안의 진입이 큐에 잡힌다. 매 (재)접속마다 세대 경계 이벤트를 먼저
// 큐에 넣고, 구독은 성공할 때까지 재시도한다(브로커가 접속은 받고 SUBACK 만
// 실패하면 OnConnect 가 다시 불리지 않아 영구 무구독이 되기 때문).
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
		SetKeepAlive(30 * time.Second)
	opts.SetOnConnectHandler(func(c mqtt.Client) {
		slog.Info("oitalk_mqtt_connected", "broker", w.mqttCfg.Broker)
		w.enqueueReconnect(ctx)
		subs := map[string]byte{topicGeofence: 1, topicState: 1}
		err := subscribeWithRetry(ctx, subscribeRetryWait, func() error {
			if !c.IsConnectionOpen() {
				return errors.New("connection not open")
			}
			tok := c.SubscribeMultiple(subs, func(_ mqtt.Client, msg mqtt.Message) {
				w.enqueue(ctx, msg.Topic(), string(msg.Payload()), msg.Retained())
			})
			tok.Wait()
			return tok.Error()
		})
		if err != nil {
			slog.Error("oitalk_mqtt_subscribe_failed", "err", err)
		} else {
			slog.Info("oitalk_mqtt_subscribed")
		}
		firstOnce.Do(func() { firstSub <- err })
	})
	opts.SetConnectionLostHandler(func(_ mqtt.Client, err error) {
		slog.Warn("oitalk_mqtt_connection_lost", "err", err)
	})

	cli := mqtt.NewClient(opts)
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

// subscribeWithRetry 구독이 성공할 때까지 wait 간격으로 반복. ctx 취소 시 중단.
func subscribeWithRetry(ctx context.Context, wait time.Duration, subscribe func() error) error {
	for {
		err := subscribe()
		if err == nil {
			return nil
		}
		slog.Warn("oitalk_mqtt_subscribe_retry", "err", err, "in", wait.String())
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
}

// enqueueReconnect 접속 세대 경계를 큐에 넣는다(구독보다 먼저 호출).
func (w *Watcher) enqueueReconnect(ctx context.Context) {
	w.enqueue(ctx, topicReconnect, "", false)
}

// enqueue paho 콜백용. 큐가 차 있으면 기다리지 않고 버린다(로그) — 콜백을 막는
// 것보다 낫고, 지오펜스는 retained 라 재접속 시 최신 값이 다시 온다.
func (w *Watcher) enqueue(ctx context.Context, topic, payload string, retained bool) {
	select {
	case w.events <- event{topic: topic, payload: payload, retained: retained}:
	case <-ctx.Done():
	default:
		slog.Warn("oitalk_event_dropped", "topic", topic, "queue", cap(w.events))
	}
}

// serve 단일 워커. ctx 취소까지 큐를 순서대로 소비한다.
func (w *Watcher) serve(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case ev := <-w.events:
			w.dispatch(ctx, ev.topic, ev.payload, ev.retained)
		}
	}
}

func (w *Watcher) dispatch(ctx context.Context, topic, payload string, retained bool) {
	switch {
	case strings.HasSuffix(topic, "/geofence"):
		w.HandleGeofence(ctx, payload, retained)
	case strings.HasSuffix(topic, "/state"):
		w.HandleState(ctx, payload)
	case topic == topicReconnect:
		w.HandleReconnect()
	case topic == topicRetry:
		if gen, err := strconv.Atoi(payload); err == nil {
			w.HandleRetry(ctx, gen)
		}
	}
}
