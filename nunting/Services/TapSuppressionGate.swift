import Foundation

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
///
/// `@MainActor` is explicit (rather than relying on
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) so the gate's contract
/// — only-touched-on-main-actor — survives an isolation-default flip and
/// is locally inspectable for the external readers in `PostDetailView` /
/// `PostDetailComments` / `InlineVideoPlayer`.
@MainActor
final class TapSuppressionGate {
    var suppressedUntil: Date = .distantPast
    var suppressed: Bool { Date() < suppressedUntil }

    func suppress(for duration: TimeInterval = 0.25) {
        suppressedUntil = Date().addingTimeInterval(duration)
    }
}
