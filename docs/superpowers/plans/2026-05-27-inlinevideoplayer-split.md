# InlineVideoPlayer 5분할 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Views/InlineVideoPlayer.swift` (1446줄) 를 컨테이너 × 모드 매트릭스 5파일로 분할, 행위 변경 없는 mechanical move.

**Architecture:** 1 composer (InlineVideoPlayer View) + 4 매트릭스 파일 (AVPlayer/WebMPlayer × Inline/Fullscreen). 타입 이름 변경 없음 (외부 dep `VideoPlayerPool` / `ContentView` 의 참조 코드 변경 0). `private` → `internal` (default) 가시성 완화. `htmlAttributeEscaped` (현재 file-private) 만 internal 로 노출해 WebM 두 파일이 공유.

**Tech Stack:** Swift 6, SwiftUI, UIKit, AVKit, AVFoundation, WebKit, Xcode 15+ filesystem synchronized groups (자동 파일 포함).

**Spec:** `docs/superpowers/specs/2026-05-27-inlinevideoplayer-split-design.md`

---

## File Structure

| 파일 | 책임 | 줄수(대략) | 신규/수정 |
|---|---|---|---|
| `nunting/Views/InlineVideoPlayer.swift` | `InlineVideoPlayer` (composer View) + `isWebmContainer` + `resolvedPoster` + `aagagPosterFallback` | ~180 | 수정 (~1265줄 축소) |
| `nunting/Views/WebMPlayerInlineView.swift` | `WebmInlineWebView` (UIViewRepresentable + Coordinator), `htmlAttributeEscaped` (internal) | ~170 | 신규 |
| `nunting/Views/WebMPlayerFullscreenView.swift` | `WebmFullscreenPlayer` (View), `WebmFullscreenWebView` (UIViewRepresentable + Coordinator) | ~120 | 신규 |
| `nunting/Views/AVPlayerFullscreenView.swift` | `FullscreenVideoPlayer` (View), `AVPlayerControllerView` (UIViewControllerRepresentable + Coordinator) | ~270 | 신규 |
| `nunting/Views/AVPlayerInlineView.swift` | `InlineAutoplayVideoView` (UIViewRepresentable), `InlineAutoplayUIView` (`@MainActor final class`), `InlineVideoScrubBarMarking` (protocol), `VideoScrubBarView`, `DirectionalScrubPanGestureRecognizer` | ~700 | 신규 |

원본 line layout (참조용):
- `1-186` — `InlineVideoPlayer` composer + helpers (composer 파일에 잔류)
- `188-241` — `InlineAutoplayVideoView` (AV inline bridge)
- `243-564` — `InlineAutoplayUIView` (`@MainActor final class`)
- `566-578` — `InlineVideoScrubBarMarking` doc comment + protocol
- `582-820` — `VideoScrubBarView`
- `822-887` — `DirectionalScrubPanGestureRecognizer`
- `889-923` — `FullscreenVideoPlayer`
- `925-1151` — `AVPlayerControllerView` + `Coordinator`
- `1153` — `// MARK: - WebM (WKWebView fallback)` divider
- `1155-1166` — `htmlAttributeEscaped` doc + func
- `1168-1323` — `WebmInlineWebView` + `Coordinator`
- `1325-1349` — `WebmFullscreenPlayer`
- `1351-1446` — `WebmFullscreenWebView` + `Coordinator`

Xcode 프로젝트 (`nunting.xcodeproj/project.pbxproj`) 는 `PBXFileSystemSynchronizedRootGroup` 사용 — `Views/` 안에 swift 파일 떨어뜨리면 자동 포함, pbxproj 수정 불필요.

## Verbatim-move contract

각 task 의 핵심 step은 "원본 파일에서 line range 의 내용을 새 파일로 이동" 이다. 다음 contract 가 모든 task 에 적용된다:

- **Imports** — 새 파일 맨 위에 필요한 모듈만 import. 각 task 가 해당 file 의 import 목록을 명시.
- **Doc comment 보존** — 원본의 모든 `///` doc comment 및 `//` 인라인 comment 를 그대로 복사. 한 글자도 다시 쓰지 않음.
- **Visibility 변경** — `private struct` / `private final class` / `private func` 키워드의 `private ` 만 삭제. 다른 변경 일절 금지.
- **Body 그대로** — 함수 body, KVO 옵저버, `@objc` 메서드, generic constraint, `@MainActor` annotation, 모든 expression 동일.
- **호출부 변경 0** — composer (`InlineVideoPlayer`) 와 외부 (`VideoPlayerPool`, `ContentView`) 의 참조는 타입 이름 그대로라 변경 없음.
- **MARK divider** — 원본의 `// MARK: - WebM (WKWebView fallback)` (line 1153) 는 분할 후 의미 잃으므로 삭제 (composer 잔류 파일에서도 제거).

