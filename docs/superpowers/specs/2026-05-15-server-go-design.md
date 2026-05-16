# Server (Go) 재작성 설계

**Goal**
`Server/` 의 Swift NuntingServer 를 통째로 삭제하고 Go 로 재작성한다. iOS 클라이언트(PR D, 이미 stable)는 zero change — 동일 API contract, 동일 Bearer prefix, 동일 baseURL 패턴. 동시에 라즈베리파이(aarch64) Docker 배포 자산까지 한 PR 에 포함해, 머지 후 곧장 `docker compose up -d --build` 한 줄로 Pi 운영 가능한 상태로 끝낸다.

**왜 Go 인가**
Swift on Linux 의 Apple-framework 결손(`CryptoKit`, `CoreFoundation`, `FoundationNetworking` 분리, Hummingbird major API churn) 을 매 라이브러리 업그레이드마다 안고 가는 게 1인 도구의 유지비 측면에서 손해. 워크로드(HTTP + SQLite + HTML scrape + APNs JWT) 는 Go 가 산업 표준 도구인 영역.

**Non-Goals**
- iOS baseURL 변경 (도메인 확정 후 사용자 한 줄 수정 — `nunting/Services/AlertSubscriptionService.swift:45`).
- Cloudflare Tunnel / TLS — 사용자가 외부 노출 별도 처리.
- 자동 백업.
- `Shared/`(NuntingCore SPM) 통합 — 별도 cleanup PR 후보.
- iOS 영향 — 단 한 줄 안 건드림.

---

## API contract (iOS 와의 인터페이스 — 절대 불변)

라우트와 응답 모양은 Swift 버전(`Server/Sources/NuntingServer/App.swift` + `Routes/*.swift`) 그대로:

| Method | Path | Auth | Body | Response |
|---|---|---|---|---|
| GET | `/health` | none | — | `200 "ok"` text/plain |
| GET | `/me/_echo` | Bearer | — | `200 "<uuid>"` text/plain |
| PUT | `/me/push-token` | Bearer | `{"token": "<hex>"} \| {"token": null}` | `200 OK` (empty body) |
| GET | `/me/keywords` | Bearer | — | `200 ["..", ".."]` (정렬된 string array) |
| POST | `/me/keywords` | Bearer | `{"keyword": "<raw>"}` | `200 "<normalized>"` (JSON string) |
| DELETE | `/me/keywords/{keyword}` | Bearer | — | `200 OK` (empty body — Swift 버전이 Status only) |

**Auth**: `Authorization: Bearer nnt_<UUID>`. 헤더 누락 / prefix 불일치면 `401`. 통과한 uuid 는 매 요청마다 `users` 테이블에 upsert (`INSERT ... ON CONFLICT DO NOTHING`).

**정규화 규칙** (POST /me/keywords):
- 앞뒤 whitespace trim
- 빈 문자열이면 `400`
- (이후 처리: trim 이후 lowercased? 아니다 — Swift 버전은 그대로 저장. Go 도 동일.)

---

## 데이터 모델 (SQLite — Swift 버전 그대로)

Pi 첫 배포라 migration 부담 없음. 동일 스키마로 신규 생성:

```sql
CREATE TABLE IF NOT EXISTS users (
    uuid       TEXT PRIMARY KEY,
    push_token TEXT,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS keyword_subs (
    uuid    TEXT NOT NULL,
    keyword TEXT NOT NULL,
    PRIMARY KEY (uuid, keyword),
    FOREIGN KEY (uuid) REFERENCES users(uuid) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_users_with_token
    ON users(uuid) WHERE push_token IS NOT NULL;

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
```

`seen_posts` 등 별도 테이블 없음 — 폴러 sentinel 은 **in-memory** (Swift 버전 동일). 컨테이너 재시작 시 sentinel 리셋 → 첫 tick 은 top post 만 sentinel 로 저장하고 알림 안 보냄(스팸 방지).

---

## 폴러 알고리즘 (Swift 버전 그대로)

