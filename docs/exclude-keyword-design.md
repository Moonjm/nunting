# 제외 키워드 (행별 포함/제외) 설계

작성일: 2026-06-04
대상: ppomppu 키워드 알림 (`Server/internal/poll`, `Server/internal/db`, `Server/internal/api`, `nunting/Services/AlertSubscriptionService.swift`, `nunting/Views/KeywordListView.swift`)

## 1. 목표

각 키워드 구독 행에 **제외 단어**를 붙인다. 어떤 글이 그 행의 **포함 키워드**에 매칭되더라도, 같은 제목에 그 행의 **제외 단어**가 하나라도 있으면 알림에서 제외한다.

> 예: 포함 `갤럭시`, 제외 `중고, 판매` → "갤럭시 S24 사용기" 알림 O / "갤럭시 중고 판매합니다" 알림 X.

범위는 **행별(per-row)**. 제외는 전역 공통이 아니라 각 포함 키워드(=구독 행)마다 따로 설정한다.

## 2. 매칭 의미론

한 구독 행 = `(포함 CSV, 제외 CSV)`. 둘 다 정규화된 CSV(소문자, trim, dedup, 정렬).

한 행이 글 제목 `T`에 **걸린다(=알림 대상)** 의 정의:

```
hit(행, T)  ==  MatchTitle(T, 포함)  AND  NOT excludeHit(T, 제외)
```

- `MatchTitle` (기존, `matcher.go`): 포함 토큰이 **모두** `T`에 substring 으로 존재(콤마 = AND). 변경 없음.
- `excludeHit` (신규): 제외 토큰 중 **하나라도** `T`에 substring 으로 존재하면 true(콤마 = OR). 제외 CSV 가 비면 항상 false(= 제외 안 함, 기존 동작).
- 검사 범위는 포함과 동일하게 **제목만**, case-insensitive.
- 한 사용자의 여러 행은 여전히 OR: 어떤 행이든 `hit`이면 알림. 사용자당 1글 1알림(기존 "첫 매칭만" 유지)은 그대로.

포함은 AND, 제외는 OR 인 점이 핵심 — "이 단어들이 다 있고, 저 단어들은 하나도 없을 때".

## 3. 데이터 모델

기존:

```sql
CREATE TABLE keyword_subs (
    uuid    TEXT NOT NULL,
    keyword TEXT NOT NULL,
    PRIMARY KEY (uuid, keyword),
    FOREIGN KEY (uuid) REFERENCES users(uuid) ON DELETE CASCADE
);
```

변경: `exclude` 컬럼 1개 추가. PK는 `(uuid, keyword)` 유지 → 포함 그룹 1개당 제외 1세트.

```sql
ALTER TABLE keyword_subs ADD COLUMN exclude TEXT NOT NULL DEFAULT '';
```

- 신규 DB: `CREATE TABLE` 정의에 `exclude TEXT NOT NULL DEFAULT ''` 포함.
- 기존 DB: 시작 시 idempotent 마이그레이션으로 `ALTER TABLE`. SQLite 는 컬럼 중복 시 에러를 내므로, `PRAGMA table_info(keyword_subs)` 로 `exclude` 존재 확인 후에만 ALTER (또는 "duplicate column name" 에러를 무시). 기존 행은 `exclude=''` 가 되어 **현재와 동일하게 동작**(제외 없음).

`alert_history` 는 변경 없음 — 제외로 빠진 글은 애초에 알림이 안 나가므로 기록할 것이 없다.

## 4. 서버 변경

### 4.1 매처 (`Server/internal/poll/matcher.go`)

`excludeHit` 추가 (제목에 제외 토큰이 하나라도 있으면 true; 빈 CSV → false):

```go
// excludeHit 제목에 exclude CSV 의 토큰이 하나라도 substring 으로 있으면 true.
// 빈 exclude 는 false(제외 없음). lowerTitle 은 호출자가 ToLower 한 값.
func excludeHit(lowerTitle, exclude string) bool {
    for _, t := range strings.Split(exclude, ",") {
        t = strings.TrimSpace(t) // 저장 시 lowercase 정규화됨
        if t == "" {
            continue
        }
        if strings.Contains(lowerTitle, t) {
            return true
        }
    }
    return false
}
```

### 4.2 매칭 (`Server/internal/db/sqlite.go` — `MatchedUsersForTitle`)

쿼리에 `k.exclude` 추가, 행 판정에 제외 검사 추가:

