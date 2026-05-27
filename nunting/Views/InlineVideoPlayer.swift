import SwiftUI
import AVKit
import UIKit
import WebKit

struct InlineVideoPlayer: View {
    let url: URL
    /// Poster image the parser already discovered (e.g. HTML5
    /// `<video poster="...">` or a site-specific CDN pattern). When nil the
    /// view falls back to the aagag `/o/{q}.jpg` convention and, failing
    /// that, a plain film-icon placeholder. Used as the visual backdrop
    /// shown until the AVPlayer produces its first frame.
    var posterURL: URL? = nil
    /// Set by ContentView's `panGesture` while a back-drag is in flight
    /// so releasing a finger over the inline video doesn't push
    /// fullscreen playback when the user only intended to leave the
    /// detail screen.
    var tapGate: TapSuppressionGate? = nil
    /// Fires the moment the user's drag-down dismiss commits (touch-up
    /// past the threshold), BEFORE SwiftUI starts animating the cover
    /// off-screen. The host view (PostDetailView) raises a full-screen
    /// black overlay during the slide-down so the underlying detail
    /// doesn't progressively reveal — without this, the user sees the
    /// detail content while the cover is still mid-animation, intuits
    /// "the screen is back, I can scroll", and tries to scroll only to
    /// hit the dismiss-event window where touches don't yet route to
    /// the underlying view. The visual cue keeps the intent honest:
    /// nothing to interact with until the cover is fully gone.
    var onDismissBegin: () -> Void = {}

    @State private var isPresented = false
    /// `onScrollVisibilityChange` callback target. Drives the inline
    /// AVPlayer's play/pause so an off-screen video doesn't keep its
    /// decoder spinning. Combined with `!isPresented` (see body) so the
    /// inline player also pauses while the fullscreen cover is up,
    /// avoiding two AVPlayers streaming the same asset in parallel.
    @State private var isVisible = false
    /// Aspect ratio reserved for the player frame. Starts at the
    /// landscape default (16:9 = ~1.78) because most board-uploaded
    /// videos are landscape and that's the better-than-nothing
    /// layout reservation before AVAsset metadata loads. Once the
    /// underlying `InlineAutoplayUIView` finishes reading the
    /// video track's `naturalSize` × `preferredTransform`, it
    /// fires `onAspectKnown` and we snap to the source's true
    /// aspect — vertical clips (9:16 ≈ 0.56) then render tall
    /// instead of letterbox-bound inside a 16:9 box.
    @State private var measuredAspect: CGFloat = 16.0 / 9.0

