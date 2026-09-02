# 오이톡 방문차량 지오펜스 자동등록 (서버)

- 날짜: 2026-09-02
- 상태: 설계 — 외부 연동 검증 완료, 구현 착수 전
- 범위: Go 서버(`Server/`) 신규 패키지 `internal/oitalk`
- 관련 파일(예정): `internal/oitalk/client.go`, `internal/oitalk/watcher.go`, `cmd/server/main.go`(배선), `Server/.env.example`(env 추가), `Server/go.mod`(MQTT 의존성)

**한 줄 요약.** 테슬라가 방문 대상 아파트 지오펜스(`일산`)에 **들어오는 순간**, nunting 서버가 오이톡 방문차량 API로 **그날부터 3일치**를 자동 등록한다. 차단기 도착 *전에* 등록이 끝나 번호판 인식으로 통과하는 게 목표다. 위치 신호는 TeslaMate의 MQTT를 **구독(이벤트 구동)** 한다 — 폴링하지 않는다. iOS/하루 앱에는 화면을 붙이지 않는다(수동은 오이톡 앱).

## 배경

우리 테슬라는 단지 등록차량이 아니라, 차단기를 통과하려면 매번 **방문차량으로 등록**해야 한다. 지금은 도착 전에 오이톡 앱을 열어 손으로 등록한다 — 깜빡하면 정문에서 막힌다.

차 위치는 이미 **TeslaMate**가 계속 쌓고 있고, TeslaMate는 **내장 지오펜스**를 MQTT로 실시간 publish한다(`teslamate/cars/$id/geofence`). 그래서 좌표 계산도, 주기 폴링도 필요 없다 — 지오펜스 값이 "집"으로 바뀌는 **상승엣지**만 잡으면 된다. 이 잡을, 이미 돌고 있는 nunting 서버(`internal/poll` 폴러와 같은 프로세스)에 구독자 하나로 얹는다.

오이톡 등록 API 자체는 mitmproxy로 전 규격을 관찰해 확정했다(SSL 피닝 없음). 등록은 관리사무소 `auto_accept:true` 라 200 응답 즉시 승인(`state:"ok"`)된다.

## 목표

- 집 지오펜스 **진입 순간** 방문차량을 자동 등록해, **차단기 도착 전에 등록이 반영**되게 한다.
- 진입한 그날 D부터 **D ~ D+2 (3일, 최대치)** 한 건 등록.
- 이미 커버된 기간이면 **재등록하지 않는다**(3일 등록이 겹치므로 실제 등록은 ~3일에 한 번).
- 진입→등록 hot-path를 **단일 POST(1~2초)** 로 최소화 — access token은 미리 데워 둔다.
- 실패는 로그로 남긴다.

## 비목표

- **화면을 만들지 않는다.** 수동 등록·조회·수정·삭제는 오이톡 앱.
- **전화인증(ARS)을 서버에 구현하지 않는다.** `client_secret`(만료 없는 자격증명)을 최초 캡처로 확보해 env로 주입.
- **좌표 point-in-polygon을 직접 하지 않는다.** TeslaMate 내장 지오펜스(원형) 판정을 그대로 쓴다. (다각형이 필요해지면 그때 `location` 토픽 구독으로 전환)
- **주기 폴링을 하지 않는다.** MQTT 이벤트 구동. (단, 부트스트랩·정합성용 최소 목록 조회는 함)
- **DB 테이블을 새로 만들지 않는다.** 멱등성은 오이톡 목록 API + 메모리 캐시로 처리(재시작 안전).
- **월 주차한도 계산을 넣지 않는다.**

---

## 트리거: TeslaMate MQTT

TeslaMate가 publish하는 토픽(확정):

| 토픽 | 값 |
| --- | --- |
| `teslamate/cars/$id/geofence` | 현재 위치의 지오펜스 이름(예: `🏡 집`), 밖이면 빈 값. **retained, 변경 시 publish.** |
| `teslamate/cars/$id/state` | `driving`/`online`/`asleep`/`charging` 등 |
| `teslamate/cars/$id/location` | `{latitude,longitude}` JSON (지오펜스로 충분하면 미사용) |

**지오펜스 설정.** 방문 대상 아파트 정문 기준 **넉넉한 반경의 원**을 TeslaMate UI에 그린다(정문에서 수백 m 밖까지). 넉넉하게 잡는 이유:

- 진입엣지가 차단기보다 한참 **바깥에서** 떠서, 차가 정문까지 달려오는 동안 등록 POST가 끝날 **리드타임**을 번다.
- TeslaMate의 지오펜스 감지는 주행 중이면 수 초~십수 초. 넉넉한 반경이면 그 지연 + API 왕복(1~2초)을 흡수하고도 남는다.
- **등록→차단기 반영은 즉시**다(실사용 확인 — 등록하면 바로 통과됨). 그래서 반경이 흡수해야 할 건 "감지 지연 + API 왕복"(수 초)뿐이고, 정문 밖 수백 m면 충분히 여유롭다.
- 드라이브 스루 오탐이 늘지만, 방문 동선이라 대부분 진짜 도착이고 오등록돼도 방문차량 1건이라 피해가 작다(월 주차한도만 헛되이 깎일 수 있음 — 실사용 보고 필요 시 조인다).

**매칭 지오펜스 이름 (확정): `일산`.** env `TESLAMATE_GEOFENCE=일산`. TeslaMate에 만든 지오펜스 이름과 정확히 일치하며 이모지·앞뒤 공백 없음. 코드는 방어적으로 trim 후 정확 일치 비교.

**구독.** nunting이 브로커(TeslaMate의 mosquitto)에 붙어 `teslamate/cars/+/geofence`(+ 보조로 `.../state`)를 구독. Go MQTT 클라이언트 `github.com/eclipse/paho.mqtt.golang` 추가. QoS 1, 자동 재접속.

**브로커·네트워크 (확정).** TeslaMate 공식 compose의 mosquitto가 **이미 가동 중**이다 — `eclipse-mosquitto:2`, `-c /mosquitto-no-auth.conf`(익명 접속), `1883:1883` 호스트 노출. TeslaMate는 `MQTT_HOST=mosquitto`로 이미 publish 중(그동안 소비자만 없었음). 따라서 브로커·TeslaMate 쪽은 **무수정**.

nunting은 **같은 Pi의 별도 compose**라, 이미 호스트에 열린 1883으로 Pi 고정 IP로 붙는다:

- `TESLAMATE_MQTT_BROKER=tcp://192.168.0.10:1883` (Pi LAN IP — `extra_hosts` 불필요)
- 익명 브로커라 `MQTT_USERNAME`/`MQTT_PASSWORD` 불필요

> 보안: 익명 + 호스트 노출이라 같은 LAN에서 차 위치 스트림 구독 가능. 집 내부망 전제로 수용. 신경 쓰이면 공유 도커 네트워크로 내부망화(포트 미노출).

---

## 오이톡 API 규격 (관찰로 확정)

공통: `Base = https://api.oitalk.net`, 인증 헤더 `x-access-token: <JWT>` 하나, 응답 `{"data":{...}}`.

식별자(캡처로 확보, env 주입): `account_id`, `group_id`, `client_secret`(만료 없음), `device.id`, `device.mobi_key`.

### 1. 토큰 재발급 — `POST /auth/refresh` (JSON)

```json
{"account_id":"<...>","client_secret":"<...>",
 "device":{"id":"<...>","mobi_key":"<...>","app_ver":"2.3.23","app_name":"net.gntalk.oitalk","os_type":"ios","os_ver":"26.6.1","model":"iPhone18,1","lan":"ko","nation":"KR"}}
```
→ `{"data":{"token":"<access, exp≈24h>","client_secret":"<동일 값>","fb_access_token":"..."}}`

`client_secret`으로 access token을 재발급 → **전화인증 개입 없음**. device 값은 최초 등록값(캡처값)과 일치해야 한다(검증 강도 미관찰).

### 2. 등록 — `POST /groups/{group_id}/visit_cars` (헤더 `x-access-token`)

```json
{"start_dt":"<UTC ISO>","end_dt":"<UTC ISO>","car_num":"<...>","recv_phone_e164":"<...>","visit_reason":"세대 방문"}
```
→ `200 {"data":{"row":{"_id":...,"state":"ok",...}}}`

**날짜 규칙**(KST=UTC+9): KST 자정 = 전날 15:00:00.000Z, KST 23:59:59.999 = 당일 14:59:59.999Z.
진입일 D부터 3일이면 `start_dt`=D 00:00 KST=`(D-1) 15:00:00.000Z`, `end_dt`=(D+2) 23:59:59.999 KST=`(D+2) 14:59:59.999Z`. **최대 3일** 제약이라 코드에서 초과 시 등록 안 함.

### 3. 중복 확인 목록 — `GET /groups/{group_id}/visit_cars?ver=1&offset=0&limit=20&start_dt={ISO}&end_dt={ISO}`

→ `{"data":{"rows":[{"_id","car_num","start_date":"YYYYMMDD","end_date":"YYYYMMDD","state",...}]}}`. 같은 차량·대상 날짜가 있으면 존재로 간주.

---

## 서버 설계

### 새 패키지 `internal/oitalk`

**`client.go` — 오이톡 HTTP 클라이언트** (트리거 방식과 무관, 재사용 가능).