매 task 의 마지막 검증 step 으로 `xcodebuild -scheme nunting -project nunting.xcodeproj -destination 'generic/platform=iOS' build` 실행 → `** BUILD SUCCEEDED **` 필수.

SourceKit (editor language server) 가 `import UIKit` / `import WebKit` / `import AVKit` 를 false positive 로 "No such module" 보고할 수 있음. iOS-target xcodebuild 가 authoritative — 무시.

---

## Task 1: WebMPlayerInlineView 추출 + helper internal 화

가장 작은 외부 의존부터. `htmlAttributeEscaped` 를 `internal func` 로 노출해야 Task 2 의 WebMPlayerFullscreen 이 cross-file 호출 가능.

**Files:**
- Create: `nunting/Views/WebMPlayerInlineView.swift`
- Modify: `nunting/Views/InlineVideoPlayer.swift` — 원본 line 1155-1166 (helper) + line 1168-1323 (WebmInlineWebView) 제거

- [ ] **Step 1: 새 파일 생성**

Create `nunting/Views/WebMPlayerInlineView.swift` with:
- Header imports: `import SwiftUI`, `import WebKit`
- Then verbatim copy of original `InlineVideoPlayer.swift`:
  - Lines 1155-1166: `htmlAttributeEscaped` doc + func — change `private func` to `func` (internal default)
  - Blank line separator
  - Lines 1168-1323: `WebmInlineWebView` block — change `private struct` to `struct`. Body inside (Coordinator class, makeUIView, updateUIView, dismantleUIView, htmlForInline static method) all verbatim, no visibility tweaks needed (everything inside the struct is already at the right scope).

The file's `htmlForInline` static method already calls `htmlAttributeEscaped(url.absoluteString)` — that call resolves correctly because both live in the new file.

- [ ] **Step 2: Remove the moved block from `InlineVideoPlayer.swift`**

Delete original lines 1155-1166 (htmlAttributeEscaped) and 1168-1323 (WebmInlineWebView struct). Leave the `// MARK: - WebM (WKWebView fallback)` divider at line 1153 in place for now — Task 4 will remove the divider as the last WebM block leaves.

The blank lines around the deleted blocks should collapse to a single blank line so the file doesn't gain double blanks.

- [ ] **Step 3: 빌드 검증**

```
xcodebuild -scheme nunting -project nunting.xcodeproj -destination 'generic/platform=iOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: 커밋**

```bash
git add nunting/Views/WebMPlayerInlineView.swift nunting/Views/InlineVideoPlayer.swift
git commit -m "$(cat <<'EOF'
refactor(video): WebMPlayerInlineView → 별도 파일

InlineVideoPlayer.swift 5분할 1/4. WebmInlineWebView (UIViewRepresentable
+ Coordinator) 와 공유 helper htmlAttributeEscaped 를 분리. helper 는
internal 로 노출 — Task 2 의 WebMPlayerFullscreenView 가 cross-file
호출 가능.

spec: docs/superpowers/specs/2026-05-27-inlinevideoplayer-split-design.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: WebMPlayerFullscreenView 추출

Task 1 에서 노출한 `htmlAttributeEscaped` 를 호출하는 측. 외부 dep 0.

**Files:**
- Create: `nunting/Views/WebMPlayerFullscreenView.swift`
- Modify: `nunting/Views/InlineVideoPlayer.swift` — 원본 line 1325-1446 (WebmFullscreenPlayer + WebmFullscreenWebView) 제거 + `// MARK: - WebM (WKWebView fallback)` divider 제거

- [ ] **Step 1: 새 파일 생성**

Create `nunting/Views/WebMPlayerFullscreenView.swift` with:
- Header imports: `import SwiftUI`, `import UIKit`, `import WebKit`
- Verbatim copy of original lines 1325-1349 (`WebmFullscreenPlayer`) — change `private struct` to `struct`. Body (body block calling WebmFullscreenWebView) verbatim.
- Blank line separator.
- Verbatim copy of original lines 1351-1446 (`WebmFullscreenWebView`) — change `private struct` to `struct`. Body (Coordinator, makeUIView with UIPanGestureRecognizer dismiss, updateUIView, dismantleUIView, htmlForFullscreen static, Coordinator class with `@objc handleDismissPan`) verbatim.

