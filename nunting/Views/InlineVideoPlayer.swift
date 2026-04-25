import SwiftUI
import AVKit
import UIKit

struct InlineVideoPlayer: View {
    let url: URL
    /// Poster image the parser already discovered (e.g. HTML5
    /// `<video poster="...">` or a site-specific CDN pattern). When nil the
    /// view falls back to the aagag `/o/{q}.jpg` convention and, failing
    /// that, a plain film-icon placeholder.
    var posterURL: URL? = nil
    /// Set by ContentView's `panGesture` while a back-drag is in flight
    /// so releasing a finger over the play button doesn't push
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

    var body: some View {
        Button {
            if tapGate?.suppressed == true { return }
            isPresented = true
        } label: {
            ZStack {
                Color.black

                if let resolvedPoster {
                    CachedAsyncImage(url: resolvedPoster, maxDimension: 720)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 42, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Circle()
                    .fill(Color.black.opacity(0.58))
                    .frame(width: 58, height: 58)

                Image(systemName: "play.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(x: 2)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