```
type Client struct { http *http.Client; cfg Config; mu sync.Mutex; accessToken string; tokenExp time.Time }
func (c *Client) EnsureToken(ctx) (string, error)   // exp 여유(5분) 두고 필요시 refresh
func (c *Client) Refresh(ctx) error                 // POST /auth/refresh
func (c *Client) List(ctx, start, end time.Time) ([]Reservation, error)
func (c *Client) Register(ctx, start, end time.Time) (Reservation, error)  // 401이면 refresh 후 1회 재시도
```

**`watcher.go` — MQTT 구독 + 진입엣지 감지 + 등록.**

```
type Watcher struct {
    client      *Client
    mqtt        mqtt.Client
    target      string        // TESLAMATE_GEOFENCE
    coverDays   int           // 기본 3
    mu          sync.Mutex
    lastGeo     string        // 직전 지오펜스 값(엣지 판정)
    coveredUntil civil.Date   // 이 날짜까지 등록됨(KST) — hot-path 캐시
}
func (w *Watcher) onGeofence(payload string)  // MQTT 콜백
func (w *Watcher) Run(ctx) error              // connect + subscribe + ctx.Done까지 유지
```

**`onGeofence` 로직 (hot-path):**

1. `new := payload`, `prev := w.lastGeo`; `w.lastGeo = new`.
2. **상승엣지만**: `prev != target && new == target` 아니면 return. (주차 중 값이 계속 "집"이어도 재트리거 안 함)
3. 오늘(KST) `today`. **커버리지 캐시**: `today <= coveredUntil` 이면 `slog.Debug` 후 return — **네트워크 없이 즉시 skip**. (3일 겹침 → 대부분의 진입이 여기서 끝남)
4. 아니면 등록: `start=today 00:00 KST`, `end=(today+coverDays-1) 23:59:59.999 KST` → `client.Register`.
   - 성공: `coveredUntil = today+coverDays-1`; `slog.Info("oitalk_registered", start_date, end_date, id)`.
   - 실패: `slog.Error`; `coveredUntil` 갱신 안 함(다음 진입에 재시도).

**토큰 프리워밍.** hot-path에서 `refresh+register` 2방을 피하려고, `Run`이 별도 goroutine으로 **토큰을 항상 유효하게 유지**한다: `state`가 `driving`으로 바뀌면(집으로 출발) 한 번 `EnsureToken`, 그리고 저빈도 타이머(예: 1h)로도 `EnsureToken`. 진입 순간엔 유효 토큰이 있어 **register POST 한 방**만 나간다.

**부트스트랩 / 재시작 안전.** 프로세스 시작 시 retained 지오펜스 메시지가 즉시 "집"으로 올 수 있다(이미 주차 중). 이를 진입으로 오인하지 않게:
- 시작 시 첫 지오펜스 값은 `lastGeo` **baseline으로만** 저장(트리거 안 함).
- 동시에 오이톡 목록 API로 오늘 기준 커버리지를 1회 조회해 `coveredUntil` 을 seed. 이후 진짜 새 진입(밖→집 엣지)만 등록.

### `cmd/server/main.go` 배선

폴러 goroutine 아래에:

```go
oiClient := oitalk.NewClient(oitalk.ConfigFromEnv())
if oiClient.Enabled() && oitalk.MQTTConfigFromEnv().Enabled() {
    w := oitalk.NewWatcher(oiClient, oitalk.MQTTConfigFromEnv())
    go func() {
        if err := w.Run(ctx); err != nil { slog.Error("oitalk_watcher_exit", "err", err) }
    }()
    slog.Info("oitalk_watcher_started")
} else {
    slog.Info("oitalk_watcher_disabled")
}
```

`OITALK_CLIENT_SECRET` 또는 MQTT 브로커 설정이 없으면 조용히 비활성 — 뽐뿌 서버는 그대로 동작.

### env (`.env.example` 에 추가)

```
# === 오이톡 방문차량 지오펜스 자동등록 (선택) ===
# 아래 + 브로커 설정이 다 있어야 동작. 하나라도 비면 비활성.
OITALK_CLIENT_SECRET=          # /auth2 응답 client_secret (만료 없음)
OITALK_ACCOUNT_ID=
OITALK_GROUP_ID=
OITALK_DEVICE_ID=
OITALK_MOBI_KEY=
OITALK_CAR_NUM=                # 등록할 차량번호
OITALK_RECV_PHONE=             # 안내문자 받을 E.164 번호
OITALK_VISIT_REASON=세대 방문
OITALK_COVERAGE_DAYS=3         # 진입 시 등록 일수(최대 3)

# TeslaMate MQTT (같은 Pi 별도 compose → Pi 고정 IP:노출된 1883, 익명)
TESLAMATE_MQTT_BROKER=tcp://192.168.0.10:1883
TESLAMATE_MQTT_USERNAME=
TESLAMATE_MQTT_PASSWORD=
TESLAMATE_MQTT_CLIENT_ID=nunting-oitalk
TESLAMATE_GEOFENCE=일산        # 확정값. TeslaMate 지오펜스 이름과 정확히 일치(이모지·공백 없음)
```