3분 ticker goroutine.
1. `lastSeenPostID == nil` (첫 tick / 재시작 직후): `page=1` 만 페치 → top post.id 를 sentinel 로 저장, 알림 안 보냄. 종료.
2. 그 외: `page=1..maxPages(=10)` 순차 페치. 페이지 내 글들을 위에서 아래로 보다가 `post.id == sentinel` 만나면 walk 종료. sentinel 못 만나고 maxPages 끝까지 가면 거기서 종료(로그만).
3. 수집된 new posts 를 reverse(=시간순 오래된 것부터) 해서 각 글마다:
   - 모든 user 의 keyword 와 매칭 (case-insensitive substring — Swift 버전 동일)
   - 매칭된 user 의 `push_token` 있으면 APNs payload 빌드 + send
4. tick 종료 시 sentinel 을 새 newest(`newPosts.last.id`) 로 갱신.

**HTTP fetch**: `m.ppomppu.co.kr/new/bbs_list.php?id=ppomppu&page=N`. 응답 인코딩은 EUC-KR 광고지만 실제로는 CP949 — `golang.org/x/text/encoding/korean.EUCKR` 디코더는 CP949 superset 처리. User-Agent 헤더 박아 모바일 컨텍스트 유지.

**HTML 파싱**: `goquery`. 리스트 페이지의 글 row selector + title/postNo/author/date 추출. 정확한 selector 는 Swift `PpomppuParser.swift` 에서 port (`Shared/Sources/NuntingCore/Parsers/PpomppuParser.swift` 참고 — 단, Go 는 NuntingCore 의존 0).

**APNs payload**:
```json
{
  "aps": {
    "alert": { "title": "<keyword>", "body": "<post.title>" },
    "sound": "default"
  },
  "url": "https://m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=<postNo>"
}
```
iOS `NotificationDelegate` 가 `userInfo["url"]` 로 deep-link.

---

## 디렉토리 / 모듈 구조

```
Server/
  go.mod
  go.sum
  cmd/
    server/
      main.go               # 부팅: env 읽고 db/api/poll/apns 와이어링 + signal handling
  internal/
    db/
      sqlite.go             # Open, schema migrate, query 함수들 (UpsertUser, SetPushToken, ListKeywords, ...)
      sqlite_test.go        # in-memory DB로 모든 CRUD 검증
    api/
      router.go             # chi 라우터 + middleware 설치
      middleware.go         # BearerAuth — uuid 검증/upsert/context 주입
      handlers.go           # health, _echo, push-token, keywords CRUD
      handlers_test.go      # httptest + in-memory DB
    poll/
      poller.go             # 3분 ticker + sentinel walk
      fetcher.go            # HTTP fetch + EUC-KR/CP949 decode
      parser.go             # goquery 기반 list page parse
      matcher.go            # case-insensitive substring 매칭
      parser_test.go        # 고정 fixture HTML 로 parse 검증
    apns/
      client.go             # sideshow/apns2 wrapper + 410 self-heal
      client_test.go        # mock transport 로 request shape 검증
  Dockerfile                # multi-stage golang:1.23-alpine → alpine:3 runtime
  docker-compose.yml        # bind mount + env_file + log rotation
  .env.example
  .dockerignore
  data/.gitkeep             # SQLite 보존 디렉토리
  secrets/.gitkeep          # APNs .p8 디렉토리
docs/ops/
  nunting-server.md         # 라즈베리파이 운영 가이드 (Go 버전)
```

`go.mod` 모듈 경로: `github.com/moonjm/nunting/server` (실제 GitHub remote 와 일치). 1인 도구라 path-based 도 가능하지만 표준 관례 따라 명시.

**파일 책임 분리 원칙**: 각 파일은 한 책임. `internal/db/sqlite.go` 가 ~200줄 넘어가면 도메인별로(`users.go`, `keywords.go`) 분리 — plan 단계에서 가이드.

---

## 설정 (환경변수)

Swift 버전과 동일한 키 (iOS 운영 가이드/`.env.example` 충돌 방지):