```go
rows, err := s.db.QueryContext(ctx, `
    SELECT u.uuid, u.push_token, k.keyword, k.exclude
    FROM keyword_subs k
    JOIN users u ON u.uuid = k.uuid
    WHERE u.push_token IS NOT NULL
    ORDER BY u.uuid, k.keyword`)
...
// 행 루프 안 (Scan 에 exclude 컬럼 1개 추가):
var exclude string
if err := rows.Scan(&m.UUID, &m.PushToken, &m.Keyword, &exclude); err != nil { ... }
if seen[m.UUID] { continue }
if !titleContainsAllTokens(lowerTitle, m.Keyword) { continue }
if excludeHit(lowerTitle, exclude) { continue } // ← 제외 단어 있으면 이 행 탈락
seen[m.UUID] = true
out = append(out, m)
```

"사용자당 첫 매칭만" 의미는 유지하되, 이제 **포함O·제외X** 인 첫 행이 선택된다. 어떤 행이 제외로 탈락하면 그 사용자의 다음 행으로 계속 진행(현재 코드는 `seen` 가드로 첫 매칭에서 멈추므로, 제외 탈락 시 `seen` 을 세우지 않고 continue 하면 자연히 다음 행을 본다).

> 참고: `excludeHit` 은 `poll` 패키지, `MatchedUsersForTitle` 은 `db` 패키지다. `db` 가 `poll` 을 import 하면 순환 우려가 있으므로, `excludeHit` 과 짝인 `titleContainsAllTokens` 처럼 **`db` 패키지 안에 동일 로직을 두거나** 공용 헬퍼 패키지로 뺀다. 현재 `titleContainsAllTokens` 가 이미 `db` 에 복제돼 있으니 같은 방식으로 `db` 에 `excludeHit` 을 둔다.

### 4.3 스토어 (`Server/internal/db/sqlite.go`)

- `AddKeyword` → 포함+제외 **upsert** 로 확장(이름은 `UpsertKeyword` 가 더 정확):

```go
func (s *Store) UpsertKeyword(ctx context.Context, uuid, keyword, exclude string) error {
    if keyword == "" { return nil }
    _, err := s.db.ExecContext(ctx, `
        INSERT INTO keyword_subs (uuid, keyword, exclude) VALUES (?, ?, ?)
        ON CONFLICT(uuid, keyword) DO UPDATE SET exclude = excluded.exclude`,
        uuid, keyword, exclude)
    return err
}
```

- `ListKeywords` → `(keyword, exclude)` 쌍 반환하도록 시그니처/반환 타입 변경(`[]KeywordSub`).
- `RemoveKeyword` 변경 없음(포함 키워드 = 행 식별자).

### 4.4 API (`Server/internal/api`)

객체 형태로 변경(개인 도구라 breaking 무방, 클라/서버 동시 배포):

| 메서드 | 경로 | 요청 | 응답 |
|---|---|---|---|
| GET | `/me/keywords` | — | `[{"keyword":"갤럭시","exclude":"중고,판매"}, ...]` |
| POST | `/me/keywords` | `{"keyword":"갤럭시","exclude":"중고, 판매"}` | `{"keyword":"갤럭시","exclude":"중고,판매"}` (upsert) |
| DELETE | `/me/keywords/{keyword}` | — | 기존과 동일 |

- `keyword`, `exclude` 둘 다 `normalizeKeyword` 로 정규화(소문자/trim/dedup/정렬). 길이 검증도 양쪽에 적용(raw ≤ 500B, 정규화 ≤ 50B).
- `exclude` 누락/빈 문자열 허용(= 제외 없음). `keyword` 는 기존대로 필수.
- POST 는 동일 `keyword` 면 제외만 갱신(편집 통로 겸용).

## 5. 클라이언트 변경

### 5.1 모델 / 서비스 (`AlertSubscriptionService.swift`)

```swift
struct KeywordSub: Codable, Hashable, Identifiable {
    let keyword: String   // 포함 CSV (정규화)
    let exclude: String   // 제외 CSV (정규화, 없으면 "")
    var id: String { keyword }
}
```

- `listKeywords() async throws -> [KeywordSub]` (기존 `[String]` → `[KeywordSub]`).
- `upsertKeyword(keyword: String, exclude: String) async throws -> KeywordSub` (기존 `addKeyword(_:)` 대체; `{keyword, exclude}` 전송, 정규화된 객체 수신).
- `removeKeyword(_ keyword: String)` 변경 없음.

### 5.2 UI (`KeywordListView.swift`) — 단일 필드 + `-` 접두 (A안)

