# 전체 개선사항 리뷰 + 서버 인증 설계

- 날짜: 2026-07-10
- 상태: 검토 완료, 착수 전
- 범위: iOS 앱(nunting/), Go 서버(Server/), 파서·테스트 전반
- 방법: 코드 전수 리뷰 (iOS 82파일 / Go 24파일 / 테스트 59파일)

전반 평가: 설계 근거 주석, 로더 분리, 파서 공통화(`BoardParser` 확장 +
`ParserBlockWalker`), 테스트 커버리지 모두 취미 프로젝트 수준을 한참 넘는다.
아래는 일반 위생 지적이 아니라 **실제로 터질 확률이 높은 것** 위주.

SQL 인젝션 없음(전 쿼리 파라미터화), 시크릿(.p8/.env) git 추적 안 됨,
`@unchecked Sendable`/`nonisolated(unsafe)` 사용처는 전부 정당한 근거 주석
동반 — 이상 없음 확인.

---

## 착수 순서 요약

| 순위 | 항목 | 영역 | 크기 |
| --- | --- | --- | --- |
| 1 | 파서 실패 텔레메트리 + 목록 빈결과 센티널 (§1) | iOS+서버 | 중 |
| 2 | 서버 인증 1+2단계 (§2) | 서버 | 중 |
| 3 | WebP 프리즈 게이트 일반화 (§3.1) | iOS | 소 |
| 4 | 나머지 (§3.2~, §4) | — | 소 |

---

## §1. 최우선 — 사이트 구조 변경이 조용히 실패함

11개 사이트 스크레이핑 앱이라 셀렉터 썩는 건 필연인데, 지금은 터져도 알 수
없다. 관측성(observability)이 이 앱의 1번 리스크.

### 1.1 목록 파싱은 구조 변경 감지가 전혀 없음 (High)

- `parseList`는 루트 셀렉터가 0건이면 그냥 `[]` 반환 —
  `ClienParser.swift:15` (`a.list_item.symph-row`), `AagagParser.swift:64`,
  `PpomppuParser.swift:13-16`(2차 셀렉터 후 조용히 빈 배열).
  `structureChanged` throw는 상세/댓글 경로에만 존재(18곳).
- `BoardListLoader.swift:244-258`가 빈 파싱을 **정상 성공으로 커밋**:
  `posts = []`, `loadedKey` 세팅(재진입해도 재시도 안 함), 멀쩡하던
  콜드스타트 스냅샷을 `snapshotStore.save`로 덮어씀.
- 사용자에겐 "글이 없습니다"(`BoardListView.swift:73-83`) — 사이트 개편과
  빈 게시판이 구분 불가.

**수정**: 1페이지 파싱 결과가 비었는데 fetch한 HTML이 실질 페이지 크기
(예: 10KB+)면 `structureChanged`로 처리 — 커밋·스냅샷 저장 건너뛰고 에러
표시 + §1.2 텔레메트리 전송. `loadMore`(`:208-211`)는 기존대로(끝 페이지가
정상적으로 비는 경우가 있음).

### 1.2 감지해도 텔레메트리가 서버로 안 감 (High) ★ 최고 레버리지

- 상세 파서들은 `ParserError.structureChanged`를 던지지만
  (`PpomppuParser.swift:84-88`, `InvenParser.swift:75-79`,
  `EtolandParser.swift:49`, `AagagParser.swift:217` 등)
  `PostDetailLoader.swift:322`에서 `errorMessage`로 끝난다.
- 업로드 채널은 이미 있다: `MetricsReporter` → `AlertSubscriptionService`
  → `/me/metrics`. `(site, "structureChanged", listOrDetail)` 카운트만
  실어 보내면 "사용자 조용히 이탈" → "당일 파악 후 수정"으로 바뀐다.

### 1.3 가장 약한 파서: Etoland, 그다음 Aagag (High)

- Etoland는 Next.js SSR flight blob(`__next_f.push`)을 정규식으로 파며
  (`EtolandParser.swift:83-97`) 자체 주석으로 비결정성 인정(같은 글이
  인라인 댓글일 때도, `BAILOUT_TO_CLIENT_SIDE_RENDERING`일 때도 있음).
  댓글 API URL은 해시된 클라이언트 청크(`0f7oc_gjz_r8m.js`)에서 역공학
  (`:138-140`). 인라인 댓글 추출 실패는 조용히 `[]`(`:312-315`), 인라인
  마커 체크(`:109`)도 형식 바뀌면 배너 없이 댓글 증발. Next.js 빌드 한
  번에 세 군데 동시 파손 가능.
- Aagag는 `AAGAG_AA.content = "..."` 단일 정규식(`AagagParser.swift:17`) +
  커스텀 `[sTag]{json}` 미니 포맷. 단, 스크립트 부재 시 throw는 함.
- 당장 재작성보단 §1.2 텔레메트리로 파손을 즉시 알 수 있게 하는 게 우선.

### 1.4 부수 (Medium)

