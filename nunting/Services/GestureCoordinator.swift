import SwiftUI
import UIKit

/// Owns the entire pan-gesture state machine for `ContentView`:
/// drawer open/close, detail-overlay back-swipe dismiss and forward-
/// swipe reveal, plus the exclusion classifiers (bottom bar, UITextView
/// selection handle, `InlineVideoPlayer` scrub strip) that decide
/// whether the pan should run at all.
///
/// Pulled out of `ContentView` so the view stays focused on layout +
/// scene lifecycle. The controller still talks to `DetailOverlayController`
/// for the overlay's `offset` / `offsetBase` / `animating` — that
/// controller continues to track the *result* of gestures; the
/// coordinator tracks the in-flight drag state and commit decisions.
@Observable
@MainActor
final class GestureCoordinator {
    // MARK: - View-observed state

    /// True while the left drawer is committed open. Flipped by the
    /// pan commit branches, the backdrop tap, and `SideDrawer`'s
    /// onClose / onSelectBoard paths (all funnelled through `closeDrawer`).
    var drawerOpen = false
    /// Signed horizontal travel of the in-flight drag, after the
    /// direction-lock baseline subtraction. Feeds `drawerProgress`
    /// so the drawer follows the finger live during the drag.
    var dragOffset: CGFloat = 0
    /// Asserted while a horizontal-classified drag is in flight so
    /// the embedded scroll views in `PostDetailView` / `BoardListView`
    /// don't double-scroll under the pan. Released by `resetDragState`
    /// at touch-up; `DetailOverlayController.animating` extends the
    /// scroll lock across the post-commit spring.
    var scrollLocked = false
    /// Latest measured container height (window-coordinate) used as a
    /// fallback exclusion when `bottomAreaTopY` hasn't been measured yet.
    var containerHeight: CGFloat = 0
    /// Y position (window coordinates) where the bottom safe-area inset
    /// — filter chips + bottom bar — begins. Drags whose `startLocation.y`
    /// sits at or below this line belong to the bar, not the pan gesture.
    /// `.infinity` until the first preference measurement, in which case
    /// the `bottomGestureExclusion` fallback kicks in.
    var bottomAreaTopY: CGFloat = .infinity

    // MARK: - Constants (exposed for ContentView layout)

    let drawerWidth: CGFloat = 300

    // MARK: - Internal lock state (not view-observed)

    /// `nil` until the first 10pt-dominant tick locks the drag axis.
    /// Stored on the coordinator (not a SwiftUI `@State`) because the
    /// view doesn't need to re-render when the lock direction changes —
    /// only `dragOffset` / `drawerOpen` / `scrollLocked` are observed.
    @ObservationIgnored private var dragDirection: DragDirection?
    /// `value.translation.width` captured at axis lock so subsequent
    /// `value.translation.width - baseline` reads represent travel
    /// since the lock, not since touch-down. Without the baseline a
    /// slow diagonal that triggers a 10pt vertical first and then
    /// flips to horizontal would jump the drawer by the diagonal
    /// pre-lock distance the moment the axis lock engaged.
    @ObservationIgnored private var dragLockBaseline: CGFloat = 0
    /// 선택 핸들/스크럽바 제외 분류의 드래그당 1회 메모이즈. 분류 입력
    /// (`value.startLocation`)이 드래그 내내 불변인데 분류 비용(뷰 트리
    /// 재귀 + hitTest)은 크므로, 매 틱 재실행 대신 시작점 키로 캐시 —
    /// 자세한 staleness 계약은 `DragExclusionCache` doccomment 참조.
    /// `lazy` + `[weak self]`: 프로브가 coordinator 의 분류 메서드를 쓰되
    /// self → cache → closure → self 순환을 피한다.
    @ObservationIgnored private lazy var dragExclusion = DragExclusionCache { [weak self] start in
        guard let self else { return .none }
        if self.touchStartedNearSelectionHandle(at: start) { return .selectionHandle }
        if self.touchStartedOnScrubBar(at: start) { return .scrubBar }
        return .none
    }

    // MARK: - Tap gates exposed to subviews

    /// Flipped on every horizontal-dominant tick (≥4pt) so list rows
    /// can read `.suppressed` from their `onTapGesture` closure and
    /// skip the tap that would otherwise fire on touch-up. Class
    /// instance with a TTL deadline — see `TapSuppressionGate` doccomment.
    let rowTapGate = TapSuppressionGate()
    /// Same shape, flipped by the detail back-drag branch so an
    /// image / video sitting under the finger doesn't tap-fire when
    /// the user releases. Consumed by `PostDetailView` / inner views.
    let detailMediaTapGate = TapSuppressionGate()

    // MARK: - Constants (private)

    /// Height of the bottom bar area (bar + filter chips + safe area
    /// buffer) used as the exclusion zone before `bottomAreaTopY` has
    /// been measured. Once measured, the geometric top wins regardless
    /// of bar height / Dynamic Type.
    private let bottomGestureExclusion: CGFloat = 110

    // MARK: - Dependencies