The `htmlForFullscreen` static method calls `htmlAttributeEscaped(url.absoluteString)` — this resolves to the `internal func` Task 1 exposed in `WebMPlayerInlineView.swift` (same module, no import needed).

- [ ] **Step 2: Remove the moved block + MARK divider**

Delete original lines 1325-1446 from `InlineVideoPlayer.swift`. Also delete the `// MARK: - WebM (WKWebView fallback)` divider (was line 1153, now adjacent to deleted content) — no WebM block remains in this file.

- [ ] **Step 3: 빌드 검증**

```
xcodebuild -scheme nunting -project nunting.xcodeproj -destination 'generic/platform=iOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. (Verifies `htmlAttributeEscaped` cross-file call works.)

- [ ] **Step 4: 커밋**

```bash
git add nunting/Views/WebMPlayerFullscreenView.swift nunting/Views/InlineVideoPlayer.swift
git commit -m "$(cat <<'EOF'
refactor(video): WebMPlayerFullscreenView → 별도 파일

InlineVideoPlayer.swift 5분할 2/4. WebmFullscreenPlayer + WebmFullscreenWebView
분리. Task 1 의 internal htmlAttributeEscaped 를 cross-file 호출.
원본의 // MARK: - WebM divider 도 함께 제거 — 더 이상 같은 파일에
WebM 블록이 없음.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: AVPlayerFullscreenView 추출

AV path 의 풀스크린 부분. `FullscreenVideoPlayer` + `AVPlayerControllerView` (긴 Coordinator 포함).

**Files:**
- Create: `nunting/Views/AVPlayerFullscreenView.swift`
- Modify: `nunting/Views/InlineVideoPlayer.swift` — 원본 line 889-1151 (FullscreenVideoPlayer + AVPlayerControllerView) 제거

- [ ] **Step 1: 새 파일 생성**

Create `nunting/Views/AVPlayerFullscreenView.swift` with:
- Header imports: `import SwiftUI`, `import UIKit`, `import AVKit`
- Verbatim copy of original lines 889-923 (`FullscreenVideoPlayer`) — change `private struct` to `struct`. Body (ZStack with Color.black + AVPlayerControllerView + ProgressView) verbatim.
- Blank line separator.
- Verbatim copy of original lines 925-1151 (`AVPlayerControllerView` + nested Coordinator):
  - Change `private struct` to `struct`.
  - Inside, `Coordinator` (`final class Coordinator: NSObject, UIGestureRecognizerDelegate`) stays as nested type with same visibility.
  - All methods verbatim: `makeCoordinator`, `makeUIViewController` (with deferred `Task { @MainActor [weak controller, coordinator = ...] in ... }`), `updateUIViewController`, `dismantleUIViewController`, Coordinator's `observeEndOfItem`, `removeEndObservation`, `startPlaybackWhenReady`, `installDismissGesture`, `@objc handleDismissPan`, `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)`.

- [ ] **Step 2: Remove the moved block from `InlineVideoPlayer.swift`**

Delete original lines 889-1151 from the file.

- [ ] **Step 3: 빌드 검증**

```
xcodebuild -scheme nunting -project nunting.xcodeproj -destination 'generic/platform=iOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: 커밋**

```bash
git add nunting/Views/AVPlayerFullscreenView.swift nunting/Views/InlineVideoPlayer.swift
git commit -m "$(cat <<'EOF'
refactor(video): AVPlayerFullscreenView → 별도 파일

InlineVideoPlayer.swift 5분할 3/4. FullscreenVideoPlayer +
AVPlayerControllerView (Coordinator 포함) 분리. composer 의
fullScreenCover 분기는 타입 이름 그대로라 변경 없음.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: AVPlayerInlineView 추출 (가장 큰 단위)

AV inline path 전체 — bridge + UIView body + scrub bar UI + pan recognizer + marker protocol. gesture coordination 이 이 파일 안에서 응집되어 있어 외부 영향은 없지만 줄수 최대 (~700줄).

**Files:**
- Create: `nunting/Views/AVPlayerInlineView.swift`
- Modify: `nunting/Views/InlineVideoPlayer.swift` — 원본 line 188-887 (5개 타입) 제거. composer 본체 (1-186) 만 잔류.

- [ ] **Step 1: 새 파일 생성**

