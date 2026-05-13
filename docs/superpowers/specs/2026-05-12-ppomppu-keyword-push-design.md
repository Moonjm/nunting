# Ppomppu 키워드 푸시 알림 — 설계

작성일: 2026-05-12
상태: 검토 중
관련 코드: `nunting/Parsers/PpomppuParser.swift`, `nunting/Views/SideDrawer.swift`, `nunting/Services/DetailOverlayController.swift`

## 목적

뽐뿌 게시판(현재는 `id=ppomppu` 한 보드)에 본인이 등록한 키워드가 들어간 글이 새로 올라오면 iOS 푸시 알림을 받고, 탭하면 그 글 상세 화면이 바로 열린다.

## 비목표 (이번 범위 밖)

- 멀티 보드: 뽐뿌의 다른 보드(뽐뿌게시판/자유/유머 등)나 뽐뿌 외 사이트는 다음 단계. 데이터 모델은 보드 식별자 컬럼을 두어 자연스럽게 확장 가능하게 둠.
- 공개 배포: 본 앱은 App Store/TestFlight 공개 배포를 하지 않는 개인용 사이드로드 도구. 인증/내성을 그 가정 위에서 설계.
- 키워드 정규식/조합 표현식: 단순 부분 일치(`contains`)로 v1 마감. 본격 규칙 엔진은 사용 빈도 보고 추가.
- 푸시 알림 사운드/그룹/뱃지 커스터마이즈: 기본 사운드 + 단일 알림.

## 핵심 결정 사항

| 영역 | 결정 | 근거 |
|------|------|------|
| 백엔드 런타임 | 본인 소유 라즈베리파이 | 호스팅 비용 0, 외부 서비스 의존 최소화 |
| 외부 노출 | Cloudflare Tunnel (`cloudflared` 데몬) | 포트포워딩/DDNS 불필요, 무료 HTTPS, rate limit/WAF 무료 |
| 백엔드 언어/프레임워크 | Swift + Hummingbird | `PpomppuParser.swift` 그대로 재사용; Hummingbird는 HTTP 라우팅 5개 + 크론 1개에 맞는 가벼움 |
| 코드 레이아웃 | 같은 git repo의 monorepo, 로컬 SPM 패키지 두 개 | 파서 단일 소스 유지; Xcode/Swift 빌드 시스템 모두 자연스럽게 동거 |
| 저장소 | SQLite (`/var/lib/nunting/state.db`) | 1인 도구 규모에 PostgreSQL은 과함; 마이그레이션은 ALTER TABLE 직접 실행으로 충분 |
| 인증 | Keychain의 클라 생성 UUID(prefix `nnt_`)를 Bearer 토큰으로 사용 | 비공개 배포 가정 + Cloudflare rate limit으로 abuse 거름; 화면상 "로그인" 없음 |
| 폴링 cadence | 3분 | 뽐뿌 인기글 회전 속도 대비 충분; Pi 부하/뽐뿌 부담 모두 무시 가능 |
| 폴링 알고리즘 | Sentinel walk (page=1부터 시작, last_seen_post_id 만날 때까지 뒤로 페이지 증분) | 3분 사이 30개 이상 들어와도 누락 없음 |
| `lastSeenPostId` 보관 | 메모리(비영속) | 재시작 시 "첫 실행" 경로로 자동 복귀; sentinel을 정상적으로 만나지 못하는 유일한 시나리오는 그 사이 글 삭제 정도라 페이지 cap은 sanity check 수준(10페이지)만 |
| 키워드 매칭 | `title.contains(keyword)` (정규화: lowercased + trim) | v1 단순성 우선 |
| 푸시 페이로드 | `{ aps: { alert, sound }, url }` | iOS 측 deep link 한 줄(`DetailOverlayController`)로 처리 |
| iOS foreground 동작 | 시스템 배너(`.banner`) | 커스텀 토스트 추가 코드 0; 탭하면 background와 동일 경로 |
| 키워드 관리 UI 위치 | `SideDrawer` 하위 항목 → 새 `KeywordListView` | 기존 패턴과 일치, 진입 1탭 |

## 아키텍처 전체