- `ParserStructureChangedTests.swift:29-55`가 11개 중 7개 파서만 커버.
  Clien/Coolenjoy/Inven/Ppomppu는 프로덕션에선 throw하지만 회귀 테스트
  없음 — 3줄짜리 테스트 4개로 마감.
- `SiteCatalog.swift:33+`(Clien/Coolenjoy/Ppomppu 게시판 메뉴 파싱)도 같은
  셀렉터 취약성인데 감지·셀렉터 테스트 없음(`BoardCatalogStoreTests`는
  fake 사용). 카탈로그 깨지면 보드 서랍이 조용히 빔.
- 파서 테스트는 전부 최소 HTML 리터럴(의도된 선택,
  `ParserListTests.swift:3-15`) — 행동은 잘 고정하지만 실사이트 드리프트엔
  장님. 사이트별 실페이지 캡처 1목록+1상세 체크인 또는 env 게이트 라이브
  스모크 추가 검토.

---

## §2. 서버 인증 설계 (결정 사항)

### 현재 구조와 문제

- iOS가 첫 실행 때 `nnt_<UUID>`를 생성해 Keychain 저장
  (`KeychainUUIDStore`, `AlertSubscriptionService.swift:283`), 매 요청
  Bearer로 전송.
- 서버 `BearerAuth`(`middleware.go:21-44`)는 `nnt_` prefix만 확인하고
  **매 요청 users 테이블 upsert**(`middleware.go:35`).

UUIDv4는 122비트 랜덤이라 타인 토큰 추측은 사실상 불가. 실제 구멍은:

1. **아무 문자열이나 계정이 됨** — `nnt_x`도 통과 → 쓰레기 row 무한 생성,
   그 row로 1MB 메트릭 업로드 가능.
2. **앱 아닌 클라이언트(curl/봇) 구분 불가.**

### 결정: 1단계 + 2단계 시행. 3단계(App Attest)는 보류.

#### 1단계 — 형식 검증 + upsert 분리 (기존 클라이언트 무수정)