Create `nunting/Views/AVPlayerInlineView.swift` with:
- Header imports: `import SwiftUI`, `import UIKit`, `import AVFoundation`, `import AVKit`
- Verbatim copy of original lines 188-241 (`InlineAutoplayVideoView`) — change `private struct` to `struct`. Body (makeUIView, updateUIView, dismantleUIView) verbatim.
- Blank line separator.
- Verbatim copy of original lines 243-564 (`InlineAutoplayUIView`) — already `@MainActor final class` (internal), keep as is. Body (init, deinit with `MainActor.assumeIsolated`, layoutSubviews, setURL, setPlaying, tryRecreatePlayer, releasePlayerForPoolEviction, teardown, createPlayer with aspect-load Task + KVO + end-of-item observer, tearDownPlayer) verbatim.
- Blank line separator.
- Verbatim copy of original lines 566-578 (`InlineVideoScrubBarMarking` doc comment + protocol) — already internal, keep as is.
- Blank line separator.
- Verbatim copy of original lines 582-820 (`VideoScrubBarView`) — change `private final class` to `final class`. Body (init, deinit, didMoveToWindow with require(toFail:), layoutSubviews, updateFill, displayProgress, `@objc handleTap`, `@objc handlePan` switch, seekToProgress, installTimeObserver, removeTimeObserverFromPreviousPlayer) verbatim.
- Blank line separator.
- Verbatim copy of original lines 822-887 (`DirectionalScrubPanGestureRecognizer`) — change `private final class` to `final class`. Body (touchesBegan, touchesMoved with directional decision, reset) verbatim.

- [ ] **Step 2: Remove the moved blocks from `InlineVideoPlayer.swift`**

Delete original lines 188-887 from the file. The file should now contain only the `InlineVideoPlayer` composer (struct + body + isWebmContainer + resolvedPoster + aagagPosterFallback) plus the top-of-file imports.

After deletion, the imports at top of `InlineVideoPlayer.swift` should be trimmed to what the composer actually needs: `import SwiftUI`, `import AVKit`, `import UIKit`, `import WebKit` — composer body references `Color`, `Image`, `WebmInlineWebView`, `InlineAutoplayVideoView`, `WebmFullscreenPlayer`, `FullscreenVideoPlayer`, `NetworkImage`, `InlineAutoplayUIView.scrubBarStripHeight`. The cross-file type references resolve module-wide (same target, no import needed for same-module types). Actual import survey:
- `import SwiftUI` — needed (View, Color, etc.)
- `import AVKit` — no longer needed (no `AVPlayer` / `AVPlayerLayer` direct use in composer)
- `import UIKit` — no longer needed (no `UIView` / `UIFont` direct use in composer)
- `import WebKit` — no longer needed (no `WKWebView` direct use in composer)

So composer file imports collapse to just `import SwiftUI`. Verify this with xcodebuild — if any of the removed imports were transitively needed, the build will fail and you'll restore the necessary one.

- [ ] **Step 3: 빌드 검증**

```
xcodebuild -scheme nunting -project nunting.xcodeproj -destination 'generic/platform=iOS' build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

If build fails on missing import, add back the minimum needed (e.g. `import UIKit` if `InlineAutoplayUIView.scrubBarStripHeight` resolution requires the UIKit module path — unlikely, since the type is in same module, but verify).

- [ ] **Step 4: 라인수 확인**

```
wc -l nunting/Views/InlineVideoPlayer.swift nunting/Views/AVPlayerInlineView.swift nunting/Views/AVPlayerFullscreenView.swift nunting/Views/WebMPlayerInlineView.swift nunting/Views/WebMPlayerFullscreenView.swift
```

Expected:
- `InlineVideoPlayer.swift` ~180줄 (was 1446)
- `AVPlayerInlineView.swift` ~700줄
- `AVPlayerFullscreenView.swift` ~270줄
- `WebMPlayerInlineView.swift` ~170줄
- `WebMPlayerFullscreenView.swift` ~120줄
- Total ~1440줄 (원본과 거의 동일, 파일별 import 헤더로 약간 증가)

- [ ] **Step 5: 커밋**

```bash
git add nunting/Views/AVPlayerInlineView.swift nunting/Views/InlineVideoPlayer.swift
git commit -m "$(cat <<'EOF'
refactor(video): AVPlayerInlineView → 별도 파일

InlineVideoPlayer.swift 5분할 4/4 (마지막). AV inline path 전체:
InlineAutoplayVideoView (UIViewRepresentable), InlineAutoplayUIView
(@MainActor final class), InlineVideoScrubBarMarking (protocol),
VideoScrubBarView, DirectionalScrubPanGestureRecognizer. gesture
coordination 이 이 파일 안에 응집되어 있어 외부 영향 없음.

이 PR 4커밋으로 InlineVideoPlayer.swift 1446 → ~180줄로 축소.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: 기존 test + 수동 QA