```
iOS App
  │  UUID(Keychain, "nnt_…") + APNs deviceToken
  │
  ▼  HTTPS, Authorization: Bearer nnt_<uuid>
Cloudflare Tunnel  (rate limit: 60req/min/IP, dashboard 설정)
  │
  ▼
Raspberry Pi
  ├ Hummingbird HTTP server  ──┐
  │   PUT  /me/push-token       │
  │   GET  /me/keywords         │ → SQLite
  │   POST /me/keywords         │
  │   DEL  /me/keywords/{k}     │
  │                              ┘
  ├ Poller (3-min cron)
  │   1. fetch ppomppu page=1,2,... (sentinel walk)
  │   2. for new posts: match keywords across users
  │   3. enqueue APNs sends
  │
  └ APNs Client (HTTP/2 outbound to api.push.apple.com)
        - .p8 key + JWT (ES256)
        - 410 Unregistered → push_token = NULL
```

## 디렉터리 / 패키지 구조

```
nunting/                          # 기존 repo 루트
├── Shared/                       # 신규: 로컬 SPM 패키지 (iOS + 서버 공통)
│   ├── Package.swift
│   ├── Sources/NuntingCore/
│   │   ├── BoardParser.swift     ─┐
│   │   ├── PpomppuParser.swift   │ 기존 nunting/Parsers/ 에서 이동
│   │   ├── Post.swift            │
│   │   ├── Board.swift           │
│   │   └── Site.swift            ─┘
│   └── Tests/NuntingCoreTests/
│
├── Server/                       # 신규: Hummingbird executable SPM 패키지
│   ├── Package.swift             # dependencies: [.package(path: "../Shared")]
│   ├── Sources/NuntingServer/
│   │   ├── main.swift
│   │   ├── Routes/
│   │   │   ├── PushTokenRoute.swift
│   │   │   └── KeywordRoutes.swift
│   │   ├── Auth/BearerMiddleware.swift
│   │   ├── DB/Schema.swift
│   │   ├── DB/Store.swift
│   │   ├── Poller/PpomppuPoller.swift
│   │   ├── Poller/KeywordMatcher.swift
│   │   └── APNs/APNsClient.swift
│   └── Tests/NuntingServerTests/
│
├── nunting/                      # 기존 iOS 앱 (그대로)
├── nunting.xcodeproj             # Local Package: Shared 추가
└── nuntingTests/
```

iOS 앱은 `Shared/`를 Local SPM Package로 추가하고, 현재 `nunting/Parsers/` 아래에 있는 파일들을 그 패키지로 이동한 뒤 `import NuntingCore`로 참조. 일회성 리팩토링은 별도 PR로 분리.

## 데이터 모델 (SQLite)

```sql
CREATE TABLE users (
    uuid       TEXT PRIMARY KEY,            -- "nnt_xxxxx"
    push_token TEXT,                        -- APNs deviceToken (hex string), NULL 가능
    created_at INTEGER NOT NULL             -- Unix epoch seconds
);

CREATE TABLE keyword_subs (
    uuid    TEXT NOT NULL,
    keyword TEXT NOT NULL,                  -- lowercased + trimmed 상태로 저장
    PRIMARY KEY (uuid, keyword),
    FOREIGN KEY (uuid) REFERENCES users(uuid) ON DELETE CASCADE
);

CREATE INDEX idx_users_with_token
    ON users(uuid)
    WHERE push_token IS NOT NULL;
```

- `seen_posts` 테이블 없음. 폴링이 `lastSeenPostId` 메모리 변수 하나로 dedup.
- 키워드는 사용자가 입력한 원문이 아니라 매칭 정규화 후 저장(공백 양 끝 제거, lowercase). 한글은 lowercase 무효지만 영문 키워드 위해 통일.

## API

전부 `Authorization: Bearer nnt_<uuid>` 헤더 필수. prefix 검사 실패 시 401. 헤더 통과 시 `users` upsert.

### `PUT /me/push-token`

```http
PUT /me/push-token
Authorization: Bearer nnt_xxx
Content-Type: application/json

{ "token": "aabbccdd..." }
```

- 응답: 204 No Content
- 동작: `users.push_token = ?` upsert. NULL("토큰 무효" 상태)로도 받을 수 있어야 함 (iOS가 알림 권한 회수했을 때).

### `GET /me/keywords`

```http
GET /me/keywords
```

- 응답: `["갤럭시", "맥북 m4"]`

### `POST /me/keywords`

```http
POST /me/keywords
Content-Type: application/json

{ "keyword": "갤럭시" }
```

- 응답: 201 Created. 본문에 정규화 후 저장된 키워드 echo.
- 동작: trim + lowercase. 빈 문자열은 400. 50자 초과면 400.
- 중복은 멱등(이미 있어도 201).

### `DELETE /me/keywords/{keyword}`