```go
// Swift UUID().uuidString 은 대문자 UUIDv4 — 기존 토큰 그대로 통과.
var tokenRe = regexp.MustCompile(
    `^nnt_[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$`)
```

- `BearerAuth`: 정규식 불일치 → 401.
- **upsert를 미들웨어에서 제거**, `PUT /push-token`(등록 성격)에서만 수행.
- 나머지 `/me/*`: users 조회 → 없으면 401. GET만으로 계정 생성 불가,
  비등록 UUID의 메트릭 업로드 차단.
- `/admin/metrics`의 `?key=` → `X-Admin-Key` 헤더로 이동(프록시/CDN 접근
  로그에 비밀이 남는 문제, `metrics.go:67-70`).

#### 2단계 — 등록 게이트 + 레이트리밋

- `PUT /push-token`에 APNs 토큰 형식 검증 `^[0-9a-f]{64}$`
  (`handlers.go:44-66`은 현재 256자 길이캡뿐). 유효한 실기기 APNs 토큰
  없이는 등록 자체가 안 됨 — 위조 토큰은 푸시가 안 가니 실익도 없음.
  겸사겸사 APNs 400/`BadDeviceToken` 응답 시에도 토큰 클리어(현재 410만
  자가치유, `apns/client.go:110` — 불량 토큰이 영구 잔존하며 폴링 루프의
  APNs 왕복 낭비 + `poller_apns_error` 로그 소음).
- `httprate` per-IP 리밋: 등록류 분당 수 회, `/me/metrics`·`/me/footprint`
  시간당 수 회.

#### 3단계 — App Attest (보류)

"진짜 내 앱 바이너리 + 실기기" 증명까지 하려면 App Attest가 정답:
Secure Enclave attestation을 `/register`로 보내 서버가 Apple 인증서 체인
검증 후 서버 발급 토큰 지급. 단 서버 검증 구현(CBOR, 체인)이 크고
시뮬레이터 미지원(개발 우회 필요). **사용자가 본인뿐인 현재는
오버엔지니어링** — 스토어 배포로 사용자가 생기면 그때.

#### 마이그레이션

없음. 본인 폰 Keychain UUID가 정규식 통과, 푸시 토큰 등록도 이미 수행
중이라 users row 존재.

---

## §3. iOS 앱

### 3.1 애니메이션 WebP 프리즈 재발 예약 (High)

`PostDetailView.swift:424-433` — ~14초 직렬 디코드 프리즈(354프레임 WebP가
`SDImageCache` 직렬 ioQueue 점유)를 막는 first-frame-only 게이트가
`posterURL != nil`에 묶여 있는데 poster는 **HumorParser만 세팅**. 주석
스스로 "다른 보드(클리앙/에토랜드/…)의 대형 WebP는 프리즈 재현"이라 명시.
5초 hang을 방금 고친 이력(#136) 감안 시 재발 확률 1순위. 수정: 게이트를
poster 유무가 아니라 파일 확장자+크기 힌트(파서 플래그) 또는 디코드 시점
Content-Length/프레임 수 기준으로.

### 3.2 BoardPager 센티널이 실제 로더를 돌림 (High)

`RootTabView.swift:707-713` — 무한루프 페이저의 head/tail 센티널이 완전한
`BoardListView`(각자 `@State` 로더 + `.task` fetch +
`DetailPrefetcher.prefetch(prefix(3))`, `BoardListView.swift:89-95`).
앱 시작 시 안 볼 수도 있는 마지막 즐겨찾기 보드의 목록 fetch + 상세 3건
프리페치가 실행됨. 또 `ForEach(... id: \.offset)`(`:709`) — 위치 키잉이라
즐겨찾기 순서 변경 시 살아남은 뷰 상태가 엉뚱한 보드에 붙음. 수정: 보이는
페이지만 fetch하는 `isActive` 게이트(네트워크 로그로 검증) + `board.id`
키잉.

### 3.3 FootprintLogger 백그라운드 flush 유실 (Medium)

`FootprintLogger.swift:69-80` — flush가 버퍼를 먼저 비우고 fire-and-forget
POST. `onBackground()`(`RootTabView.swift:295`) 직후 iOS가 suspend하면 OOM
진단에 제일 중요한 순간의 샘플이 증발. 수정:
`UIApplication.beginBackgroundTask`로 감싸기, 또는 전송 실패 시 버퍼 복원,
또는 백그라운드 시 디스크 저장 후 다음 실행 때 업로드.

### 3.4 딥링크 진입 시 상세 헤더가 빈 값 (Medium)

푸시 진입 `DetailOverlayController.present(url:title:)`
(`DetailOverlayController.swift:116-137`)은 `author: ""`, `commentCount: 0`
의 최소 Post를 만드는데, 헤더가 입력 Post를 렌더
(`PostDetailView.swift:135, 140`)라 상세 로딩 완료 후에도 작성자·댓글수
공란. 수정: `loader.detail?.post.author ?? post.author` 식으로 detail 우선
(이미 `fullTitle`/`fullDateText`는 그렇게 함).

### 3.5 KeywordListView가 로더 패턴 미적용 494줄 (Medium)

`KeywordListView.swift:245-407` — `AlertSubscriptionService.shared` 인라인
호출 + 낙관적 업데이트/롤백 상태머신이 뷰 안에. 특히 리네임이
`upsertKeyword` → `removeKeyword(원본)` 2단계(`:314-368`)라 **부분 실패 시
키워드 2개 잔존** 버그. `:256` `try? await fetchAlertHistory()`는 에러
무음 — 네트워크 실패 시 히스토리 탭이 재시도 없이 빈 화면.
`BoardListLoader`/`PostDetailLoader`처럼 `@Observable` KeywordStore 추출.

### 3.6 소소 (Low)

- 셀룰러/저전력 자동재생: `AVPlayerInlineView.swift:322-327`
  `automaticallyWaitsToMinimizeStalling = false` 무조건 — 셀룰러에서 스터터
  루프 + 데이터 소모. `NWPathMonitor.isExpensive` /
  `isLowPowerModeEnabled` 체크(body-media-refactor.md §8 이연 TODO).
- `Networking.swift:166-192` / `:314-343` — transient 재시도 루프 복붙 2벌.
  `withTransientRetry {}` 추출.
- `RootTabView.swift` 929줄/private 타입 8개 — 최소 `BoardPager`(wrap-around
  인덱스 수학이 private라 테스트 불가)와 `GlassFilterBar` 분리.
- `HistoryResumeHandle`(`RootTabView.swift:801-815`) `.black` 하드코딩 —
  다크모드 glass에서 대비 소실. `.primary`로.
- `ReadStore.swift:85-99` — 글 열 때마다 5000개 ID 전체(~80KB JSON) 재기록.
  trailing write 디바운스 또는 append-only 로그.

---

## §4. 파서 중복 정리 (Low, 리팩터링 기회)

전체 중복률은 낮은 편(공유 스캐폴딩 우수) — 남은 3개 클러스터:

1. **삭제 안내 감지 ×7**: `body.contains("삭제") || …` + 같은 문구 리터럴
   (`AagagParser.swift:216-221`, `Cook82Parser.swift:39-44`,
   `EtolandParser.swift:47-53`, `DdanziParser.swift:40-45`,
   `HumorParser.swift:61-66`, `SLRParser.swift:32-37`,
   `BobaeParser.swift:33-36`) — 키워드 셋이 제각각이라 드리프트 위험.
   `deletionNotice(keywords:)` 헬퍼로 추출.
2. **댓글 ID 포맷 ×13**: `"\(site.rawValue)-c-\(id)"` 수기 반복, 3곳은
   사이트 문자열 하드코딩(`DdanziParser.swift:286`,
   `EtolandParser.swift:431`, `SLRParser.swift:258`).
3. **댓글 페이저 추출 ×3**: `BobaeParser.swift:154-176`,
   `CoolenjoyParser.swift:87`, `DdanziParser.swift:305-323`.

신규 사이트 추가 마찰은 중간 수준 — 라우팅 switch가 전부 exhaustive라
컴파일러가 터치 포인트를 열거해줌(좋음). 미러 전용 사이트는 저렴, 완전
브라우징 사이트는 목록/댓글 셀렉터가 bespoke라 하루+.
