import SwiftUI

/// State + transitions for the keep-alive `PostDetailView` overlay.
///
/// The overlay is permanent-mounted in `ContentView`'s ZStack — once a
/// post opens the view stays in the SwiftUI tree for the rest of the
/// session. `hide()` only animates it off-screen right; `show(_:)`
/// either re-slides the same post back in (keep-alive path) or rebuilds
/// the overlay around a different post via `.id(post.id)`.
///
/// Pulled out of `ContentView` so that:
///  - Tests can drive the state machine without spinning up SwiftUI
///  - Future overlay-shape changes (e.g. modal vs sheet vs sheetlet) only touch this file
///  - The pan gesture still owns its own drag-state machine; this controller
///    only tracks the *result* of those gestures (`offset`, `offsetBase`).
@Observable
@MainActor
final class DetailOverlayController {
    /// Most recently opened post. Stays non-nil after `hide()` so the
    /// next forward-swipe can restore the same view instantly.
    var activePost: Post?
    /// 0 = overlay fully shown; `containerWidth` = fully hidden off the
    /// right edge. Driven by `show`/`hide` springs and tracked directly
    /// by the pan gesture during interactive back-drags.
    var offset: CGFloat = 0
    /// `offset` snapshot taken when the horizontal drag lock engages.
    /// Lets the gesture classify the drag as back-swipe (base 0) vs
    /// forward-reveal (base `containerWidth`) regardless of how far
    /// the finger has travelled.
    var offsetBase: CGFloat = 0
    /// Held true across the commit/cancel spring so the embedded
    /// `PostDetailView`'s scroll lock stays asserted past the drag's
    /// `onEnded`. Without this the inner ScrollView's contentOffset
    /// can drift mid-bounce.
    var animating: Bool = false
    /// Mirrors `ContentView.containerWidth`. The controller needs it
    /// to compute hide offsets and visibility predicates.
    var containerWidth: CGFloat = 0

    /// In-flight deferred animation from `show(_:)`'s replace branch.
    /// Tracked so `hide()` (and a subsequent `show(_:)`) can cancel it
    /// before the `Task.yield` resumes — otherwise a fast
    /// show → hide sequence could let the show's animation override the
    /// hide. The race is theoretical for current user-driven call sites
    /// (tap then dismiss can't fit inside one runloop tick) but the
    /// cancellation hook keeps future callers safe.
    private var showTask: Task<Void, Never>?
    /// In-flight 350ms timer from `beginAnimationLock`. Tracked so
    /// rapid sequential commits (back-drag dismiss followed by a
    /// forward-reveal within 350ms) don't have the older timer release
    /// the lock early on the newer commit's spring — when that
    /// happens, `PostDetailView`'s inner ScrollView lock drops mid-
    /// settle and `contentOffset` can drift away from where the user
    /// last left it.
    private var animationLockTask: Task<Void, Never>?

    private static let springResponse: Double = 0.32
    private static let springDamping: Double = 0.85
    /// Padded slightly past the spring's response so `animating` doesn't
    /// release mid-bounce. Must stay > `springResponse * 1000`.
    private static let animationLockMs: Int = 350
    /// Fallback off-screen anchor when the very first `show(_:)` runs
    /// before `containerWidth` has been measured. Larger than any
    /// plausible device width (iPad Pro 12.9" landscape ≈ 1366pt) so a
    /// race between scene activation and the first `onPreferenceChange`
    /// can never leave a sliver of the overlay visible.
    private static let unmeasuredContainerFallback: CGFloat = 4096

    /// Open `post`. If it's already the `activePost`, slide the
    /// existing overlay back into view (the underlying
    /// `PostDetailView` still owns its scroll position, image state,
    /// video playback). If it's a different / first post, park the
    /// overlay off-screen, swap `activePost`, then animate in on the
    /// next runloop tick so SwiftUI observes the off-screen starting
    /// position before the spring runs.
    func show(_ post: Post) {
        // Drop any pending deferred-show before scheduling a new one.
        showTask?.cancel()
        if activePost?.id == post.id {
            withAnimation(.spring(response: Self.springResponse, dampingFraction: Self.springDamping)) {
                offset = 0
            }
            return
        }
        // Fallback to a finite off-screen offset on the very first
        // open before the GeometryReader has measured `containerWidth`.
        offset = containerWidth > 0 ? containerWidth : Self.unmeasuredContainerFallback
        activePost = post
        showTask = Task { @MainActor [weak self] in
            // Yield once so SwiftUI observes the off-screen anchor
            // before the animation transaction starts — without this,
            // the offscreen write and the animate-to-0 write could
            // collapse into a single transaction and the spring
            // wouldn't visibly animate in. Equivalent to the
            // `DispatchQueue.main.async` semantic this used to use.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            withAnimation(.spring(response: Self.springResponse, dampingFraction: Self.springDamping)) {
                self.offset = 0
            }
        }
    }

    /// Slide the overlay off-screen right. Intentionally leaves
    /// `activePost` non-nil so a subsequent forward-swipe re-reveals
    /// the same instance. Cancels any in-flight `show` animation so
    /// hide can't be silently overridden by a stale show.
    func hide() {
        showTask?.cancel()
        withAnimation(.spring(response: Self.springResponse, dampingFraction: Self.springDamping)) {
            offset = containerWidth
        }
    }

    /// Hold `animating` true for slightly longer than the spring's
    /// response so the embedded scroll lock doesn't release mid-bounce.
    /// Cancels any prior pending unlock so two rapid commits don't let
    /// the first timer release the lock during the second spring.
    func beginAnimationLock() {
        animationLockTask?.cancel()
        animating = true
        animationLockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.animationLockMs))
            guard !Task.isCancelled else { return }
            self?.animating = false
        }
    }

    /// Recompute on container resize — if the overlay was hidden at
    /// the previous width, keep it hidden at the new width so a
    /// rotation / window resize can't leave a sliver on the right.
    func updateContainerWidth(_ newWidth: CGFloat) {
        let wasHidden = offset >= containerWidth - 0.5 && containerWidth > 0
        containerWidth = newWidth
        if wasHidden { offset = newWidth }
    }

    /// Pan-gesture commit predicate: did the back-drag travel far
    /// enough or fast enough to dismiss the overlay?
    func shouldDismissSwipe(dx: CGFloat, velocityX: CGFloat) -> Bool {
        dx > swipeDistanceThreshold || velocityX > 120
    }

    /// Capped at 32pt so on wider iPad layouts a small, deliberate
    /// drag still commits — without the cap, 8% of a 1024pt landscape
    /// width would require 80pt of finger travel to dismiss.
    var swipeDistanceThreshold: CGFloat {
        min(containerWidth * 0.08, 32)
    }

    /// True while the overlay's tappable area should receive hit-tests.
    /// `containerWidth == 0` covers the brief pre-measurement window.
    var allowsHitTesting: Bool {
        containerWidth == 0 || offset < containerWidth - 0.5
    }

    /// True when the overlay is at least partially visible. Used by
    /// `PostDetailView`'s `isOverlayVisible` so cached image-decode and
    /// inline video playback know whether the user can actually see
    /// the result.
    var isOverlayVisible: Bool {
        containerWidth > 0 && offset < containerWidth - 0.5
    }
}
