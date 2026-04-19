import SwiftUI
import AVKit
import UIKit

struct InlineVideoPlayer: View {
    let url: URL

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            ZStack {
                Color.black

                if let posterURL {
                    CachedAsyncImage(url: posterURL, maxDimension: 720)
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

    /// Construct the poster URL from the aagag CDN's `/{q}.mp4` pattern.
    private var posterURL: URL? {
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
        let player = AVPlayer(url: url)
        context.coordinator.player = player

        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true

        context.coordinator.installDismissGesture(on: controller.view)

        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== context.coordinator.player {
            controller.player = context.coordinator.player
        }
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

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
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
