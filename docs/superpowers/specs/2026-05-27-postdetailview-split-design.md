# PostDetailView 파일 분할 설계

`Views/PostDetailView.swift` (932줄) 를 응집 단위별로 5파일로 분할한다.
외부 동작 변경 없는 mechanical move + 명명 정리 + 가시성 한 단계 완화 (`private` → `internal`).

## 배경

- `docs/refactor-followups.md` §2 항목. 700+줄 SwiftUI view 파일이 다음 기능 추가 시 위험.
- 같은 파일 안에 `PostDetailView` 본체, 댓글 트리(`CommentsSection` + `CommentRow` + 마크다운/캐시 로직),
  배너 3종(`YouTubeBanner`/`DealLinkBanner`/`SourceBanner`), UILabel 브리지(`WrappingTitleLabel`),
  window-level scroll claim 유틸(`StatusBarTapScrollClaimer`) 가 한 덩어리로 들어 있음.
- file-private 서브 struct 단위로 이미 충분히 분리되어 있어 mechanical move 비용이 낮다.
- `InlineVideoPlayer.swift` (1446줄) 분할은 본 spec 범위 밖. 안정 회수 후 별도 PR.

## 파일 구조

| 새 파일 | 옮길 타입 | 줄수(대략) |
|---|---|---|
| `Views/PostDetailView.swift` (남김) | `PostDetailView` 본체 + `==` + `body` + `detailHeader` + `articleContent` + `attributedString` + `linkifyPlainText` + `urlDetector` + `beginDismissCover` + `reloadDetail` + `presentInBrowser` | ~440 |
| `Views/PostDetailComments.swift` | `PostDetailCommentsSection` (← `CommentsSection`), `PostDetailCommentRow` (← `CommentRow`), `StyledBox`, `styledCache`, `styledContent`, `computeStyledContent` | ~190 |
| `Views/PostDetailBanners.swift` | `PostDetailYouTubeBanner`, `PostDetailDealLinkBanner`, `PostDetailSourceBanner` | ~110 |
| `Views/WrappingTitleLabel.swift` | `WrappingTitleLabel` (그대로) | ~40 |
| `Views/StatusBarTapScrollClaimer.swift` | `StatusBarTapScrollClaimer` + 내부 `ClaimerView` (그대로) | ~125 |

## 네이밍

`PostDetail` 접두사로 소유권 시그널링 — 다른 파일에서 우발적으로 끌어 쓰지 않도록.

- `CommentsSection` → `PostDetailCommentsSection`
- `CommentRow` → `PostDetailCommentRow`
- `YouTubeBanner` → `PostDetailYouTubeBanner`
- `DealLinkBanner` → `PostDetailDealLinkBanner`
- `SourceBanner` → `PostDetailSourceBanner`
- `WrappingTitleLabel` 유지 (제목용 일반 utility — 호출은 PostDetailView 한 곳뿐이지만 의미적으로 일반)
- `StatusBarTapScrollClaimer` 유지 (window-level scroll utility)

호출부 변경: `PostDetailView.body` 안의 `CommentsSection(…)`, `articleContent` 안의 `YouTubeBanner`/`DealLinkBanner`/`SourceBanner` 참조를 새 이름으로 일괄 변경.

## 접근 수준

모든 옮긴 타입을 `internal` (`struct PostDetailCommentsSection: View { … }`).
기존 `private struct ...` 키워드를 `struct ...` 로 변경. 새 파일 컨텍스트에서 file-private는 동일 파일 내 다른 entry 가 없어서 의미 없음.

## Xcode 프로젝트 등록

프로젝트가 Xcode 15+ `PBXFileSystemSynchronizedRootGroup` 을 사용하므로 `Views/` 하위 새 `.swift` 파일은 별도 등록 없이 자동 포함된다. `project.pbxproj` 수정 불필요. 빌드 검증으로 확인.

## 데이터 흐름

변경 없음.

- `PostDetailCommentsSection` 의 prop (`comments`, `tapGate`, `onImageTap`, `onVideoDismissBegin`) 시그니처 그대로.
- `styledCache` 는 `PostDetailCommentRow` 의 `static let` 로 이동. 인스턴스 단일성·동작 동일.
- `urlDetector` / `linkifyPlainText` / `attributedString` 은 `PostDetailView` 안에 그대로 남음 (본문 텍스트 처리). 댓글의 마크다운 + mention 처리는 `PostDetailCommentRow` 가 자체 보유.

## 회귀 위험 / QA

행위 변경이 없으므로 회귀 표면은 좁다.

빌드/타입 회귀:
1. `private` → `internal` 로 가시성 완화. 동일 파일 안에서만 접근하던 타입이 모듈 전체에 노출됨. `PostDetail` 접두사로 시그널.

행위 회귀 가능 표면 (수동 QA, 본문+댓글 있는 글 1개로 확인):
- 제목 줄바꿈 정상 (`WrappingTitleLabel`)
- 본문 NSDataDetector 자동 링크 / 명시적 `<a>` 링크 / 외부 링크 → SafariView 라우팅
- 댓글 mention `@nickname` 파란 굵게 / 마크다운 `[label](url)` 링크 색 / `~` 이스케이프 (1995~1996 에 strikethrough 안 걸려야 함)
- 출처 배너 / YouTube 배너 / DealLink 배너 렌더
- pull-to-refresh
- status bar tap → 본문 ScrollView 최상단으로 (`StatusBarTapScrollClaimer` 동작)
- detail dismiss 후 list status bar tap → list 최상단 (claimer 복구)
- 본문 이미지 탭 → ImageViewer 진입 / dismiss cover 정상 동작

QA 범위 밖 (이번 분할에 무관):
- 인라인 비디오 재생 / 풀스크린 / 스크럽 (InlineVideoPlayer 미수정)
- 본문 ScrollView 위치 보존 (수정 없음)

## 테스트

기존 `nuntingTests/` 는 parser/loader/network 위주로 view 분할 영향 없음. 빌드 통과 + 기존 테스트 그린이면 끝.

새 테스트 추가하지 않음. SwiftUI view 스냅샷 테스트는 본 프로젝트에 없고, 회귀 표면이 좁아 도입 부담이 이득 대비 큼.

## 작업 순서

1. 새 파일 4개 생성 (`PostDetailComments.swift`, `PostDetailBanners.swift`, `WrappingTitleLabel.swift`, `StatusBarTapScrollClaimer.swift`).
2. 기존 `Views/PostDetailView.swift` 에서 해당 타입 제거 + 호출부 새 이름으로 갱신.
3. `xcodebuild -scheme nunting build` 통과 확인.
4. 기존 unit test 통과 확인.
5. 수동 QA 위 체크리스트.
6. 커밋 → push 승인 대기.

## 범위 밖

- `InlineVideoPlayer.swift` 분할 — 별도 후속 PR.
- `Services/Networking.swift` 분할 (refactor-followups §3) — 별도.
- 테스트 헬퍼화 (refactor-followups §4) — 별도.
- detailHeader 별도 파일 추출 — 12줄짜리 computed property 라 분리 가치 낮음.
- 행위 변경, 새 기능, 리팩토링 외 코드 정리.