기존 test 그린 확인 + 수동 QA. PostDetailView 분할보다 회귀 표면 크니까 mp4 / webm 둘 다 실제 글로 검증.

**Files:** 없음 (검증만)

- [ ] **Step 1: Unit test 실행**

```
xcodebuild test -scheme nunting -project nunting.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | tail -10
```

(iPhone Simulator 이름은 `xcrun simctl list devices available | grep "iPhone (17|16)"` 으로 확인.)

Expected: 217/217 PASS, `** TEST SUCCEEDED **`.

- [ ] **Step 2: 수동 QA — mp4 비디오 글 1개**

Spec QA 체크리스트 (AV path):
- [ ] inline 자동 재생 (muted), 스크롤로 사라지면 일시정지, 다시 보이면 재생
- [ ] inline scrub bar 탭/드래그로 seek (좌우 pan 만 — 세로 pan 은 ScrollView 가 claim)
- [ ] inline 탭 → 풀스크린 진입 (단, scrub bar 영역 탭은 풀스크린 안 열림)
- [ ] 풀스크린 dismiss (드래그-다운), `ContentView` 백드래그와 충돌 없음
- [ ] 풀스크린 dismiss 직후 detail 의 black cover 가 점진 노출 방지 (PR #71 dismissCovering 동작)

- [ ] **Step 3: 수동 QA — webm 비디오 글 1개 (etoland)**

Spec QA 체크리스트 (WebM path):
- [ ] inline 자동 재생 (WKWebView 안 muted autoplay)
- [ ] inline 탭 → 풀스크린 진입 (전체 frame 이 탭 surface, scrub 영역 없음)
- [ ] 풀스크린 dismiss (드래그-다운), HTML5 native controls 보임/탭 가능

- [ ] **Step 4: 수동 QA — 시스템 통합**

- [ ] `VideoPlayerPool` lease — 비디오 3개+ 글에서 활성 3개 + 대기열 동작 (긴 게시글 스크롤)
- [ ] `ContentView` 백드래그 — 비디오 scrub 영역 위에서 시작해도 정상 dismiss

- [ ] **Step 5: push 승인 대기**

QA 통과 시 사용자에게 보고하고 `git push` 승인 받기 (auto-push 금지 메모리).

---

## Self-Review (작성자 체크)

**Spec coverage:**
- WebMPlayerInlineView 추출 + htmlAttributeEscaped internal 화 → Task 1 ✓
- WebMPlayerFullscreenView 추출 → Task 2 ✓
- AVPlayerFullscreenView 추출 → Task 3 ✓
- AVPlayerInlineView 추출 (5개 타입 묶음) → Task 4 ✓
- 작업 순서 (WebM Inline → WebM Fullscreen → AV Fullscreen → AV Inline) 저위험 → 고위험 + helper 의존성 순서 충족 → ✓
- 가시성 `private` → `internal` (각 task verbatim contract 에 명시) → ✓
- 타입 이름 유지 (composer 호출부 변경 0) → ✓
- 빌드 검증 → Task 1-4 각 task 마지막 step ✓
- 기존 test + 수동 QA → Task 5 ✓

**Placeholder scan:** 없음. 모든 step 에 실제 line range / 명령 / 커밋 메시지 / 기대 결과 포함.

**Type consistency:**
- `WebmInlineWebView` 와 `htmlAttributeEscaped` cross-file 호출 — Task 1 정의 ↔ Task 2 호출. helper 는 `internal func` (default access) 으로 노출되며 같은 모듈 내라 import 없이 호출 가능.
- `InlineAutoplayUIView.scrubBarStripHeight` — composer 가 참조. Task 4 에서 같은 모듈 내 다른 파일로 이동, 참조 유효.
- `VideoPlayerPool.shared.acquire(_:InlineAutoplayUIView)` 등 외부 dep — 타입 이름 변경 없음.
- `ContentView.panGesture` 의 `if v is InlineVideoScrubBarMarking` — protocol 이 다른 파일로 이동하지만 internal scope 유지로 hit-test 유효.

---

## 범위 밖

- AV inline path 의 6-way 추가 분할 (scrub UI vs bridge 분리) — gesture coordination 의 internal API 노출 비용. 별도 후속.
- AVPlayer / WebKit 공통 protocol 추상화 — 별도 후속.
- `SelectableRichText` SwiftUI→UIKit attribute bridge 일반화 — PR #71 mention fix follow-up, 별도 PR.
- 행위 변경, 새 기능, 무관한 리팩토링.