URL의 `{keyword}`는 URL-encoded 정규화된 키워드.

- 응답: 204. 없어도 204(멱등).

## 인증 / 봇 차단

- 클라(iOS): 첫 실행 시 Keychain에 `"nnt_" + UUID().uuidString` 저장. 이후 모든 요청에 `Authorization: Bearer ` + 저장값.
- 서버:
  1. `Authorization` 헤더 파싱, `Bearer nnt_` prefix 없으면 401 즉시 반환.
  2. 통과한 토큰을 그대로 `users.uuid`로 사용. 없으면 INSERT, 있으면 그 row 사용.
- Cloudflare Tunnel 앞단에 IP당 분당 60 요청 rate limit 설정. UUID 추측해도 무차별 등록을 막음.
- App Attest는 v1에 도입하지 않음. 비공개 배포라 RE를 통한 prefix 노출 위협 모델이 사실상 없음.

## 폴링 알고리즘

```swift
// PpomppuPoller.swift 의사 코드
actor PpomppuPoller {
    private var lastSeenPostId: String?      // 메모리, persistent 하지 않음
    private let maxBootstrapPages = 1        // 첫 실행 시 page=1만 본다

    func tick() async {
        var page = 1
        var newPosts: [Post] = []

        // 첫 실행: sentinel 설정만 하고 종료
        guard let sentinel = lastSeenPostId else {
            let posts = try await fetchAndParse(page: 1)
            if let top = posts.first(where: { !$0.isNotice }) {
                lastSeenPostId = top.postNo
            }
            return
        }

        outer: while true {
            let posts = try await fetchAndParse(page: page)
            for post in posts {
                if post.isNotice { continue }    // 공지 행은 매번 같은 ID로 보임
                if post.postNo == sentinel { break outer }
                newPosts.append(post)
            }
            page += 1
            // Sanity cap. 3분 사이에 100개 넘는 새 글이 들어왔거나(현실적
            // 으로 불가) sentinel 글이 그 사이 삭제된 비정상 케이스 대비.
            // 평소엔 1~2 페이지 안쪽에서 break 됨.
            if page > 10 {
                Log.warn("sentinel walk hit page cap, possible deleted last_seen post")
                break outer
            }
        }

        // 오래된 것부터 알림 보내기 위해 역순
        newPosts.reverse()

        // 키워드 매칭 → APNs 큐
        if !newPosts.isEmpty {
            await dispatchToMatchingUsers(newPosts)
            lastSeenPostId = newPosts.last!.postNo
        }
    }
}
```

매칭 단계는 `keyword_subs`를 한 번 SELECT 해서 `[uuid: Set<keyword>]` 인메모리 맵을 만든 뒤, 각 새 글에 대해 모든 사용자의 모든 키워드와 `String.contains` 검사. v1 사용자 수 ≪ 100이라 N×M 시간 복잡도로 충분.

## 푸시 페이로드 / iOS 측 처리

```json
{
  "aps": {
    "alert": {
      "title": "뽐뿌 — 갤럭시",
      "body": "갤럭시 S25 핫딜 19만원"
    },
    "sound": "default"
  },
  "url": "https://www.ppomppu.co.kr/zboard/view.php?id=ppomppu&no=12345678"
}
```

- `aps.alert.title`은 매칭된 키워드를 포함해 어떤 키워드로 잡혔는지 한눈에 보임.
- `aps.alert.body`는 글 제목 그대로.
- 커스텀 키 `url`은 iOS의 `didReceive` 핸들러가 deep-link로 사용. 글 식별을 `boardId+postNo`가 아닌 URL로 두는 이유: 향후 사이트 추가 시 라우팅 분기를 늘리지 않고 URL → 적절한 detail view로 매핑할 수 있음.

iOS 측 변경 지점:

1. **`nuntingApp.swift`** — `@UIApplicationDelegateAdaptor` 도입, AppDelegate에서:
   - `application(_:didFinishLaunchingWithOptions:)`에서 `UNUserNotificationCenter.current().delegate = self`
   - 권한 요청은 첫 키워드 추가 시점에 (앱 시작 시 흩뿌리지 않음)
   - `registerForRemoteNotifications()` 호출
   - `didRegisterForRemoteNotificationsWithDeviceToken`에서 토큰 hex 변환 후 서버에 PUT
