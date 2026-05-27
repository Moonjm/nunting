import UIKit

/// Pan recognizer that arbitrates direction itself instead of trusting
/// `UIPanGestureRecognizer`'s magnitude-based threshold. The plain
/// recognizer transitions to `.began` once cumulative motion exceeds
/// ~10pt regardless of direction, so a straight-down drag of (0, 10)
/// inside the scrub strip locks in a horizontal scrub — `handlePan`
/// reads only `location.x`, so the bar slides sideways while the post
/// fails to scroll. Sampling translation post-super doesn't help: by
/// the time `state == .possible` guards we'd run, super has already
/// promoted to `.began` and the action fired.
///
/// Approach: in `.possible`, decide ourselves. Track the touch's
/// start point in `touchesBegan` and on each `touchesMoved` compute
/// the delta directly from `UITouch.location` (without depending on
/// super's internal tracking, which we're about to gate). Then:
///
///   * `|dy| > 4` and `|dy| >= |dx|`  →  set state `.failed`. The
///     enclosing scroll view's pan can then claim the touch and the
///     page scrolls. Biasing the tie (`>=`) toward vertical keeps a
///     finger held still then dragged straight down on the strip
///     from ever falling into the scrub branch.
///   * `|dx| > 10` and `|dx| > |dy|`  →  forward to super, which
///     promotes the gesture to `.began` and lets `handlePan` start
///     scrubbing.
///   * Otherwise — ambiguous or below threshold. Skip the forward so
///     super stays in `.possible` and the direction can resolve over
///     subsequent touches.
///
/// Once we're out of `.possible` (recognized or failed), behaviour is
/// the default `UIPanGestureRecognizer`'s.
final class DirectionalScrubPanGestureRecognizer: UIPanGestureRecognizer {
    private var startLocation: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if startLocation == nil, let touch = touches.first, let view {
            startLocation = touch.location(in: view)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible,
              let touch = touches.first,
              let view,
              let start = startLocation
        else {
            super.touchesMoved(touches, with: event)
            return
        }
        let current = touch.location(in: view)
        let dx = current.x - start.x
        let dy = current.y - start.y
        if abs(dy) > 4, abs(dy) >= abs(dx) {
            state = .failed
            return
        }
        if abs(dx) > 10, abs(dx) > abs(dy) {
            super.touchesMoved(touches, with: event)
        }
        // Ambiguous: don't forward, stay `.possible` for the next move.
    }

    override func reset() {
        super.reset()
        startLocation = nil
    }
}
