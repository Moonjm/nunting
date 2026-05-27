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
    var panGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { [self] value in onPanChanged(value) }
            .onEnded { [self] value in onPanEnded(value) }
    }

    private func onPanChanged(_ value: DragGesture.Value) {
        // If the touch started near a visible selection
        // handle (see `touchStartedNearSelectionHandle` for
        // the exact hit-box dimensions and rationale), the
        // user is grabbing it — bail so UITextView's handle
        // pan can run without our back-drag sliding the
        // overlay out underneath it. `value.startLocation`
        // is stable across ticks so the check is consistent
        // for the whole drag.
        if touchStartedNearSelectionHandle(at: value.startLocation) {
            return
        }
        // Scrub strip drags route through the inline player's
        // own UIKit pan — slipping past here would race the
        // back-drag against the scrubber.
        if touchStartedOnScrubBar(at: value.startLocation) {
            return
        }
        // Don't fight the bottom-bar swipe (board step) when the drag
        // started inside the bar's hit area.
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
        if touchStartedNearSelectionHandle(at: value.startLocation) {
            resetDragState()
            return
        }
        if touchStartedOnScrubBar(at: value.startLocation) {
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
    /// same spring.
    func dismissDetailOverlay(alongsideAnimation: (() -> Void)? = nil) {
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

    /// Walk the key window's view hierarchy to find the (at most one)
    /// UITextView that currently has a non-empty selection, then
    /// return `true` if `point` lies within an asymmetric box around
    /// either of its selection-handle anchors. UITextView's own
    /// handle hit-area is tight (~22pt), so a touch landing slightly
    /// off the visible blue circle isn't recognized as a handle drag
    /// and falls into back-swipe classification. Inflate the
    /// effective hit zone — but as a wide-but-short box, not a
    /// 44pt-radius circle:
    ///   * Horizontal `±28pt`: generous slop for users aiming
    ///     sideways of the handle.
    ///   * Vertical `±16pt`: tight enough that handles on adjacent
    ///     text lines don't bleed into each other across every
    ///     Dynamic Type size. The smallest body line height (xSmall,
    ///     ~18pt) puts the adjacent line's top 18pt from the anchor —
    ///     just outside 16pt — so an above-line back-swipe still
    ///     routes to back-drag, not to a phantom handle grab. (A
    ///     circular 44pt radius reached up to 2 lines above/below at
    ///     default line height, which produced the "3-line body,
    ///     bottom-line selection, back-drag from line 1 freezes" bug.
    ///     A tighter 15pt extent worked too but barely covers the
    ///     handle dot's center; 16pt picks up a touch more handle
    ///     slop while still excluding xSmall's adjacent line.)
    ///
    /// `point` is in key-window coordinates (panGesture uses
    /// `coordinateSpace: .global`).
    private func touchStartedNearSelectionHandle(at point: CGPoint) -> Bool {
        guard let window = UIApplication.shared
            .connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first
        else { return false }
        guard let tv = findTextViewWithActiveSelection(in: window) else { return false }
        return tv.selectionHandleAnchorsInWindow().contains { anchor in
            abs(point.x - anchor.x) <= 28 && abs(point.y - anchor.y) <= 16
        }
    }

    /// True when the back-drag's starting touch landed inside an
    /// inline video's scrub strip. `VideoScrubBarView` conforms to
    /// `InlineVideoScrubBarMarking`; hit-testing the key window at
    /// `point` and walking the superview chain catches every active
    /// strip without exposing the otherwise-private class. Bailing
    /// here keeps a rightward scrub drag from also driving the
    /// detail-screen back-slide: the scrub UIKit pan starts at 10pt
    /// of horizontal motion while this SwiftUI DragGesture begins
    /// at 6pt, so without the skip the back-drag would have a 4pt
    /// head start and lock direction to horizontal before the scrub
    /// had a chance to take over.
    private func touchStartedOnScrubBar(at point: CGPoint) -> Bool {
        guard let window = UIApplication.shared
            .connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first
        else { return false }
        var view = window.hitTest(point, with: nil)
        while let v = view {
            if v is InlineVideoScrubBarMarking { return true }
            view = v.superview
        }
        return false
    }

    /// Resign first responder ONLY on the UITextView that currently
    /// holds a non-empty selection — leaving any other editable
    /// view in the hierarchy (search bar, future comment compose
    /// field) untouched. Used at detail-dismissal time so the iOS
    /// edit menu (Copy / Look Up / Translate) doesn't strand on top
    /// of the list after the overlay slides off-screen. The detail
    /// view is kept mounted on dismiss (it's a `.offset()` slide-
    /// out, not a SwiftUI removal), so without explicit teardown
    /// the text view stays first responder forever and UIKit keeps
    /// its menu visible.
    ///
    /// Scoped to foreground-active scenes only — background scenes
    /// on iPad multi-window may legitimately hold their own
    /// selections that an unrelated dismiss shouldn't clear.
    private func resignSelectedTextResponder() {
        for scene in UIApplication.shared.connectedScenes where scene.activationState == .foregroundActive {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let tv = findTextViewWithActiveSelection(in: window) {
                    tv.resignFirstResponder()
                }
            }
        }
    }

    /// Recurse the view tree and stop at the first UITextView with a
    /// non-empty selection. Across the app at most one text view can
    /// hold the system selection at any moment (selecting in one
    /// clears the prior selection), so we don't have to enumerate the
    /// entire tree — first match wins.
    private func findTextViewWithActiveSelection(in view: UIView) -> UITextView? {
        if let tv = view as? UITextView,
           let range = tv.selectedTextRange,
           !range.isEmpty {
            return tv
        }
        for sub in view.subviews {
            if let hit = findTextViewWithActiveSelection(in: sub) {
                return hit
            }
        }
        return nil
    }
}

private enum DragDirection {
    case horizontal
    case vertical
}

/// Reference-typed gate that gestures use to tell child taps
/// "you just saw a horizontal drag — don't fire on release". A class
/// (not @State value type) so that mutating the deadline from a gesture
/// closure doesn't invalidate the SwiftUI body. Both drivers — the list-
/// row drag-vs-tap discriminator and the detail overlay back-drag
/// suppressor for embedded image / video taps — live inside
/// `GestureCoordinator`.
///
/// Stored as an absolute deadline (`suppressedUntil`) instead of a flat
/// `Bool` so a missed reset (drag interrupted by a system alert / app
/// backgrounding mid-gesture / SwiftUI gesture cancellation that doesn't
/// fire `.onEnded`) can't strand the gate `true` and silently kill all
/// future taps. The 250ms TTL covers the longest plausible gap between
/// the last `onChanged` tick and the SwiftUI tap closure firing on the
/// same touch-up — so nothing has to schedule an explicit unblock.
final class TapSuppressionGate {
    var suppressedUntil: Date = .distantPast
    var suppressed: Bool { Date() < suppressedUntil }

    func suppress(for duration: TimeInterval = 0.25) {
        suppressedUntil = Date().addingTimeInterval(duration)
    }
}

private extension UITextView {
    /// Window-coordinate positions of the two selection handles for
    /// the current `selectedTextRange`. Uses `selectionRects(for:)`
    /// (rather than `caretRect(for:)` of the range endpoints) so
    /// selections ending on a soft line-wrap return the visual end
    /// of the previous line rather than a zero-width rect at x=0 on
    /// the next line — handles sit at the trailing glyph position,
    /// not at the start of the next line. Returns `[]` when no
    /// selection rects are available.
    func selectionHandleAnchorsInWindow() -> [CGPoint] {
        guard let range = selectedTextRange, !range.isEmpty else { return [] }
        let rects = selectionRects(for: range)
        guard !rects.isEmpty else { return [] }
        // Start handle sits at the top-left of the rect that contains
        // the selection start; end handle at the bottom-right of the
        // rect that contains the selection end (assumes LTR layout —
        // for RTL the visual-left/right relationship to start/end
        // flips; the parsers in this app only emit Korean / Latin
        // text so LTR is safe). `containsStart` / `containsEnd` flag
        // those rects directly.
        let startRect = rects.first(where: { $0.containsStart })?.rect
            ?? rects.first?.rect
        let endRect = rects.first(where: { $0.containsEnd })?.rect
            ?? rects.last?.rect
        var anchors: [CGPoint] = []
        if let r = startRect {
            anchors.append(convert(CGPoint(x: r.minX, y: r.minY), to: nil))
        }
        if let r = endRect {
            anchors.append(convert(CGPoint(x: r.maxX, y: r.maxY), to: nil))
        }
        return anchors
    }
}