기존의 "콤마로 토큰을 빠르게 치는" 한 줄 입력을 유지하고, **토큰 앞에 `-`를 붙이면 제외**가 된다. 한 행 = 한 입력 문자열이라 추가·편집·표시가 모두 한 형식으로 통일된다.

- 상태: `[String]` → `[KeywordSub]`.
- **입력 파싱** (클라에서 입력 문자열 → 포함/제외 raw 로 분리; 정규화는 서버):

  ```
  tokens   = input.split(",").map(trim).filter(nonempty)
  exclude  = tokens 중 "-" 로 시작 → 앞의 "-" 1개 제거 후 trim (빈 건 버림)
  include  = 나머지 토큰
  → upsertKeyword(keyword: include.joined(","), exclude: exclude.joined(","))
  ```

  예: `갤럭시, s24, -중고, -판매` → 포함 `갤럭시,s24`(AND), 제외 `중고,판매`(OR).

- **행 표시**: 한 행에 포함·제외 칩을 **같은 줄에 그대로** 나열하되, **제외 칩만 배경색**(빨강 계열)으로 구분. "제외" 라벨이나 줄 분리 없음.
- **빠른 추가**: 상단 입력에 위 형식으로 치고 추가 → 한 번에 포함+제외 행 생성. placeholder `예: 갤럭시, -중고  ( -는 제외 )` + 작은 힌트로 `-` 규칙 안내.
- **행 편집(신규 기능)**: 행을 탭하면 입력 필드에 그 행의 문자열(`갤럭시, -중고, -판매`)이 채워진다. 고쳐서 저장하면:
  - 포함 토큰셋이 그대로면 → `upsertKeyword`(제외만 갱신, POST 1회).
  - 포함이 바뀌면 PK(=keyword)가 달라지므로 → 이전 행 `removeKeyword(K_old)` 후 `upsertKeyword(K_new, exclude)`. (행 원본 `KeywordSub.keyword` 로 K_old 식별.)
- 삭제: 기존 drag-to-delete 유지.

```
┌──────────────────────────────────────────┐
│ [ 갤럭시, -중고, -판매          ] [추가]   │   placeholder: "예: 갤럭시, -중고 ( -는 제외 )"
├──────────────────────────────────────────┤
│  [갤럭시] [중고] [판매]              ⌫     │   ← 갤럭시=기본색, 중고·판매=빨강 배경
│  [삼다수] [500ml]                   ⌫     │   ← 제외 없는 행
└──────────────────────────────────────────┘
   행 탭 → 위 입력칸에 "갤럭시, -중고, -판매" 채워 재편집
```

## 6. 하위 호환

- 기존 구독 행 → `exclude=''` → 제외 없이 현재와 100% 동일 동작.
- API 객체화는 클라/서버를 함께 배포(개인 도구라 구버전 클라 호환 불필요).

## 7. 테스트

- **서버 매처** (`matcher_test.go` 패턴): `excludeHit` 단독(토큰 OR, 빈 CSV→false, 대소문자), `hit` 조합(포함O+제외O→탈락, 포함O+제외X→매칭, 포함X→탈락).
- **서버 스토어**: `UpsertKeyword` 신규/제외갱신, `ListKeywords` 가 exclude 동반 반환, `MatchedUsersForTitle` 가 제외 행을 건너뛰고 다음 행으로 진행.
- **서버 API**: POST `{keyword, exclude}` 정규화·검증, GET 객체 배열.
- **클라 서비스**: `KeywordSub` 디코드/인코드, `upsertKeyword` round-trip.

## 8. 결정 사항 / 비범위

- 제외 = OR(어느 하나라도 있으면 탈락). 포함 = AND(기존).
- 입력 UI = **단일 필드 + `-` 접두**(A안). 한 행 = 한 문자열. 표시는 같은 줄 칩, 제외 칩만 배경색.
- **키워드 수정 기능은 이번에 신규**(현재는 추가 + 드래그 삭제만 있음). 행 탭 → 단일 필드 재편집으로 포함·제외 모두 수정 가능. 포함이 바뀌면 PK가 달라지므로 클라가 "이전 행 삭제 + 새 upsert"로 처리.
- `-` 접두 규칙의 발견성은 placeholder + 힌트로 보완. 토큰 중간의 `-`(예: `갤럭시-탭`)는 리터럴(접두 `-` 1개만 제외 플래그).
- `alert_history` 스키마 변경 없음.
- 한글-영문 cross-script 매칭은 기존과 동일하게 안 함(사용자가 둘 다 등록).
