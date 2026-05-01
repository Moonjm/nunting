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

    private static let springResponse: Double = 0.32
    private static let springDamping: Double = 0.85
    /// Padded slightly past the spring's response so `animating` doesn't
    /// release mid-bounce. Must stay > `springResponse * 1000`.
    private static let animationLockMs: Int = 350

    /// Open `post`. If it's already the `activePost`, slide the
    /// existing overlay back into view (the underlying
    /// `PostDetailView` still owns its scroll position, image state,
    /// video playback). If it's a different / first post, park the
    /// overlay off-screen, swap `activePost`, then animate in on the
    /// next runloop tick so SwiftUI observes the off-screen starting
    /// position before the spring runs.
    func show(_ post: Post) {
        if activePost?.id == post.id {
            withAnimation(.spring(response: Self.springResponse, dampingFraction: Self.springDamping)) {
                offset = 0
            }
            return
        }
        // Fallback to a finite off-screen offset on the very first
        // open before the GeometryReader has measured `containerWidth`.
        offset = containerWidth > 0 ? containerWidth : 1000
        activePost = post
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            withAnimation(.spring(response: Self.springResponse, dampingFraction: Self.springDamping)) {
                self.offset = 0
            }
        }
    }

    /// Slide the overlay off-screen right. Intentionally leaves
    /// `activePost` non-nil so a subsequent forward-swipe re-reveals
    /// the same instance.
    func hide() {
        withAnimation(.spring(response: Self.springResponse, dampingFraction: Self.springDamping)) {
            offset = containerWidth
        }
    }

    /// Hold `animating` true for slightly longer than the spring's
    /// response so the embedded scroll lock doesn't release mid-bounce.
    func beginAnimationLock() {
        animating = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.animationLockMs))
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