    var body: some View {
        ZStack {
            Color.black

            if let resolvedPoster {
                // Backdrop poster shown until the AVPlayer renders its
                // first frame. `AVPlayerLayer` with `.resizeAspect` is
                // transparent in any letterbox area, so the poster
                // also fills bars when source aspect doesn't match
                // the reserved frame (mostly during the preroll
                // window before `measuredAspect` snaps in).
                NetworkImage(
                    url: resolvedPoster,
                    thumbnailMaxPointSize: 720
                )
            } else {
                Image(systemName: "film")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }

            // `isPlaying` ANDs visibility with NOT-presented so the
            // inline player pauses while the fullscreen cover takes
            // over. fullScreenCover doesn't unmount the underlying
            // view, so without the second clause the inline AVPlayer
            // would keep streaming alongside the fullscreen one.
            //
            // WebM container is unsupported by AVFoundation regardless
            // of the inner codec (VP9 plays fine in MP4 but not WebM),
            // so etoland's webm uploads route through a WKWebView path
            // — iOS WebKit decodes VP8/VP9-in-WebM since Safari 14.1.
            if isWebmContainer {
                WebmInlineWebView(
                    url: url,
                    isPlaying: isVisible && !isPresented,
                    onAspectKnown: { aspect in
                        if aspect.isFinite && aspect > 0 {
                            measuredAspect = aspect
                        }
                    }
                )
            } else {
                InlineAutoplayVideoView(
                    url: url,
                    isPlaying: isVisible && !isPresented,
                    onAspectKnown: { aspect in
                        // Guard against degenerate metadata (audio-only
                        // tracks or assets where preferredTransform makes
                        // both dimensions zero). Without the guard a
                        // bogus aspect collapses the SwiftUI frame to
                        // zero height and the slot disappears.
                        if aspect.isFinite && aspect > 0 {
                            measuredAspect = aspect
                        }
                    }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(measuredAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Tap-to-fullscreen overlay carved to exclude the bottom strip
        // where the scrub bar's UIKit gesture recognizers live. A
        // whole-frame `.onTapGesture` on the outer ZStack would race
        // SwiftUI's gesture system against the underlying UIKit
        // recognizers — and SwiftUI usually wins for taps that don't
        // turn into pans, so a tap on the scrub bar would open
        // fullscreen instead of seeking. Restricting the SwiftUI tap
        // to the top region leaves the bottom strip as plain SwiftUI
        // dead space; touches there fall through to the
        // `InlineAutoplayUIView` (which contains the scrub bar) and
        // its UIKit gestures fire normally. The constant is owned by
        // the UIView side so the two coordinate spaces can't drift.
        .overlay(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if tapGate?.suppressed == true { return }
                    isPresented = true
                }
                // The WebM (WKWebView) path has no custom UIKit scrub bar
                // to dodge — its WKWebView is `isUserInteractionEnabled =
                // false`, so the SwiftUI tap can safely cover the whole
                // frame and route every tap to fullscreen.
                .padding(.bottom, isWebmContainer ? 0 : InlineAutoplayUIView.scrubBarStripHeight)
        }
        .onScrollVisibilityChange(threshold: 0.1) { visible in
            // 0.1 (10%) instead of 0 so the player doesn't toggle
            // play/pause for sub-pixel frame movement during the
            // ScrollView's first layout pass; visible AVPlayer
            // play()/pause() are documented as cheap but on a long
            // post the back-to-back churn was visible as a frame
            // hiccup.
            isVisible = visible
        }
        .accessibilityLabel("영상 재생")
        .fullScreenCover(isPresented: $isPresented) {
            if isWebmContainer {
                WebmFullscreenPlayer(url: url, onDismissBegin: onDismissBegin)
            } else {
                FullscreenVideoPlayer(url: url, onDismissBegin: onDismissBegin)
            }
        }
    }

    /// Container-extension probe for the WKWebView fallback. Codec
    /// (VP8/VP9/AV1) doesn't matter for AVFoundation gating — the
    /// container itself is unsupported. Extensions on these board CDNs
    /// are reliable; URLs without extensions just default to the
    /// AVPlayer path and surface a load failure if they happen to be
    /// webm-served-as-bytes.
    private var isWebmContainer: Bool {
        url.pathExtension.lowercased() == "webm"
    }

    /// Parser-supplied poster wins; otherwise fall back to the aagag CDN's
    /// `/o/{q}.jpg` pattern, then to `nil` (→ film-icon placeholder).
    private var resolvedPoster: URL? {
        if let posterURL { return posterURL }
        return aagagPosterFallback
    }

    private var aagagPosterFallback: URL? {
        guard url.host?.contains("aagag.com") == true else { return nil }
        let last = (url.path as NSString).lastPathComponent
        guard last.hasSuffix(".mp4") else { return nil }
        let q = String(last.dropLast(4))
        return URL(string: "https://i.aagag.com/o/\(q).jpg")
    }
}

/// SwiftUI bridge for the inline `AVPlayerLayer`. Uses
/// `UIViewRepresentable` because `VideoPlayer` (the SwiftUI native)
/// always shows transport controls, and we want a passive moving-image
/// look — controls only appear in the fullscreen `AVPlayerViewController`
/// after a tap. Each instance owns its own AVPlayer for the lifetime
/// of the SwiftUI view; a future `VideoPlayerPool` will lease these
/// out from a capped pool to bound memory on long posts with many
/// videos.
private struct InlineAutoplayVideoView: UIViewRepresentable {
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
final class InlineAutoplayUIView: UIView {
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

/// Minimal scrub bar — a 3pt-thick progress line at the bottom of the
/// inline video, with a 30pt touch strip wrapped around it for
/// comfortable drag/tap. Renders nothing else (no thumb, no time, no
/// play button) so the inline video keeps its "moving image" feel.
/// Tap anywhere on the strip seeks to that position; pan drags the
/// playhead live then commits on touch-up.
/// Marker conformance used by `ContentView`'s back-drag hit-test to
/// detect that a touch started inside an inline video's scrub strip
/// without exposing the otherwise-`private` `VideoScrubBarView` to
/// other files. A type check (`is InlineVideoScrubBarMarking`) keeps
/// the contract refactor-safe — a string `accessibilityIdentifier`
/// would collide with VoiceOver / UI-test instrumentation and could
/// be silently shadowed by a future contributor who doesn't know
/// gesture routing depends on it.
protocol InlineVideoScrubBarMarking: AnyObject {}

private final class VideoScrubBarView: UIView, InlineVideoScrubBarMarking {

    /// Strong-ish ref via `weak` so the view itself doesn't keep the
    /// AVPlayer alive past the `InlineAutoplayUIView`'s tear-down.
    /// Setter installs/removes the periodic time observer.
    weak var player: AVPlayer? {
        didSet {
            if oldValue === player { return }
            removeTimeObserverFromPreviousPlayer(oldValue)
            installTimeObserver()
            updateFill()
        }
    }

    /// Visible bar height. 3pt is the thinnest that's still
    /// comfortably visible on a retina display; a thicker bar would
    /// pull the eye away from the actual video frame above.
    private let barHeight: CGFloat = 3

    private let backgroundLayer = CALayer()
    private let fillLayer = CALayer()
    /// Translucent black fade behind the bar. The resting track is
    /// white-32% and the fill is white-95%; on videos with bright
    /// pixels at the bottom edge (snow, sky, white-background webcomics)
    /// both layers blend into the frame and the bar disappears.
    /// Painting a short dark gradient under the bar gives consistent
    /// contrast regardless of source content, while staying
    /// unobtrusive enough to preserve the "moving image" feel.
    private let backdropGradient = CAGradientLayer()

    /// `addPeriodicTimeObserver` returns an `Any` token; held so
    /// `removeTimeObserver` can pair off correctly when the player
    /// changes or the bar is torn down.
    private var timeObserverToken: Any?
    /// `true` between drag/pan `.began` and `.ended`. While true the
    /// fill renders from `dragProgress` instead of the player's clock,
    /// so the scrub feels live (no lag while the player processes the
    /// seek). On touch-up we seek and clear the flag.
    private var isDragging = false
    private var dragProgress: Double = 0
    /// Held as a property (not a local in `init`) so `didMoveToWindow`
    /// can install a `require(toFail:)` dependency on the enclosing
    /// scroll view's pan once the view chain is connected — keeping
    /// quick taps as seek while routing scroll attempts to the
    /// parent ScrollView.
    private let tap = UITapGestureRecognizer()
    /// Last scroll view whose pan `tap` was made to require to fail.
    /// Tracked so re-entry to a window (the scrub bar's parent
    /// `InlineAutoplayUIView` is reused via `VideoPlayerPool`, so
    /// `didMoveToWindow` may fire multiple times against different
    /// scroll views) doesn't accumulate dependencies — `require(toFail:)`
    /// has no dedup, and a stale entry would force `tap` to wait for
    /// an unrelated scroll view that never tracks the current touch.
    private weak var tapRequiredScrollPan: UIPanGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // Darken the resting bar so it's visible over both light
        // (snow / sky scenes) and dark (night / black-letterbox)
        // video backgrounds. The fill is brighter for contrast.
        backgroundLayer.backgroundColor = UIColor.white.withAlphaComponent(0.32).cgColor
        fillLayer.backgroundColor = UIColor.white.withAlphaComponent(0.95).cgColor
        backdropGradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
        ]
        backdropGradient.startPoint = CGPoint(x: 0.5, y: 0)
        backdropGradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(backdropGradient)
        layer.addSublayer(backgroundLayer)
        layer.addSublayer(fillLayer)

        let pan = DirectionalScrubPanGestureRecognizer(
            target: self,
            action: #selector(handlePan(_:))
        )
        addGestureRecognizer(pan)
        tap.addTarget(self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeTimeObserverFromPreviousPlayer(player)
    }

    /// Once the view is in a window the superview chain is settled, so
    /// walk up to find the post detail's enclosing `UIScrollView` (the
    /// UIKit object SwiftUI builds `ScrollView` on top of) and make the
    /// seek tap wait for its pan recognizer to fail. The tap then only
    /// fires when the touch ends without enough movement to trigger a
    /// scroll — a deliberate tap on the strip — while a touch that the
    /// scroll view's pan claims (vertical scroll attempt) marks this
    /// tap as failed and skips the seek.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var current: UIView? = superview
        while let c = current {
            if let sv = c as? UIScrollView {
                if sv.panGestureRecognizer !== tapRequiredScrollPan {
                    tap.require(toFail: sv.panGestureRecognizer)
                    tapRequiredScrollPan = sv.panGestureRecognizer
                }
                return
            }
            current = c.superview
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barY = bounds.height - barHeight
        backgroundLayer.frame = CGRect(x: 0, y: barY, width: bounds.width, height: barHeight)
        // Disable implicit CALayer animation so a frame change during
        // bounds updates (e.g. aspect ratio snap on first metadata
        // load) doesn't cross-fade the gradient through a visible
        // transition.
        let backdropHeight: CGFloat = 18
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropGradient.frame = CGRect(
            x: 0,
            y: bounds.height - backdropHeight,
            width: bounds.width,
            height: backdropHeight
        )
        CATransaction.commit()
        updateFill()
    }

    private func updateFill() {
        let progress = displayProgress()
        let barY = bounds.height - barHeight
        let fillWidth = bounds.width * CGFloat(progress)
        // Disable implicit CALayer animation so the fill tracks
        // playback continuously without the default 0.25s cross-fade
        // every time the periodic observer ticks (4× per second).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(x: 0, y: barY, width: fillWidth, height: barHeight)
        CATransaction.commit()
    }

    private func displayProgress() -> Double {
        if isDragging { return dragProgress }
        guard let player, let item = player.currentItem else { return 0 }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return 0 }
        let current = player.currentTime().seconds
        return min(1, max(0, current / duration))
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)
        let progress = max(0, min(1, location.x / bounds.width))
        seekToProgress(progress)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: self)
        let progress = max(0, min(1, location.x / bounds.width))
        switch recognizer.state {
        case .began:
            isDragging = true
            dragProgress = progress
            updateFill()
        case .changed:
            dragProgress = progress
            updateFill()
        case .ended:
            // `.ended` only follows `.began`/`.changed`, so `isDragging`
            // is always set when we land here. The gate is defensive —
            // belt-and-braces against any future code path that fails
            // the recognizer after `.began` and then somehow surfaces
            // `.ended`. UIKit doesn't fire the action when a continuous
            // recognizer transitions `.possible → .failed`, so the
            // directional pan's vertical-drag self-fail never reaches
            // this switch.
            if isDragging {
                isDragging = false
                seekToProgress(progress)
            }
        case .cancelled, .failed:
            // Mid-drag abort. `.cancelled` is the case that actually
            // fires here — UIKit sends it when an external interruption
            // (incoming call, scroll view claiming the touch, view
            // detachment) yanks a recognized continuous gesture out
            // from under us. `.failed` is bundled for symmetry but
            // does not fire for `.possible → .failed`. Snap the fill
            // back to the player's clock instead of stranding it at
            // the abort point; never seek.
            if isDragging {
                isDragging = false
                updateFill()
            }
        default:
            break
        }
    }

    private func seekToProgress(_ progress: Double) {
        guard let player, let item = player.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        // Zero tolerance so the bar lands exactly where the user
        // dragged. Default tolerance can offset the actual seek by
        // ~half a keyframe interval, which is visible as the fill
        // jumping back slightly after touch-up.
        let target = CMTime(seconds: progress * duration, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func installTimeObserver() {
        guard let player else { return }
        // 4 Hz tick is plenty for a 3pt bar — the eye can't resolve
        // sub-quarter-second movement on something that thin. Higher
        // rates (10-30 Hz) wake the main thread for no visual gain.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isDragging else { return }
            self.updateFill()
        }
    }

    private func removeTimeObserverFromPreviousPlayer(_ previous: AVPlayer?) {
        if let token = timeObserverToken, let previous {
            previous.removeTimeObserver(token)
        }
        timeObserverToken = nil
    }
}

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
private final class DirectionalScrubPanGestureRecognizer: UIPanGestureRecognizer {
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
