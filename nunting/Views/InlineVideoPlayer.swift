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
            guard let self, let player = self.player else { return }
            player.seek(to: .zero)
            if self.wantsPlay { player.play() }
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
private final class VideoScrubBarView: UIView {
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

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeTimeObserverFromPreviousPlayer(player)
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
        case .ended, .cancelled, .failed:
            isDragging = false
            seekToProgress(progress)
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

private struct FullscreenVideoPlayer: View {
    let url: URL
    var onDismissBegin: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    /// True from presentation until the first video frame is decoded.
    /// We defer `play()` to `.readyToPlay` to keep audio/video in sync,
    /// but the black-and-silent window before that leaves the user
    /// wondering if the tap registered — surface a spinner until the
    /// first frame comes up.
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AVPlayerControllerView(
                url: url,
                isLoading: $isLoading,
                onDismiss: {
                    onDismissBegin()
                    dismiss()
                }
            )
            .ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.4)
            }
        }
    }
}

private struct AVPlayerControllerView: UIViewControllerRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        // PiP adds measurable synchronous setup cost (internal PiP
        // controller wiring + capability probing) on mount — none of the
        // target sites actually need Picture-in-Picture, so disabling
        // shortens the main-thread stall window that starts when the
        // fullScreenCover first presents.
        controller.allowsPictureInPicturePlayback = false

        context.coordinator.installDismissGesture(on: controller.view)

        // Seed the onReady callback now so it exists by the time the
        // KVO observation fires; `updateUIViewController` will refresh
        // it on each SwiftUI re-eval in case the binding's storage
        // identity changes.
        context.coordinator.onReady = { [isLoading = $isLoading] in
            isLoading.wrappedValue = false
        }

        // The bulk of AVPlayerViewController's mount cost lands on the
        // `controller.player = …` assignment (layer allocation, transport
        // control materialisation, KVO wiring, probe of the first few
        // track samples). Doing that synchronously inside
        // `makeUIViewController` means the fullScreenCover present
        // animation and the spinner render both block on the AVKit stall,
        // so the user sees an unresponsive black screen for the first
        // seconds after tap. Hop one runloop tick via `Task { @MainActor }`
        // so SwiftUI's present animation can finish and the spinner paints
        // before AVKit's setup begins — the tap now feels like it
        // registered even though the total load time hasn't changed.
        //
        // The Task handle is stored on the coordinator and cancelled by
        // `dismantleUIViewController`. `[weak controller]` alone is not
        // enough: UIKit retains the controller through the dismiss
        // animation, so without the cancel + `Task.isCancelled` guard
        // below, the body would proceed to build a fresh AVPlayerItem /
        // AVPlayer on the already-dismantled coordinator and play audio
        // over the dismiss animation once `.readyToPlay` fires.
        let capturedURL = url
        context.coordinator.setupTask = Task { @MainActor [weak controller, coordinator = context.coordinator] in
            guard !Task.isCancelled, let controller else { return }
            let item = AVPlayerItem(url: capturedURL)
            let player = AVPlayer(playerItem: item)
            coordinator.player = player
            controller.player = player
            // Loop on end-of-playback: most boards' inline videos are
            // short reaction clips users want to rewatch. NotificationCenter
            // keeps us on `AVPlayer` (not `AVQueuePlayer`) so the rest of
            // the playback / dismantle paths stay unchanged.
            coordinator.observeEndOfItem(item)
            // Defer the first `play()` until the item reports
            // `.readyToPlay` so audio and first decoded picture start
            // together (avoids the "black frame + sound only" case).
            coordinator.startPlaybackWhenReady(item: item)
            coordinator.setupTask = nil
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // URL is fixed for the lifetime of the fullScreenCover presentation
        // (the sheet is tied to `isPresented`, not a dynamic item binding),
        // so there's no URL-change path to reinstall a player here.
        // Refresh the dismiss and ready closures so they point at the
        // latest Binding / environment values — capturing the values
        // once at `makeUIViewController` time would leave us stuck on
        // the initial binding if SwiftUI's diff re-homes the @State.
        context.coordinator.onDismiss = onDismiss
        context.coordinator.onReady = { [isLoading = $isLoading] in
            isLoading.wrappedValue = false
        }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        // Cancel the deferred player-attach Task before touching any state.
        // Without this, UIKit can retain `controller` for the dismiss
        // animation, the Task's `[weak controller]` check succeeds, and it
        // proceeds to wire up a fresh `AVPlayerItem` + `AVPlayer` on the
        // dismantled coordinator — which then plays audio during the
        // dismiss animation once `.readyToPlay` fires.
        coordinator.setupTask?.cancel()
        coordinator.setupTask = nil
        coordinator.removeEndObservation()
        coordinator.player?.pause()
        coordinator.player = nil
        controller.player = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var player: AVPlayer?
        var onDismiss: () -> Void
        /// Invoked once the player item reports `.readyToPlay`.
        /// Refreshed from `updateUIViewController` so the closure always
        /// points at the current `@Binding` storage — capturing the
        /// binding once at `makeUIViewController` time would pin us to
        /// the initial snapshot.
        var onReady: () -> Void = {}

        private weak var dismissPan: UIPanGestureRecognizer?
        private var hasDismissed = false
        private var statusObservation: NSKeyValueObservation?
        /// `NotificationCenter.addObserver(forName:object:queue:using:)`
        /// returns an opaque token that's both the observer and the
        /// removal handle. Stored so dismantle can detach the looping
        /// callback — without removal, the closure (which captures the
        /// coordinator weakly) would dangle on the default center until
        /// the AVPlayerItem itself deallocates.
        private var endObservation: NSObjectProtocol?
        /// Handle to the deferred player-attach Task (see
        /// `makeUIViewController`). Retained here so dismantle can cancel
        /// it before the closure body fires against a torn-down controller.
        var setupTask: Task<Void, Never>?

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        deinit {
            statusObservation?.invalidate()
            if let endObservation {
                NotificationCenter.default.removeObserver(endObservation)
            }
        }

        /// Subscribe to `didPlayToEndTimeNotification` and rewind+resume
        /// playback when the item finishes. Uses `.main` queue so the
        /// `AVPlayer` calls happen on the same actor that drives the
        /// playback layer; AVPlayer's `seek(to:)` and `play()` are
        /// documented as main-thread-affine.
        ///
        /// Cleanup correctness depends on this being called from the
        /// SAME synchronous main-actor span as `setupTask`'s body —
        /// `dismantleUIViewController` runs `setupTask?.cancel()` and
        /// then `removeEndObservation()` back-to-back, which is safe
        /// only because the body has no `await` between the
        /// `Task.isCancelled` guard and the call here. Adding an
        /// `await` (e.g. async asset probing) before this point would
        /// let the registration race past dismantle's removal, leaking
        /// the token for the AVPlayerItem's lifetime.
        func observeEndOfItem(_ item: AVPlayerItem) {
            removeEndObservation()
            endObservation = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self, let player = self.player else { return }
                player.seek(to: .zero)
                player.play()
            }
        }

        func removeEndObservation() {
            if let endObservation {
                NotificationCenter.default.removeObserver(endObservation)
                self.endObservation = nil
            }
        }

        /// Hold off on `play()` until the AVPlayerItem reports it can deliver
        /// frames, so audio doesn't race ahead of the first decoded picture.
        /// `.initial` covers the rare case where the item is already
        /// `.readyToPlay` by the time we attach (cached/short clips).
        ///
        /// Re-entry is harmless: if `.initial` fires already-ready and a
        /// follow-up `.new` notification reaches the closure before the
        /// dispatched main block runs, the second `play()` is idempotent on
        /// an already-playing player and the second `invalidate()` is a
        /// no-op on a nil observation.
        func startPlaybackWhenReady(item: AVPlayerItem) {
            statusObservation?.invalidate()
            statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                guard item.status == .readyToPlay else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.player?.play()
                    self.onReady()
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                }
            }
        }

        func installDismissGesture(on view: UIView) {
            guard dismissPan == nil else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
            pan.cancelsTouchesInView = false
            pan.delegate = self
            view.addGestureRecognizer(pan)
            dismissPan = pan
        }

        @objc private func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
            guard !hasDismissed else { return }
            let translation = recognizer.translation(in: recognizer.view)
            let velocity = recognizer.velocity(in: recognizer.view)

            guard translation.y > 0, abs(translation.y) > abs(translation.x) else { return }

            if recognizer.state == .ended || recognizer.state == .cancelled {
                if translation.y > 70 || velocity.y > 550 {
                    hasDismissed = true
                    player?.pause()
                    onDismiss()
                }
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

// MARK: - WebM (WKWebView fallback)

/// Escape every character that's significant inside an HTML attribute
/// or a `<script>` body so a parser-supplied URL can't break out of
/// `src="…"` and inject markup. Both webm players splice the raw URL
/// into a `loadHTMLString` template, so the escape is the only barrier
/// between attacker bytes and a same-origin script context.
private func htmlAttributeEscaped(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

/// Inline WebM player. AVFoundation can't decode the WebM container
/// (even when the inner codec is VP9, which AVPlayer otherwise
/// supports inside MP4), so we hand the URL to WebKit instead — iOS
/// Safari/WKWebView decode VP8/VP9-in-WebM since 14.1. Mirrors the
/// AVPlayer-based `InlineAutoplayVideoView` API so the SwiftUI parent
/// can branch on container without touching the surrounding chrome.
private struct WebmInlineWebView: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    let onAspectKnown: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAspectKnown: onAspectKnown)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Required so the `<video>` plays in place instead of
        // auto-presenting the system fullscreen player.
        config.allowsInlineMediaPlayback = true
        // Empty set = no user-gesture gate. Combined with the `muted`
        // attribute on the `<video>` element, this lets autoplay kick
        // off the moment the page loads — same gating Safari applies
        // to muted HTML5 video.
        config.mediaTypesRequiringUserActionForPlayback = []
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "aspectReady")
        config.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        // Touches must fall through to the SwiftUI `.onTapGesture`
        // overlay above so a tap routes to fullscreen — exactly the
        // way the AVPlayer path reserves the bottom strip for the
        // scrub bar but the rest for fullscreen. The webm path has no
        // scrub bar, so the entire frame is fullscreen-tap surface and
        // the WKWebView only needs to render frames.
        webView.isUserInteractionEnabled = false

        // Match the AVPlayer path's `atsSafe` upgrade — a parser-emitted
        // `http://` URL would otherwise be blocked by ATS and surface as
        // a silent black frame inside the WKWebView with no diagnostic.
        // Apply to both the `<video src>` and the document's `baseURL`
        // so any same-origin subresources resolve over https too.
        let safe = url.atsSafe
        webView.loadHTMLString(Self.htmlForInline(url: safe), baseURL: safe)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onAspectKnown = onAspectKnown
        context.coordinator.desiredPlaying = isPlaying
        context.coordinator.applyPlaybackState(to: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // WKUserContentController retains its message handlers strongly,
        // so without an explicit removal the coordinator (and any
        // closures it captures) outlives the SwiftUI dismantle and the
        // WebKit content process keeps a reference until the webview
        // itself is collected. Explicit removal lets ARC unwind on
        // the same tick the SwiftUI view goes away.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "aspectReady")
        webView.stopLoading()
        // Force WebKit to release its decoder reservation eagerly —
        // navigating to a blank page tears down the `<video>` element
        // before the WKWebView itself deallocates, matching the
        // `replaceCurrentItem(with: nil)` pattern on the AVPlayer side.
        webView.loadHTMLString("", baseURL: nil)
    }

    private static func htmlForInline(url: URL) -> String {
        // URL bytes come from third-party board HTML via the parsers,
        // and `URL(string:)` accepts characters that aren't valid in a
        // strict RFC 3986 path/query (especially in fragments and query
        // strings). Escape the full set of HTML-attribute-significant
        // characters so an attacker-crafted URL can't break out of the
        // `src="…"` quoting and inject markup or a `<script>` block —
        // anything injected here would run in this WKWebView's origin
        // with reach to the `aspectReady` script-message handler.
        let src = htmlAttributeEscaped(url.absoluteString)
        return """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
          html, body { margin:0; padding:0; height:100%; background:transparent; overflow:hidden; }
          video { width:100%; height:100%; object-fit:contain; display:block; background:transparent; }
        </style>
        </head><body>
        <video src="\(src)" autoplay muted loop playsinline></video>
        <script>
          (function() {
            var v = document.querySelector('video');
            if (!v) return;
            function report() {
              if (v.videoWidth > 0 && v.videoHeight > 0
                  && window.webkit && window.webkit.messageHandlers
                  && window.webkit.messageHandlers.aspectReady) {
                window.webkit.messageHandlers.aspectReady.postMessage({
                  width: v.videoWidth,
                  height: v.videoHeight
                });
              }
            }
            v.addEventListener('loadedmetadata', report);
            if (v.readyState >= 1) report();
          })();
        </script>
        </body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onAspectKnown: (CGFloat) -> Void
        var desiredPlaying = false
        /// Tracks whether the initial `loadHTMLString` finished. Until
        /// then any `evaluateJavaScript` is racing the page's parse
        /// and the `document.querySelector('video')` would silently
        /// return null. Gating on this flag means the first state
        /// transition after load applies cleanly.
        private var hasLoaded = false

        init(onAspectKnown: @escaping (CGFloat) -> Void) {
            self.onAspectKnown = onAspectKnown
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasLoaded = true
            applyPlaybackState(to: webView)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "aspectReady",
                  let body = message.body as? [String: Any],
                  let w = (body["width"] as? NSNumber)?.doubleValue,
                  let h = (body["height"] as? NSNumber)?.doubleValue,
                  h > 0
            else { return }
            onAspectKnown(CGFloat(w / h))
        }

        func applyPlaybackState(to webView: WKWebView) {
            guard hasLoaded else { return }
            let js = desiredPlaying
                ? "var v=document.querySelector('video'); if(v){v.play().catch(function(){});}"
                : "var v=document.querySelector('video'); if(v){v.pause();}"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

/// Fullscreen counterpart of `WebmInlineWebView`. Uses HTML5 native
/// controls (play/pause/scrub/volume) since we can't reuse
/// `AVPlayerViewController` for an unsupported container; the user
/// stays in-app and gets the same drag-down dismiss as the AVPlayer
/// fullscreen path so the gesture vocabulary is consistent.
private struct WebmFullscreenPlayer: View {
    let url: URL
    var onDismissBegin: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            WebmFullscreenWebView(
                url: url,
                onDismiss: {
                    onDismissBegin()
                    dismiss()
                }
            )
            .ignoresSafeArea()
        }
    }
}

private struct WebmFullscreenWebView: UIViewRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        let safe = url.atsSafe
        webView.loadHTMLString(Self.htmlForFullscreen(url: safe), baseURL: safe)

        // Drag-down-to-dismiss, matching `FullscreenVideoPlayer`'s
        // gesture so the dismissal feel is identical regardless of
        // container. `cancelsTouchesInView = false` keeps the HTML5
        // controls reachable — taps land on the `<video>` chrome
        // unless the gesture promotes to a vertical pan.
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDismissPan(_:))
        )
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        webView.addGestureRecognizer(pan)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onDismiss = onDismiss
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private static func htmlForFullscreen(url: URL) -> String {
        let src = htmlAttributeEscaped(url.absoluteString)
        // Start `muted` so autoplay isn't blocked by WebKit's
        // unmuted-autoplay policy; the visible HTML5 controls let
        // the user toggle audio if the clip has a soundtrack.
        return """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
          html, body { margin:0; padding:0; height:100%; background:#000; overflow:hidden; }
          video { width:100%; height:100%; object-fit:contain; display:block; background:#000; }
        </style>
        </head><body>
        <video src="\(src)" autoplay muted loop playsinline controls></video>
        </body></html>
        """
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onDismiss: () -> Void
        private var hasDismissed = false

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        @objc func handleDismissPan(_ recognizer: UIPanGestureRecognizer) {
            guard !hasDismissed else { return }
            let translation = recognizer.translation(in: recognizer.view)
            let velocity = recognizer.velocity(in: recognizer.view)
            guard translation.y > 0, abs(translation.y) > abs(translation.x) else { return }
            if recognizer.state == .ended || recognizer.state == .cancelled {
                if translation.y > 70 || velocity.y > 550 {
                    hasDismissed = true
                    onDismiss()
                }
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
