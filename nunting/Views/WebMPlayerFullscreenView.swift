import SwiftUI
import UIKit
import WebKit

/// Fullscreen counterpart of `WebmInlineWebView`. Uses HTML5 native
/// controls (play/pause/scrub/volume) since we can't reuse
/// `AVPlayerViewController` for an unsupported container; the user
/// stays in-app and gets the same drag-down dismiss as the AVPlayer
/// fullscreen path so the gesture vocabulary is consistent.
struct WebmFullscreenPlayer: View {
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

struct WebmFullscreenWebView: UIViewRepresentable {
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