2. **`SideDrawer.swift`** — "알림 키워드" 항목 추가. 누르면 `KeywordListView` push.
3. **신규 `nunting/Views/KeywordListView.swift`** — 리스트 + 추가/삭제 UI. API 호출은 신규 `nunting/Services/AlertSubscriptionService.swift`로 위임.
4. **신규 `nunting/Services/AlertSubscriptionService.swift`** — UUID 발급/조회, 4개 엔드포인트 클라이언트.
5. **UNUserNotificationCenterDelegate 구현 (AppDelegate에 직접 또는 신규 코디네이터)**:
   - `willPresent`: foreground 시 `[.banner, .sound]` 반환 → 시스템 배너 표시
   - `didReceive`: payload의 `url` 읽어 `DetailOverlayController.shared.present(url:)` 호출

## APNs 전송

- HTTP/2 + JWT (ES256) 인증. `.p8` key 파일 + Team ID + Key ID + Topic(bundle ID) 환경변수.
- 한 알림 = 한 push_token에 POST `https://api.push.apple.com/3/device/<token>`.
- 응답 코드 처리:
  - 200: 성공
  - 410: 토큰 무효 → `UPDATE users SET push_token = NULL WHERE push_token = ?`
  - 429/500/503: 백오프 후 재시도(최대 3회)
  - 그 외 4xx: 로그 + 폐기
- v1은 Swift의 `URLSession` HTTP/2 그대로 사용 (외부 APNs Swift 라이브러리 도입은 추후).

## 키워드 매칭 정규화

- 저장: `keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()` 결과만 DB에 들어감.
- 매칭: `post.title.lowercased().contains(normalized_keyword)`.
- 한글은 lowercase가 사실상 무효이지만 영문/숫자 키워드(`m4`, `RTX5090`)와 일관 동작 보장.
- 공백 양끝 제거 외에 내부 공백은 그대로 둠. "갤럭시 S25"는 "갤럭시 S25"와만 매칭.

## 배포 / 운영

### 라즈베리파이 setup

- OS: Raspberry Pi OS 64-bit (arm64).
- 컨테이너 vs 직접: **Docker** 선택. 이미지가 Swift 빌드 환경 + 런타임을 격리하고, `docker compose` 한 줄로 cloudflared와 함께 띄움. Pi OS 호스트는 손대지 않음.
- `docker-compose.yml` 골격:
  - `nunting-server`: 빌드한 NuntingServer 이미지. 볼륨으로 `/var/lib/nunting`(SQLite)과 `/etc/nunting/auth.p8`(APNs key) 마운트. healthcheck로 자기 자신의 `/health` 폴.
  - `cloudflared`: Cloudflare 공식 이미지. tunnel 토큰을 env로 받음. `nunting-server:8080`으로 라우팅.

### Cloudflare Tunnel 설정

- Cloudflare 대시보드에서 새 Tunnel 생성, hostname 하나(`nunting.<your-domain>`)를 Pi의 `nunting-server:8080`로 매핑.
- Cloudflare WAF 규칙: 분당 60 req/IP, 분당 500 req 글로벌. 초과 시 429.
- TLS는 Cloudflare가 처리. Pi 내부는 평문 HTTP/2.

### 빌드 / 배포 흐름

- 개발: macOS에서 `swift build` (NuntingServer 자체는 macOS에서도 컴파일됨, 배포 산출물은 Linux arm64).
- 배포: GitHub Actions(또는 로컬 스크립트)로 cross-compile, Docker 이미지 빌드, Pi에 SSH 후 `docker compose pull && up -d`. v1은 단순화를 위해 수동 스크립트로 시작.

## 에러 / 엣지 케이스

