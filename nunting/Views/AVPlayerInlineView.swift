import SwiftUI
import UIKit
import AVFoundation
import AVKit

/// SwiftUI bridge for the inline `AVPlayerLayer`. Uses
/// `UIViewRepresentable` because `VideoPlayer` (the SwiftUI native)
/// always shows transport controls, and we want a passive moving-image
/// look — controls only appear in the fullscreen `AVPlayerViewController`
/// after a tap. Each instance owns its own AVPlayer for the lifetime
/// of the SwiftUI view; a future `VideoPlayerPool` will lease these
/// out from a capped pool to bound memory on long posts with many
/// videos.
struct InlineAutoplayVideoView: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    /// Fired on the main actor once the AVAsset's video track reports
    /// its `naturalSize × preferredTransform`. Lets the SwiftUI parent
    /// snap its `.aspectRatio` modifier from the 16:9 default to the
    /// source's true aspect so vertical clips render tall instead of
    /// being letterboxed inside a landscape frame. May fire 0 or 1
    /// times per `setURL` call (audio-only assets or load failures
    /// just don't fire).
    let onAspectKnown: (CGFloat) -> Void

    func makeUIView(context: Context) -> InlineAutoplayUIView {
        let view = InlineAutoplayUIView()
        view.onAspectKnown = onAspectKnown
        view.setURL(url)
        view.setPlaying(isPlaying)
        return view
    }

    func updateUIView(_ uiView: InlineAutoplayUIView, context: Context) {
        // Refresh the closure on every SwiftUI re-evaluation so it
        // always points at the current @State storage (parent's
        // `measuredAspect` setter), not whatever closure happened to
        // be captured at `makeUIView` time.
        uiView.onAspectKnown = onAspectKnown
        if uiView.url != url {
            uiView.setURL(url)
        }
        uiView.setPlaying(isPlaying)
    }

    static func dismantleUIView(_ uiView: InlineAutoplayUIView, coordinator: ()) {
        // SwiftUI's representable lifecycle drops the view here when
        // its parent goes away (e.g. PostDetailView pop, LazyVStack
        // derealize on long-distance scroll). Without explicit
        // teardown, the AVPlayer + its KVO observers + the
        // didPlayToEndTimeNotification token would survive until ARC
        // walked them down — which is enough to leave a paused player
        // holding its decoder reservation past the view's lifetime.
        uiView.teardown()
    }
}

/// Internal (not file-private) so `VideoPlayerPool` can hold weak refs
/// for its eviction callbacks. Same UIView the SwiftUI representable
/// above wraps — there's no second consumer.
///
/// `@MainActor` is explicit even though `UIView` already implies it
/// under Swift 6 default-isolation. Pinning it at the type level
/// hardens the contract `VideoPlayerPool` relies on (the pool is
/// `@MainActor` and assumes it can call this view's methods
/// synchronously) against future Swift mode changes or accidental
/// `nonisolated` overrides on individual methods.
@MainActor
final class InlineAutoplayUIView: UIView, VideoPlayerPool.Leaseholder {
    /// Bottom strip height reserved for the scrub bar's UIKit gesture
    /// recognizers. The SwiftUI tap-to-fullscreen overlay excludes
    /// the same height via `.padding(.bottom:)` so the two
    /// coordinate spaces stay in lockstep — a single owner here
    /// prevents silent drift if either side is later tuned.
    static let scrubBarStripHeight: CGFloat = 48