**보안.** `client_secret` 은 오이톡 계정 전체를 여는 열쇠다. `.env` 는 커밋 금지(기존 관례). 이 문서에도 실제 값을 남기지 않는다.

## 테스트

HTTP·MQTT를 인터페이스로 막고 fake로:

- **진입엣지**: `밖→집`만 등록, `집→집`/`밖→밖`/`집→밖`은 무동작.
- **커버리지 캐시**: `today <= coveredUntil` 이면 Register 호출 안 함.
- **3일 범위 날짜 변환**: 진입일 D → `start_dt`=D 00:00 KST, `end_dt`=(D+2) 23:59:59.999 KST 의 UTC ISO 정확 일치. 3일 초과 설정은 거부.
- **토큰**: 만료 시 refresh 선행; register 401 → refresh 후 1회 재시도. driving 진입 시 프리워밍 호출.
- **부트스트랩**: 재시작 후 retained "집" 이 즉시 와도 트리거 안 함(baseline), 목록으로 `coveredUntil` seed.
- **비활성**: env 부족 시 watcher 안 뜸.

실 API·실 브로커를 때리는 테스트는 두지 않는다.

## 검증 완료 (2026-09-02)

착수 전, 실제 계정·실제 브로커로 외부 연동을 확인했다. **읽기 전용** — 방문차량 등록(POST)은 하지 않았다.

**오이톡 API (Mac → api.oitalk.net, 읽기 전용):**
- `POST /auth/refresh` → 200. 저장된 `client_secret`으로 새 access token 발급(exp ≈ 24h). `client_secret`은 그대로 반환(회전 안 함) → **캡처값 아직 유효, 자동갱신 동작 확정**.
- `GET /groups/{group_id}/visit_cars` → 200, 예약 51건. 최근 내역 전부 `동일 차량 / 세대 방문 / state=ok`. group_id·account·아파트 일치 확인.
- 목록에 `20260716~20260717`, `20260710~20260711` 등 **2일짜리 예약 실재** → **다중일(우리 3일) 등록이 서비스에서 실제로 동작함** 확정.

**TeslaMate MQTT (Mac → 192.168.0.10:1883, 익명 구독):**
- 연결·구독 성공(CONNACK rc 0, SUBACK ok), 토픽 23개 수신 — 차량 표시명·`state`·위경도·배터리 등 정상 흐름.
- `geofence` 토픽은 그 시점 부재 → 차가 지오펜스 밖이라 **정상**(안에 들어가면 retained로 이름이 즉시 옴).

→ 핵심 리스크(client_secret 무효·API 연결·규격·MQTT 파이프라인)가 모두 해소. "지오펜스 진입 → 등록"이 이어진다는 게 사실상 보장됨. 남은 건 실제 진입 1회로 `geofence='일산'` 문자열을 눈으로 최종 확인하는 것뿐.

## 미확인 / 리스크

- **등록→차단기 반영**: 실사용 확인 결과 **즉시** 통과된다(별도 전파 지연 없음). 리스크에서 내림 — 반경은 감지+API 지연(수 초)만 흡수하면 됨.
- **MQTT 유실**: 도착 순간 브로커/연결이 끊겨 있으면 진입 이벤트를 놓칠 수 있음. paho 자동 재접속 + retained로 대부분 복구되나, 백스톱으로 **하루 1회 저빈도 정합성 체크**(오늘 커버 안 됐고 최근 집에 있으면 등록)를 옵션으로 둘 수 있음(우선 미구현).
- **지오펜스 이름 매칭**: 값은 `일산`으로 확정. 그래도 코드는 trim 후 정확 일치로 방어. 실제 진입 시 뜨는 문자열이 다르면(예: 이모지 접두어) env만 그 값으로 교체.
- **`client_secret` 무효화**: 2026-09-02 시점 유효 확인됨. 이후 오이톡 앱 재로그인/로그아웃 시 새 값 발급·옛 값 무효화 가능 → refresh 401 로그로 드러나면 새 캡처로 env 갱신.
- **월 주차한도**: `parking_time_of_month` 존재. 오탐 누적 시 한도 소진 가능 — 등록 거부되면 200 아님으로 로그에 드러남.
- **`device` 검증 강도 / 목록 `state` 값 종류**: 관찰 못 함. 캡처값 그대로 주입, 멱등은 보수적으로.