| 키 | 기본값 | 의미 |
|---|---|---|
| `NUNTING_BIND_HOST` | `127.0.0.1` | 컨테이너 내부는 compose `environment:` 가 `0.0.0.0` 강제 |
| `NUNTING_BIND_PORT` | `8080` | 동일 |
| `NUNTING_DB_PATH` | `/var/lib/nunting/state.db` | bind mount 안 |
| `NUNTING_POLL_INTERVAL_SECONDS` | `180` | int 파싱 실패 시 default |
| `NUNTING_HOST_PORT` | `8080` | compose `${NUNTING_HOST_PORT:-8080}:8080` 매핑 |
| `APNS_KEY_PATH` | (없으면 stub) | 컨테이너 내부 경로 `/run/secrets/AuthKey_XXX.p8` |
| `APNS_KEY_ID` | (없으면 stub) | 10자 |
| `APNS_TEAM_ID` | (없으면 stub) | 10자 |
| `APNS_TOPIC` | (없으면 stub) | iOS 앱 번들 ID |
| `APNS_HOST` | `api.sandbox.push.apple.com` | sandbox 기본 |

`APNS_*` 네 키(KEY_PATH/KEY_ID/TEAM_ID/TOPIC) 중 하나라도 누락이면 **stub-print 모드** — 매칭 결과를 stderr 에 로깅만, 실제 APNs 호출 없음. Swift 버전과 동일 fallback.

---

## 빌드 / Docker

**Dockerfile (multi-stage)**:
- Stage 1 (builder): `golang:1.23-alpine`
  - `apk add --no-cache git ca-certificates`
  - `WORKDIR /src` → `COPY go.mod go.sum` → `go mod download` → `COPY . .` → `go build -ldflags='-s -w' -trimpath -o /out/nunting ./cmd/server`
  - cross-compile 자동: Pi 에서 빌드 시 Go toolchain 이 host arch(arm64) 로 빌드.
- Stage 2 (runtime): `alpine:3`
  - `apk add --no-cache ca-certificates tzdata`
  - `COPY --from=builder /out/nunting /usr/local/bin/nunting`
  - `EXPOSE 8080`
  - `CMD ["/usr/local/bin/nunting"]`

**빌드 위치 결정**: 라즈베리파이에서 직접 `docker compose build`. Go 는 cross-compile 도 자명하지만(Mac 에서 `GOOS=linux GOARCH=arm64 go build`), 1인 도구라 `git pull && docker compose up -d --build` 한 줄로 끝나는 단순함을 우선. Pi 에서 Go 빌드는 ~30초.

이미지 크기: ~30MB (`alpine:3` base 5MB + Go static binary 20MB + ca-certs/tzdata). Swift 335MB 의 1/10.

**docker-compose.yml**: PR E 에서 다듬은 구조 그대로 carry-over.
- `build: .` (Server/ 안에서 빌드 — Go 는 외부 의존 없음)
- `restart: unless-stopped`, `env_file: .env`, `ports: ${NUNTING_HOST_PORT:-8080}:8080`
- volumes: `./data:/var/lib/nunting`, `./secrets:/run/secrets:ro`
- environment: `NUNTING_BIND_HOST=0.0.0.0`, `NUNTING_BIND_PORT=8080`, `NUNTING_DB_PATH=/var/lib/nunting/state.db`
- logging: `json-file` driver, `max-size: 10m × max-file: 5`

**.dockerignore**: `.git`, `**/.DS_Store`, `data/`, `secrets/`, `.env`, `**/*_test.go` 정도. iOS 디렉토리 제외 불필요(빌드 context 가 `Server/` 안이라 자동 제외).

---

## 에러 처리 정책

- DB 오류: 500 + stderr 로그. Statement 재시도 없음(SQLite single-writer 라 retry 의미 적음 — `BUSY` 발생 시 client 가 재시도).
- APNs 410 `Unregistered`: 해당 `users.push_token = NULL` 로 self-heal. Swift 버전 동일.
- APNs 다른 에러(403 등): stderr 로그, 다음 tick 에 재시도 안 함(이미 새 sentinel). 인증 문제는 운영자가 해결.
- HTML parse 실패: stderr 로그, 그 페이지 skip, 폴러는 계속. 5번 연속 실패 시 backoff? — YAGNI, 1인 도구라 그냥 계속 시도.
- ppomppu 429/5xx: stderr 로그, 그 tick skip. Sentinel 갱신 안 함(다음 tick 에서 다시 시도하게).

