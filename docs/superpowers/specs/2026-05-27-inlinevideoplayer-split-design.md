# InlineVideoPlayer 파일 분할 설계

`Views/InlineVideoPlayer.swift` (1446줄) 를 컨테이너 (AVPlayer / WebMPlayer) × 모드 (Inline / Fullscreen) 매트릭스 5파일로 분할.
행위 변경 없는 mechanical move + 가시성 한 단계 완화 (`private` → `internal`).

## 배경

- `docs/refactor-followups.md` §2 후반. PostDetailView 분할 (PR #71) 의 짝.
- 1446줄 안에 12개 top-level 타입 + 4개 코디네이터/내부 클래스. AVKit / WebKit / Gesture / Scrub UI / Pool / Fullscreen / Inline 이 한 덩어리.
- 외부 dep 2건: `VideoPlayerPool` → `InlineAutoplayUIView`, `ContentView` → `InlineVideoScrubBarMarking`. 둘 다 internal 가시성 유지 필수.

## 파일 구조

| 새 파일 | 옮길 타입 | 줄수(대략) |
|---|---|---|
| `Views/InlineVideoPlayer.swift` (남김) | `InlineVideoPlayer` (composer View) + `isWebmContainer` + `resolvedPoster` + `aagagPosterFallback` | ~180 |
| `Views/AVPlayerInlineView.swift` | `InlineAutoplayVideoView` (UIViewRepresentable), `InlineAutoplayUIView` (UIView body, `@MainActor final class`), `InlineVideoScrubBarMarking` (protocol), `VideoScrubBarView`, `DirectionalScrubPanGestureRecognizer` | ~700 |
| `Views/AVPlayerFullscreenView.swift` | `FullscreenVideoPlayer` (View), `AVPlayerControllerView` (UIViewControllerRepresentable + Coordinator) | ~270 |
| `Views/WebMPlayerInlineView.swift` | `WebmInlineWebView` (UIViewRepresentable + Coordinator), `htmlAttributeEscaped` (internal) | ~170 |
| `Views/WebMPlayerFullscreenView.swift` | `WebmFullscreenPlayer` (View), `WebmFullscreenWebView` (UIViewRepresentable + Coordinator) | ~120 |

Xcode 프로젝트는 `PBXFileSystemSynchronizedRootGroup` 사용 — 새 swift 파일은 자동 포함, `project.pbxproj` 수정 불필요.

## 네이밍

타입 이름 **유지** (PostDetailView 분할 때와 다른 정책):
- 기존 타입 이름이 이미 충분히 specific (`InlineAutoplayUIView`, `WebmFullscreenPlayer` 등 컨테이너/모드가 이름에 명시).
- 외부 dep 두 곳 (`VideoPlayerPool`, `ContentView`) 의 참조 코드 변경 0.
- 파일 이름이 컨테이너 × 모드 매트릭스로 위치 시그널 — `AVPlayerInlineView.swift` / `WebMPlayerFullscreenView.swift` 등.

## 가시성

- 모든 `private struct/class/func` → 내부 default (`internal`).
- `htmlAttributeEscaped` — WebM inline 파일에 internal 로 두고 WebM fullscreen 이 같은 모듈 내 import 없이 호출. 별도 `WebMHelpers.swift` 만들지 않음 (14줄짜리 함수에 과함).
- `InlineAutoplayUIView` (이미 `@MainActor final class`, internal) — 가시성 유지. `VideoPlayerPool` 의 `weak var view: InlineAutoplayUIView?` 그대로 동작.
- `InlineVideoScrubBarMarking` (이미 internal protocol) — 가시성 유지. `ContentView` 의 `v is InlineVideoScrubBarMarking` 그대로 동작.

## Composer dispatch

변경 없음. `InlineVideoPlayer.body` 안 분기:

```swift
if isWebmContainer {
    WebmInlineWebView(url: url, isPlaying: ..., onAspectKnown: { ... })
} else {
    InlineAutoplayVideoView(url: url, isPlaying: ..., onAspectKnown: { ... })
}
```

```swift
.fullScreenCover(isPresented: $isPresented) {
    if isWebmContainer {
        WebmFullscreenPlayer(url: url, onDismissBegin: onDismissBegin)
    } else {
        FullscreenVideoPlayer(url: url, onDismissBegin: onDismissBegin)
    }
}
```

타입 이름 그대로라 composer 본체 코드 한 글자도 안 바뀜.

## 회귀 위험 / QA

PostDetailView 분할보다 회귀 위험 큼. Gesture coordination 이 한 파일 안에 응집되어 있어 외부 영향은 없지만, AVKit / WebKit / Pool / Gesture 의 동작 표면이 넓다.

빌드/타입 회귀:
1. `private` → `internal` 가시성 완화. `Inline*` / `AVPlayer*` / `Webm*` 접두사가 우발 사용 시그널.
2. `htmlAttributeEscaped` 가 private 에서 internal 로 — 동일 시그널.

행위 회귀 가능 표면 (수동 QA, mp4 비디오 글 + webm 비디오 글 각 1개):

**AV path (mp4):**
- [ ] inline 자동 재생 (muted), 스크롤로 사라지면 일시정지, 다시 보이면 재생
- [ ] inline scrub bar 탭/드래그로 seek (좌우 pan 만 — 세로 pan 은 ScrollView 가 claim)
- [ ] inline 탭 → 풀스크린 진입 (단, scrub bar 영역 탭은 제외)
- [ ] 풀스크린 dismiss (드래그-다운), `ContentView` 백드래그와 충돌 없음
- [ ] 풀스크린 dismiss 직후 detail 의 black cover 가 점진 노출 방지

**WebM path (etoland webm):**
- [ ] inline 자동 재생 (WKWebView 안 muted autoplay)
- [ ] inline 탭 → 풀스크린 진입 (전체 frame 이 탭 surface, scrub 영역 없음)
- [ ] 풀스크린 dismiss (드래그-다운), HTML5 native controls 보임/탭 가능

**시스템 통합:**
- [ ] `VideoPlayerPool` lease — 비디오 3개+ 글에서 활성 3개 + 대기열 동작 (긴 게시글 스크롤)
- [ ] `ContentView` 백드래그 — 비디오 scrub 영역 위에서 시작해도 정상 dismiss

QA 범위 밖 (이번 분할 무관):
- 본문 텍스트 / 댓글 (PR #71 에서 확인)
- 본문 / 댓글 이미지 viewer
- pull-to-refresh, status bar tap

## 테스트

기존 `nuntingTests/` 는 parser/loader/network 위주로 view 분할 영향 없음. 빌드 통과 + 기존 217 test 그린이면 끝.

새 테스트 추가하지 않음. SwiftUI view 스냅샷 테스트는 본 프로젝트에 없고, 회귀 표면은 좁지 않지만 수동 QA 가 자동화보다 빠르고 충분.

## 작업 순서

저위험 → 고위험 순. `htmlAttributeEscaped` 가 양쪽 WebM 파일에서 쓰이므로 helper 소유자 (Inline) 를 먼저 추출 + internal 로 노출해야 Fullscreen 추출 시점에 cross-file 호출이 컴파일 됨:

1. `WebMPlayerInlineView.swift` 추출 + `htmlAttributeEscaped` 를 `internal func` 로 노출 (~170줄)
2. `WebMPlayerFullscreenView.swift` 추출 — Step 1 의 internal helper 호출 가능 (~120줄)
3. `AVPlayerFullscreenView.swift` 추출 — `FullscreenVideoPlayer` + `AVPlayerControllerView` (~270줄)
4. `AVPlayerInlineView.swift` 추출 — 가장 큰 단위, gesture coordination + scrub UI + pool 참조 + protocol (~700줄)
5. 빌드 (`xcodebuild build`) + 기존 217 test 통과 + 수동 QA

각 단계 = 단일 파일 추출 + 호출부 변경 0 + `xcodebuild` 검증 + 커밋.

## 범위 밖

- AV inline path 의 scrub UI (`VideoScrubBarView` + `DirectionalScrubPanGestureRecognizer`) 와 bridge (`InlineAutoplayVideoView` + `InlineAutoplayUIView`) 6-way 분할 — gesture coordination 으로 강하게 얽혀 있어 internal API 노출 비용이 이득보다 큼. 별도 후속.
- AVPlayer / WebKit 공통 protocol 추상화 — 별도 후속.
- `SelectableRichText` SwiftUI→UIKit attribute bridge 일반화 — PR #71 mention fix 의 follow-up, 별도 PR.
- Networking 분할 (refactor-followups §3), 테스트 헬퍼화 (§4).
- 행위 변경, 새 기능, 무관한 리팩토링.