    /// Singleton lookup deferred to a computed getter so the class
    /// definition stays free of a default-argument expression that
    /// would have to read a main-actor isolated static from the
    /// nonisolated default-arg context (Swift 6 warning otherwise).
    private var detail: DetailOverlayController { .shared }

    // MARK: - Computed (view layer)

    /// 0…1 — drawer is `drawerOpen ? width : 0` plus whatever portion
    /// of the current drag should pull it open. Clamped so flicks past
    /// the rest position don't spill past 100% opacity / 1× translation.
    var drawerProgress: CGFloat {
        let base: CGFloat = drawerOpen ? drawerWidth : 0
        let target = base + drawerApplicableDrag
        return max(0, min(1, target / drawerWidth))
    }

    /// Portion of the current drag that should feed `drawerProgress`. Zero
    /// whenever the drag is classified as a detail back/forward swipe, so
    /// the drawer doesn't flash open while the detail overlay is tracking
    /// the same finger.
    var drawerApplicableDrag: CGFloat {
        guard detail.activePost != nil else { return dragOffset }
        // Overlay exists. Detail back-swipe (base 0) and forward-reveal
        // (dragging left) both own the drag; only a rightward drag started
        // while the overlay is hidden still belongs to the drawer.
        if detail.offsetBase == 0 { return 0 }
        return dragOffset > 0 ? dragOffset : 0
    }

    var drawerXOffset: CGFloat {
        -drawerWidth + drawerWidth * drawerProgress
    }

    // MARK: - Gesture