---

## 로깅

`log/slog` (Go 1.21+ stdlib) 사용. JSON 핸들러로 stdout 출력 → Docker `json-file` 드라이버가 그대로 수집. 레벨: `INFO` 기본.

주요 로그 이벤트:
- 부팅: `apns_mode=real|stub`, bind addr, db path, poll interval.
- 매 tick: `tick_start`, `new_posts_count`, `apns_sent_count`, `tick_done_ms`.
- 에러: `db_error`, `apns_error_410`, `apns_error_other`, `parse_error`, `fetch_error` (전부 context 포함).

`fmt.Println` / `print` 직접 사용 금지 — 모든 로그는 `slog` 거침.

---

## 테스트 전략

**Unit (Go `testing` 패키지)**:
- `internal/db`: in-memory SQLite(`:memory:`) 로 모든 query 검증. ~10개 테스트.
- `internal/api`: `httptest.NewServer` + in-memory DB 로 라우트별 시나리오 (auth pass/fail, payload shape, 정렬 응답 등). ~12개 테스트.
- `internal/poll/parser`: fixture HTML (실제 ppomppu 응답 한 페이지 저장) 로 추출 검증. ~3-5개 테스트.
- `internal/poll/matcher`: case-insensitive substring 매칭 보더 케이스. ~5개 테스트.
- `internal/apns`: `http.RoundTripper` mock 으로 request shape (path, header, body JSON) + 410 처리 검증. ~5개 테스트.

총 ~35-40 unit tests. `go test ./...` 가 1초 안에 끝나는 게 목표.

**Integration (수동 스모크 — Pi 배포 직전)**:
1. Mac 에서 `docker compose build` 성공.
2. Mac 에서 `NUNTING_HOST_PORT=18080 docker compose up -d` + `curl :18080/health → ok`.
3. iOS 시뮬레이터 baseURL 임시 변경 → push-token PUT → 200.
4. 키워드 추가 → 3분 안에 매칭 글에 푸시 도착 (실제 APNs sandbox).
5. `docker compose restart` 후 keyword/token 보존 확인.
6. 라즈베리파이로 이전 → 4단계 재현.

---

## 마이그레이션 (Swift → Go)

이 PR 머지 시점에 일어나는 일:
- `Server/Sources/`, `Server/Tests/`, `Server/Package.swift`, `Server/Package.resolved` 모두 삭제 (= Swift 코드 zero, 워킹트리에 .swift 파일 0개 in Server/).
- `Server/Sources/CSQLite/` 도 삭제 (SystemLibrary 모듈).
- `Server/go.mod` 등 새 Go 파일들이 그 자리에.
- `Shared/`(NuntingCore SPM) 는 그대로 유지 — iOS 가 계속 사용.
- iOS 빌드: 영향 없음(서버는 분리된 의존성). 그러나 implementation plan 의 verification 단계에서 `xcodebuild` 한 번 돌려 확인.

---

## 합의된 결정 요약

| 항목 | 결정 |
|---|---|
| 언어 | Go 1.23+ |
| HTTP 프레임워크 | `chi` (net/http stdlib + 가벼운 라우터) |
| SQLite | `modernc.org/sqlite` (pure Go, CGO 없음) |
| HTML | `goquery` |
| APNs | `github.com/sideshow/apns2` |
| 로깅 | `log/slog` stdlib + JSON 핸들러 |
| 빌드 위치 | 라즈베리파이에서 직접 `docker compose build` |
| 런타임 베이스 | `alpine:3` (+ ca-certificates, tzdata) |
| 컨테이너 사용자 | root (1인 도구 scope — 추후 `nonroot` 검토 가능) |
| DB 스키마 | Swift 버전 그대로 (users + keyword_subs + index) |
| 폴러 sentinel | in-memory (재시작 시 reset, 첫 tick 알림 skip) |
| iOS 클라이언트 영향 | zero |
| Branch | `server-go` |
