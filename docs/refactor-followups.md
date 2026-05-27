# Refactor Follow-ups

## ✅ 1. ParserBlockWalker 통합 (완료)

PR #64 ~ #70 — 모든 HTML-walking 파서가 `ParserBlockWalker` + `WalkerRules` 로 통합. 누적 ~1170 줄 절감.

| 사이트 | PR | 변화 |
|---|---|---|
| Bobae + Ppomppu (파일럿) | #64 | -241 |
| Etoland (customElement hook) | #65 | -94 |
| Clien | #66 | -170 |
| Inven | #67 | -163 |
| Humor | #68 | -76 |
| SLR | #69 | -100 |
| Ddanzi + Coolenjoy + Cook82 | #70 | -325 |

**Aagag 는 의도적으로 제외** — 본문이 HTML element 가 아니라 `<script>AAGAG_AA.content = "..."</script>` JS 문자열 안 `[sTag]{json}[/sTag]` 커스텀 마커로 인코딩됨. parseDetail 이 자체 문자열 파서를 써서 walker 적용 대상 아님.

**Walker hook surface (현재 4 closure)** — `resolveImageURL`, `resolveVideoURL`, `imageBlock`, `shouldEmitAnchor`, `customElement`. 다음 파서 추가 시 5개 이상 override 가 필요하면 추상화 부족 신호.

## 2. 거대 View 파일 분할

### ✅ PostDetailView (완료, PR #71)

`Views/PostDetailView.swift` 932 → 440줄. 5파일로 분할 + QA 중 발견한 mention bridge bug 1건 동봉.

- `WrappingTitleLabel.swift` (44) — UILabel 제목 줄바꿈 브리지
- `StatusBarTapScrollClaimer.swift` (150) — window-level scrollsToTop claim
- `PostDetailBanners.swift` (112) — YouTube / DealLink / Source 배너 3종 (`PostDetail` 접두사)
- `PostDetailComments.swift` (220) — CommentsSection / CommentRow + markdown/mention 캐시 (`PostDetail` 접두사)
- `PostDetailView.swift` (440) — 본체

Mention fix: SwiftUI `.foregroundColor` / `.font` 가 `NSMutableAttributedString` 변환 시 `SwiftUI.*` 별도 key 로 가서 `SelectableRichText` 의 "nil 이면 label color" pass 가 mention 을 일반 글씨로 덮어쓰던 회귀. mention 적용을 `\.uiKit` scope 로 변경. 같은 bridge bug 가 markdown link 에도 있지만 UITextView `.linkTextAttributes` fallback 으로 가려져 별도 follow-up — `PostDetailComments.swift` NOTE 코멘트로 흔적 남겨둠.

### ⏳ InlineVideoPlayer (남음)

`Views/InlineVideoPlayer.swift` — **1446줄**. AVPlayer + WebmView + aspect ratio 로직 혼재.
- 분할 후보: `AVPlayerInline.swift` / `WebMPlayerInline.swift` / `InlineVideoPlayer.swift` (조립자)
- 회귀 위험 큼: 스크럽 / 풀스크린 dismiss / WebM autoplay / `VideoPlayerPool` leasing / `ContentView` 백드래그 충돌 등 수동 QA 항목 다수.

## 3. Networking 책임 분리

`Services/Networking.swift` **624줄** — HTTPS redirect, 챌린지(Aagag 봇체크), 재시도가 한 클래스에.

- `HTTPClientChallenge.swift` — Aagag 등 봇체크 응답 처리
- `HTTPRedirectHandler.swift` — 303/302 + scheme upgrade
- `Networking.swift` — 조립 + 공통 API

셀룰러/오프라인 처리 추가 예정이라면 그 전에 정리.

## 4. 테스트 헬퍼화

`nuntingTests/ParserDetailTests.swift` **1881줄** (마이그 과정에서 baseline fixture 가 늘어 더 커짐). 파서별 fixture 구조가 비슷하게 반복 — 헬퍼 추출 후보.

- `ParserTestHelper.swift` — fixture HTML loader, assertion 유틸 (image block 추출, richText 텍스트 join, link 세그먼트 추출 등)
- 비슷한 모양의 helper closure 들이 매 테스트마다 반복(`compactMap { if case .image... }`, `compactMap { if case .richText... }`) → 한 곳에 모으면 fixture 가독성 ↑
- table-driven test: 사이트 × 시나리오 매트릭스

## 메모

- 우선순위 1 + 2(PostDetailView) 완료. 다음 후보는 2 후반(InlineVideoPlayer) / 3 / 4 / SelectableRichText SwiftUI→UIKit attribute bridge 일반화.
- View 분할(#2 InlineVideoPlayer) 은 비디오 재생 회귀 위험이 커서 수동 QA 항목이 많음 (스크럽 / 풀스크린 / WebM / pool / 백드래그).
- Networking 분리(#3) 는 셀룰러/오프라인 기능 추가 예정 있을 때가 가장 자연스러운 타이밍.
- 테스트 헬퍼화(#4) 는 비교적 안전하고 빠름.
- Server (Go) 쪽은 별도 concern — 이 목록에는 포함 안 함.