    /// `.global` so `value.startLocation` shares the same window-
    /// coordinate space as `bottomAreaTopY` (which `BottomAreaTopKey`
    /// publishes via `frame(in: .global).minY`). Without the match,
    /// the local-coordinate start point sits below the top safe-
    /// area inset and `startedInBottomBar`'s `>=` comparison was
    /// ~47-59pt off on iPhones with notch / Dynamic Island.
    ///
    /// MUST stay computed — SwiftUI re-evaluates ContentView's body on
    /// every observed-state change and re-diffs gestures by structural
    /// identity. Memoising this onto a stored property would let stale
    /// closures linger across re-diffs and break the back-drag tracking.
    var panGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { [self] value in onPanChanged(value) }
            .onEnded { [self] value in onPanEnded(value) }
    }

    private func onPanChanged(_ value: DragGesture.Value) {
        // Touch started on a selection handle (UITextView's handle pan
        // must run without our back-drag sliding the overlay out under
        // it) or an inline video's scrub strip (the player's own UIKit
        // pan owns the drag) — bail. Classified once per drag and
        // memoised on `value.startLocation`, which is stable across
        // ticks; see `touchStartedNearSelectionHandle` /
        // `touchStartedOnScrubBar` for the hit-box rationale.
        if dragExclusion.kind(at: value.startLocation) != .none {
            return
        }
        // Don't fight the bottom-bar swipe (board step) when the drag
        // started inside the bar's hit area. (Pure geometry — cheap
        // enough to stay per-tick.)
        if startedInBottomBar(value) { return }
        let absW = abs(value.translation.width)
        let absH = abs(value.translation.height)
        // Block list-row taps as soon as we see *any* horizontal
        // intent (≥ 4pt and dominant) — even a small `→` drag that
        // never reaches the drawer commit threshold should not
        // surface as a tap on the row underneath when the user
        // releases. The gate uses a TTL deadline so we don't have
        // to schedule a reset; if the gesture is cancelled and
        // `onEnded` never fires, the deadline lapses on its own.
        if absW >= 4 && absW >= absH {
            rowTapGate.suppress()
        }
        if dragDirection == nil {
            if absW > 10 && absW >= absH {
                dragDirection = .horizontal
                dragLockBaseline = value.translation.width
                scrollLocked = true
                detail.offsetBase = detail.offset
            } else if absH > 10 && absH > absW {
                dragDirection = .vertical
            }
        }
        if dragDirection == .horizontal {
            dragOffset = value.translation.width - dragLockBaseline
            if detail.activePost != nil && detail.offsetBase == 0 {
                // Back-drag from the visible overlay. Track the
                // finger so the detail follows the drag out to
                // the right; the inner ScrollView is gated by
                // `isScrollingBlocked` so its pan can't drift
                // under us during the drag.
                detailMediaTapGate.suppress()
                detail.offset = max(0, min(detail.containerWidth, dragOffset))
            } else if detail.activePost != nil && detail.offsetBase >= detail.containerWidth {
                // Forward-swipe reveal: overlay hidden at drag
                // start and finger moving leftward pulls it in.
                // If the finger reverses back rightward past
                // the start, snap the overlay fully hidden again
                // so the next swipe re-enters forward-reveal
                // mode cleanly instead of getting stuck at a
                // partial reveal.
                if dragOffset < 0 {
                    detail.offset = max(0, min(detail.containerWidth, detail.containerWidth + dragOffset))
                } else {
                    detail.offset = detail.containerWidth
                }
            }
        }
    }

    private func onPanEnded(_ value: DragGesture.Value) {
        // No explicit gate reset — `TapSuppressionGate` uses a
        // TTL deadline that lapses on its own (see the class
        // doccomment for why this matters when `.onEnded` is
        // skipped entirely).
        if dragExclusion.kind(at: value.startLocation) != .none {
            resetDragState()
            return
        }
        if startedInBottomBar(value) {
            resetDragState()
            return
        }
        let lockedHorizontal = dragDirection == .horizontal
        let baseline = dragLockBaseline
        let base = detail.offsetBase
        let hasActive = detail.activePost != nil
        let containerW = detail.containerWidth
        resetDragState()

        guard lockedHorizontal else {
            dragOffset = 0
            return
        }

        let velocity = value.predictedEndTranslation.width - value.translation.width
        let traveled = value.translation.width - baseline

        // Detail overlay modes take precedence — the drag already
        // moved `detail.offset` interactively, so committing the
        // correct end state here preserves continuity with the
        // finger's position.
        if hasActive && base == 0 {
            // Back-drag: overlay was fully visible at drag
            // start. Commit to hidden if the finger travelled
            // past the distance / velocity thresholds, else
            // snap back to fully visible.
            let shouldDismiss = detail.shouldDismissSwipe(dx: traveled, velocityX: velocity)
            if shouldDismiss {
                // Goes through `dismissDetailOverlay` so the
                // edit-menu teardown is shared with the
                // header back button — see the helper for
                // why both paths must converge here.
                dismissDetailOverlay(alongsideAnimation: { [self] in dragOffset = 0 })
            } else {
                detail.beginAnimationLock()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    detail.offset = 0
                    dragOffset = 0
                }
            }
            return
        }
        if hasActive && base >= containerW && traveled < 0 {
            // Forward-swipe reveal: low threshold matches the old
            // lastOpenedPost re-push so a light flick from the right
            // edge is enough to pull the overlay back in.
            let shouldReveal = traveled < -32 || velocity < -120
            detail.beginAnimationLock()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                detail.offset = shouldReveal ? 0 : containerW
                dragOffset = 0
                if shouldReveal && drawerOpen {
                    drawerOpen = false
                }
            }
            return
        }

        // Drawer commit (overlay absent, or overlay hidden + drag
        // went rightward).
        let shouldOpen: Bool
        if drawerOpen {
            shouldOpen = !(traveled < -drawerWidth / 3 || velocity < -150)
        } else {
            shouldOpen = (traveled > 50 || velocity > 90)
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            drawerOpen = shouldOpen
            dragOffset = 0
            // If forward-reveal was mid-drag and the user reversed
            // into a drawer gesture, the overlay may still sit at a
            // partial reveal from `onChanged`. Snap it fully hidden
            // here so the next forward-swipe sees the expected base.
            if hasActive && base >= containerW && detail.offset != containerW {
                detail.offset = containerW
            }
        }
    }

    // MARK: - Public ops

    /// Single dismiss chokepoint. Both the back-drag commit and the
    /// header back button route through here so the selection /
    /// edit-menu teardown can't be silently forgotten by a future
    /// third dismiss trigger (deep link, keyboard shortcut, etc.).
    /// `alongsideAnimation` is forwarded to `DetailOverlayController.hide(...)`
    /// so the back-drag site can reset its `dragOffset` inside the
    /// same spring. Closure typed `@MainActor` so the caller can safely
    /// mutate main-actor isolated state (e.g. `dragOffset`) without
    /// relying on `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` to infer it.
    func dismissDetailOverlay(alongsideAnimation: (@MainActor () -> Void)? = nil) {
        resignSelectedTextResponder()
        detail.hide(alongsideAnimation: alongsideAnimation)
    }

    func closeDrawer() {
        resetDragState()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            drawerOpen = false
            dragOffset = 0
        }
    }

    // MARK: - Classifiers

    private func resetDragState() {
        dragDirection = nil
        dragLockBaseline = 0
        scrollLocked = false
        // 드래그 종료 — 같은 좌표에서 새 드래그가 시작돼도 뷰 계층이
        // 바뀌었을 수 있으니(선택 해제, 플레이어 회수) 재분류시킨다.
        dragExclusion.reset()
    }

    private func startedInBottomBar(_ value: DragGesture.Value) -> Bool {
        // Prefer the measured top of the filter+bar area so a tap-with-jitter
        // on a chip ("10추", "이슈모음 전체", etc.) is always classified as
        // belonging to the bar, regardless of chip height / Dynamic Type.
        if bottomAreaTopY.isFinite {
            return value.startLocation.y >= bottomAreaTopY
        }
        guard containerHeight > 0 else { return false }
        return value.startLocation.y > containerHeight - bottomGestureExclusion
    }

    // 키 윈도우 계층을 직접 들여다보는 프로브들(touchStartedNearSelectionHandle /
    // touchStartedOnScrubBar / resignSelectedTextResponder)은
    // GestureExclusions.swift 의 extension 으로 분리 — 이 파일은 팬 상태기계만.
}

private enum DragDirection {
    case horizontal
    case vertical
}
