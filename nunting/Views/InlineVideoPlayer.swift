import SwiftUI
import AVKit
import UIKit

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
        .frame(maxWidth: .infinity)
        .aspectRatio(measuredAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if tapGate?.suppressed == true { return }
            isPresented = true
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
            FullscreenVideoPlayer(url: url, onDismissBegin: onDismissBegin)
        }
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
final class InlineAutoplayUIView: UIView {
    private(set) var url: URL?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var endObservation: NSObjectProtocol?
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
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
    }

    deinit {
        // deinit can't await, so call the synchronous portion directly.
        // VideoPlayerPool.release would also be appropriate but the
        // weak reference in the pool's lease list will compact itself
        // on the next acquire — no leak.
        tearDownPlayer()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
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
            // Lazy create: defer AVPlayer instantiation until something
            // actually wants to play. Off-screen video blocks (the
            // "LazyVStack realised but not visible" set) thus sit
            // player-less and don't count against the pool cap.
            if player == nil {
                acquireAndCreatePlayer()
            }
            player?.play()
        } else {
            // Pause keeps the player alive (and the pool slot).
            // Resuming on next setPlaying(true) is a single-call play()
            // with no recreate cost, which matters for the
            // fullscreen-cover-up-and-back transition path where the
            // user sees no player gap.
            player?.pause()
        }
    }

    /// Called by `VideoPlayerPool` when this view's lease is being
    /// evicted to make room for another. The pool has already removed
    /// us from its lease list, so we just tear down the player.
    /// `url` is preserved — if the view becomes visible again later
    /// and `setPlaying(true)` runs, we re-acquire and recreate.
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

    private func acquireAndCreatePlayer() {
        guard let url, player == nil else { return }
        // Pool may evict another view's player before returning. The
        // evicted view stays mounted (poster visible) — its
        // `releasePlayerForPoolEviction` just nilled its AVPlayer.
        VideoPlayerPool.shared.acquire(self)

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
        p.automaticallyWaitsToMinimizeStalling = false

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
    }

    private func tearDownPlayer() {
        aspectTask?.cancel()
        aspectTask = nil
        if let endObservation {
            NotificationCenter.default.removeObserver(endObservation)
        }
        endObservation = nil
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