    private(set) var url: URL?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private let scrubBar = VideoScrubBarView()
    private var endObservation: NSObjectProtocol?
    /// KVO on `AVPlayerItem.status`. Triggers pool release + player
    /// teardown when the item moves to `.failed` so a 404 / corrupt
    /// stream / unreachable host doesn't permanently consume one of
    /// the pool's three lease slots — without this, a long post with
    /// one bad URL silently caps inline playback to two videos for
    /// the rest of the page.
    private var statusObservation: NSKeyValueObservation?
    /// Latest `setPlaying` value. Stored so `setURL` (which doesn't
    /// create a player by itself) and pool-eviction recovery (which
    /// recreates a player when the view next becomes visible) can read
    /// the desired state — the SwiftUI representable only re-runs
    /// `setPlaying` on state change, not periodically.
    private var wantsPlay = false
    /// Fired once per asset load with the source's true aspect ratio
    /// (width / height after preferredTransform). Replaced by
    /// `updateUIView` on every SwiftUI re-evaluation so the closure
    /// captures the current state setter, not the one alive at
    /// `makeUIView` time.
    var onAspectKnown: ((CGFloat) -> Void)?
    /// Aspect-load task handle. Held so a URL change mid-load can
    /// cancel the previous task before its callback fires against
    /// the new asset and reports the wrong aspect.
    private var aspectTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // The AVPlayerLayer renders into this view's layer hierarchy;
        // making the host view itself transparent lets the SwiftUI
        // poster show through during preroll and in any letterbox area.
        isOpaque = false
        addSubview(scrubBar)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        addSubview(scrubBar)
    }

    deinit {
        // `deinit` is nonisolated in Swift 6 even on a `@MainActor`
        // class. UIView's deallocation is documented to occur on the
        // main thread, so `MainActor.assumeIsolated` is safe and
        // gives `tearDownPlayer` (which touches UIKit + AVPlayer
        // observer state) the actor context it needs.
        MainActor.assumeIsolated {
            tearDownPlayer()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
        // Scrub bar sits at the bottom of the video frame. The view's
        // outer height includes touch-target padding above the visible
        // 3pt bar; pinning it to a `scrubBarStripHeight`-tall strip at
        // the bottom (Apple HIG's 44pt minimum + a few pt headroom)
        // gives a comfortable drag area on the thin bar without
        // forcing pixel-perfect aim. Tap on this strip is absorbed
        // by the scrub bar's own gesture recognizers, so the SwiftUI
        // parent's `.onTapGesture` (fullscreen trigger) only fires
        // for taps above this region — the intended split between
        // "scrub" and "open fullscreen".
        scrubBar.frame = CGRect(
            x: 0,
            y: bounds.height - Self.scrubBarStripHeight,
            width: bounds.width,
            height: Self.scrubBarStripHeight
        )
        bringSubviewToFront(scrubBar)
    }

    func setURL(_ newURL: URL) {
        if url == newURL { return }
        // URL change mid-lifetime: tear down current player (if any)
        // and reset URL. Player creation is now deferred to
        // `setPlaying(true)`; the SwiftUI representable's
        // `updateUIView` will call setPlaying right after setURL with
        // the latest desired state, so a play-while-visible swap
        // recreates the player against the new URL on the same tick.
        VideoPlayerPool.shared.release(self)
        tearDownPlayer()
        url = newURL
    }

    func setPlaying(_ playing: Bool) {
        wantsPlay = playing
        if playing {
            if player == nil {
                // No player yet — either initial state or we were
                // evicted earlier. Try to acquire a slot. If the
                // pool denies (all leases playing), the view stays
                // poster-only and the pool will call us back via
                // `tryRecreatePlayer()` when a slot opens.
                tryRecreatePlayer()
            } else {
                // Player survived a brief off-screen pause (lease kept
                // alive but flagged `isPaused` by `notifyPaused`).
                // Tell the pool the lease is active again so this
                // now-visible video is no longer eviction-eligible —
                // otherwise a later acquire could evict it mid-screen
                // and, with no further visibility change to re-fire
                // `setPlaying`, it would stall on its poster. This is
                // the "scroll back up and a visible video stops
                // playing" bug. `player != nil` here guarantees we
                // still hold a pool lease (every path that nils the
                // player also releases the lease, except this kept-warm
                // pause), so `notifyResumed`'s lease lookup always hits.
                VideoPlayerPool.shared.notifyResumed(self)
                player?.play()
            }
        } else {
            if player != nil {
                // Has player. Notify pool the slot is paused so it's
                // eligible for eviction in favour of another view's
                // acquire (or a waiter's promotion). Keep the
                // player alive for fast resume on the next
                // setPlaying(true) — fullscreen cover toggle and
                // brief scroll flickers benefit from the avoided
                // recreate cost.
                VideoPlayerPool.shared.notifyPaused(self)
                player?.pause()
            } else {
                // Was waiting (no player but wantsPlay had been true).
                // User no longer wants playback here, so cancel the
                // wait — frees the queue position for any later
                // genuine waiter and prevents the pool from
                // promoting us into a pointless player creation.
                VideoPlayerPool.shared.release(self)
            }
        }
    }

    /// Called by `VideoPlayerPool` to either:
    ///   1. Notify of an eviction (when the pool pulled this view's
    ///      lease to make room for another) — `tearDownPlayer` runs
    ///      synchronously below in `releasePlayerForPoolEviction`.
    ///   2. Promote this view from the waiter list (when a slot
    ///      freed up) — this method retries `acquire` and creates
    ///      the player on success.
    func tryRecreatePlayer() {
        guard wantsPlay, player == nil, url != nil else { return }
        if VideoPlayerPool.shared.acquire(self) {
            createPlayer()
            player?.play()
        }
        // If denied here too (race: another view acquired between
        // promotion and this retry), the pool re-queues us and the
        // next `notifyPaused`/`release` will re-promote.
    }

    /// Called by `VideoPlayerPool` when this view's lease is being
    /// evicted to make room for another. The pool has already removed
    /// us from its lease list; we just tear down the player. `url`
    /// is preserved so the next `setPlaying(true)` can recreate.
    ///
    /// Recovery path: in current call sites, eviction targets only
    /// **paused** leases (`Lease.isPaused == true`), which by
    /// invariant means the view's most recent SwiftUI state was
    /// `setPlaying(false)` (`wantsPlay == false`). Recovery happens
    /// when SwiftUI later fires `setPlaying(true)` on visibility
    /// return — NOT via the waiter list. The waiter list applies
    /// only to views that asked for a lease and got denied because
    /// every existing slot was actively playing; an evicted view
    /// is dropped on the floor here. If a future change ever evicts
    /// a `wantsPlay == true` lease (e.g., a "playing slot can be
    /// preempted by a higher-priority view" feature), this method
    /// would also need to enqueue the evicted view as a waiter.
    func releasePlayerForPoolEviction() {
        tearDownPlayer()
    }

    /// Full SwiftUI dismantle path. Release pool lease too (deinit
    /// will catch it via weak compaction otherwise, but releasing
    /// eagerly frees the slot for the next acquire one frame sooner).
    func teardown() {
        VideoPlayerPool.shared.release(self)
        tearDownPlayer()
        url = nil
        wantsPlay = false
    }

    /// Build the AVPlayer + layer + observers for the current `url`.
    /// Pool acquire is the caller's responsibility (`setPlaying(true)`
    /// → `tryRecreatePlayer` handles it). Pre-conditions: `url` set,
    /// `player` nil, pool lease already acquired.
    private func createPlayer() {
        guard let url, player == nil else { return }

        let safeURL = url.atsSafe
        let asset = AVURLAsset(url: safeURL)
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)

        // Asynchronously read the source's aspect ratio so the SwiftUI
        // parent can swap its layout reservation from 16:9 to the
        // actual aspect — vital for vertical clips. Done off the main
        // actor; the callback is hopped back via `await MainActor.run`.
        // Cancellation: `tearDownPlayer` cancels the handle so a
        // pool eviction mid-load doesn't fire a stale aspect callback.
        aspectTask = Task { [weak self] in
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return }
                let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                let displayed = size.applying(transform)
                let w = abs(displayed.width)
                let h = abs(displayed.height)
                guard h > 0 else { return }
                let aspect = w / h
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.onAspectKnown?(aspect)
                }
            } catch {
                // Swallow load errors — the 16:9 default stands and
                // the player itself will surface playback failures
                // via the AVPlayerItem status path if the asset is
                // unreachable. No need to cascade an aspect-load
                // failure into a separate UI state.
            }
        }
        // Muted autoplay is the only form iOS allows without a user
        // gesture. Silent switch is irrelevant for muted output, so
        // the inline preview plays regardless of the device's silent
        // mode — same UX Safari ships for `<video muted autoplay>`.
        p.isMuted = true
        // `.none` keeps AVPlayer from inserting its own end-of-playback
        // gap; the loop is driven by `didPlayToEndTimeNotification`
        // below so the seek + play happens back-to-back.
        p.actionAtItemEnd = .none
        // Skip the implicit preroll wait. `automaticallyWaitsToMinimizeStalling`
        // = true defers `play()` until the player has buffered enough
        // data to play through; for short looped clips on board CDNs
        // that's overkill and adds 1-3s of black before first frame.
        // Setting false makes `play()` start the moment the decoder
        // produces a frame, accepting brief stalls on slow networks
        // in exchange for a snappier feel on the typical Wi-Fi path.
        // TODO(deferred per body-media-refactor.md §8): on cellular
        // / Low Power Mode, flip this back to `true` (or skip
        // autoplay entirely) so weak connections don't stutter-loop
        // every video that scrolls into view. The §8 work also adds
        // a Settings toggle for the cellular auto-play preference.
        p.automaticallyWaitsToMinimizeStalling = false

        // Observe AVPlayerItem.status. On `.failed` (404, malformed
        // stream, ATS block on a redirect, etc.), release the pool
        // lease and tear down the player so a single bad URL doesn't
        // hold one of the three pool slots indefinitely. The poster
        // stays on screen — no special failure UI for now, matching
        // the inline-image fail-silent stance for decorative slots.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                VideoPlayerPool.shared.release(self)
                self.tearDownPlayer()
            }
        }

        let layer = AVPlayerLayer(player: p)
        layer.videoGravity = .resizeAspect
        layer.frame = bounds
        self.layer.addSublayer(layer)

        // Loop on end-of-playback. Same pattern the FullscreenVideoPlayer
        // uses — AVPlayer (vs AVQueuePlayer + AVPlayerLooper) keeps the
        // teardown path simple and matches the typical short reaction-clip
        // length boards ship.
        endObservation = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this block runs on the main
            // queue, so `assumeIsolated` is a static promotion from the
            // observer's `@Sendable` signature into MainActor context —
            // no actual hop and no runtime check beyond the assertion.
            // Lets the closure touch `player` / `wantsPlay` directly
            // under Swift 6 strict concurrency without an extra Task
            // hop that would defer the loop seek to the next runloop.
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                player.seek(to: .zero)
                if self.wantsPlay { player.play() }
            }
        }

        self.player = p
        self.playerLayer = layer
        scrubBar.player = p
    }

    private func tearDownPlayer() {
        aspectTask?.cancel()
        aspectTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObservation {
            NotificationCenter.default.removeObserver(endObservation)
        }
        endObservation = nil
        // Drop scrub-bar reference BEFORE nulling the player so the
        // bar's periodic time observer is removed from the live
        // player (its `player.didSet` calls
        // `removeTimeObserver(timeObserver)`); otherwise we'd leak
        // the observer attached to the about-to-be-released player.
        scrubBar.player = nil
        player?.pause()
        // `replaceCurrentItem(with: nil)` releases the AVPlayerItem +
        // its decoder reservation eagerly; without it the OS holds the
        // resources until ARC walks the player down, which on a long
        // post with many video blocks compounds into a measurable
        // pressure spike at LazyVStack derealize boundaries.
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }
}