- **APNs 키 만료/잘못된 환경변수**: 서버 부팅 시 startup check에서 JWT 한 번 생성 시도, 실패면 로그 + exit. 그래야 데몬 자동재시작이 빠르게 알람으로 이어짐.
- **뽐뿌 HTML 구조 변경**: `PpomppuParser`가 빈 배열을 반환하기 시작함. 폴러는 마지막 N(예: 10)회 연속 빈 결과면 경고 로그.
- **SQLite 파일 권한**: `/var/lib/nunting/` 디렉터리 컨테이너 마운트 시 소유자 일치 필요. Compose에서 `user:` 명시.
- **알림 권한 거부**: iOS는 권한 없으면 `didRegisterForRemoteNotificationsWithError`가 호출. 키워드 추가 시점에 권한 안내 메시지 → 거부하면 키워드 저장은 가능하지만 알림은 안 옴(서버는 push_token NULL).
- **앱 재설치**: iOS Keychain은 기본적으로 앱 삭제 후 재설치 시 보존됨(기본 `kSecAttrAccessible.afterFirstUnlock`). 즉 UUID 유지. APNs 토큰은 새로 발급되므로 PUT으로 갱신.
- **iCloud 다른 디바이스**: Keychain 아이템 저장 시 `kSecAttrSynchronizable = true`를 함께 지정하면 같은 Apple ID의 다른 디바이스가 같은 UUID를 사용 → 같은 키워드 구독 공유 + 두 디바이스 모두 알림 수신. APNs `push_token`은 디바이스마다 별도이므로 서버 측 `users.push_token`은 UUID당 마지막 디바이스 토큰만 남겨두는 v1 단순화로 가고(= 최근 등록 디바이스 한 곳만 알림), 멀티 디바이스 알림은 후속에서 `device_tokens(uuid, token)` 테이블로 확장.
- **공지 글**: `PpomppuParser`가 `hotpop_bg_color`만 거름. 다른 종류 공지는 `Post.category` 또는 URL의 다른 시그널로 한 번 더 필터(폴러 측에서). 새 보드 추가 시 재검토.

## 테스트 전략

### NuntingCore (파서)

- 기존 `nuntingTests/ParserDetailTests.swift` 패턴 따라 `NuntingCoreTests`에 Ppomppu list HTML fixture를 두고 `parseList(html:board:)` 단위 테스트.
- HTML 변경 감지: 매주 한 번 실제 페이지 받아서 `parseList`가 30개 안팎 반환하는지 smoke test (CI 옵션).

### NuntingServer

- API: Hummingbird의 in-memory test client로 4개 엔드포인트 X 정상/누락 토큰/잘못된 prefix 케이스 단위 테스트.
- 폴러: `fetchHTML`을 stub으로 주입해 sentinel walk 알고리즘 시나리오(첫 실행 / 새 글 0개 / 새 글 5개 / 페이지 2까지 걸침 / sentinel 못 만남) 검증.
- APNs: 실제 전송은 통합 테스트(개발용 APNs sandbox host로 실 디바이스에 한 발)로만. 단위 테스트는 페이로드 직렬화 + JWT 서명 형태만.

### iOS

- 새 서비스 `AlertSubscriptionService`는 URLSession을 protocol로 추상화해 테스트 가능하게.
- KeywordListView는 SwiftUI Preview로 시각 검증.
- 푸시 deep-link 흐름은 시뮬레이터에서 `xcrun simctl push` JSON 파일로 수동 검증.

## 마이그레이션 / 단계적 도입

1. **PR A — 파서 추출 리팩토링** (단일 PR로 끊기, 기능 변화 0)
   - `Shared/` SPM 패키지 신설, `Parsers/*.swift`와 관련 모델 이동.
   - iOS Xcode 프로젝트의 target membership 갱신, `import NuntingCore` 추가.
   - 기존 동작/테스트 모두 통과 확인.
2. **PR B — 서버 minimum** (라우트 4개 + SQLite + 인증, 폴링은 아직)
   - Hummingbird 보일러플레이트, BearerMiddleware, Store.
   - macOS에서 통합 테스트 → Pi 배포 → curl로 keyword CRUD 확인.
3. **PR C — 폴러 + APNs**
   - `PpomppuPoller`, `KeywordMatcher`, `APNsClient`.
   - 실제 푸시 한 발 받아 deep-link까지 동작 확인 (iOS는 아직 placeholder).
4. **PR D — iOS UI/AppDelegate**
   - SideDrawer 항목, KeywordListView, AlertSubscriptionService.
   - AppDelegate의 알림 권한/토큰 등록/willPresent/didReceive.
5. **PR E — Docker compose + Cloudflare Tunnel 운영 가이드**
   - 설정 파일, README, 운영 노트.

## 미해결 / 후속

- 다중 보드 확장 시 `Poller`를 보드별 인스턴스로 분리하고 `users.boards` 같은 구독 정보 추가. 데이터 모델 확장은 단순(`keyword_subs`에 `board` 컬럼 추가).
- 키워드 통계(몇 번 매칭됐는지)는 v1 비목표. 필요해지면 `match_log(uuid, keyword, post_no, sent_at)` 추가.
- 키워드별 음소거 시간대(예: 새벽엔 알림 X)도 추후.
- 다른 사이트(클리앙/인벤 등) 추가는 NuntingCore의 다른 파서를 활성화하면 거의 그대로 구현 가능.
