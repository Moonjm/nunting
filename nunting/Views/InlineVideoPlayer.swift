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

    @State private var isPresented = false

    var body: some View {
        Button {
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
            FullscreenVideoPlayer(url: url)
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

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AVPlayerControllerView(url: url) {
            dismiss()
        }
        .ignoresSafeArea()
        .background(Color.black)
    }
}

private struct AVPlayerControllerView: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        context.coordinator.player = player

        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true

        context.coordinator.installDismissGesture(on: controller.view)

        // Calling `play()` synchronously here starts the audio decoder
        // before AVPlayerViewController has materialised its render layer,
        // which is exactly the "black frame + sound only" case the user
        // reported. Defer the first `play()` until the underlying item
        // reports `.readyToPlay` (its first video sample is decoded), so
        // image and audio kick off together.
        context.coordinator.startPlaybackWhenReady(item: item)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // URL is fixed for the lifetime of the fullScreenCover presentation
        // (the sheet is tied to `isPresented`, not a dynamic item binding),
        // so there's no URL-change path to reinstall a player here. Only the
        // dismiss closure is worth refreshing in case SwiftUI rebuilds the
        // parent and captures a new closure identity.
        context.coordinator.onDismiss = onDismiss
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.player = nil
        controller.player = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var player: AVPlayer?
        var onDismiss: () -> Void

        private weak var dismissPan: UIPanGestureRecognizer?
        private var hasDismissed = false
        private var statusObservation: NSKeyValueObservation?

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        deinit {
            statusObservation?.invalidate()
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
                    self?.player?.play()
                    self?.statusObservation?.invalidate()
                    self?.statusObservation = nil
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
