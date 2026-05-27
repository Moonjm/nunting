import SwiftUI
import UIKit
import WebKit

/// Escape every character that's significant inside an HTML attribute
/// or a `<script>` body so a parser-supplied URL can't break out of
/// `src="…"` and inject markup. Both webm players splice the raw URL
/// into a `loadHTMLString` template, so the escape is the only barrier
/// between attacker bytes and a same-origin script context.
func htmlAttributeEscaped(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

/// Container UIView that holds an optional WKWebView child. Lets the
/// `WebmInlineWebView` representable lease/release the heavy WKWebView
/// without churning the SwiftUI-managed root UIView identity — when
/// `WebMPlayerPool` denies a lease, the container stays mounted but
/// holds no web view (poster shows through the transparent background).
final class WebmContainerView: UIView {
    var webView: WKWebView?

    func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func detach() {
        guard let webView else { return }
        // Same teardown sequence as the prior dismantleUIView path —
        // explicit handler removal + stopLoading + blank load is what
        // gets WebKit to release the decoder + `<video>` element before
        // the WKWebView itself deallocates.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "aspectReady")
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
        self.webView = nil
    }
}

/// Inline WebM player. AVFoundation can't decode the WebM container
/// (even when the inner codec is VP9, which AVPlayer otherwise
/// supports inside MP4), so we hand the URL to WebKit instead — iOS
/// Safari/WKWebView decode VP8/VP9-in-WebM since 14.1. Mirrors the
/// AVPlayer-based `InlineAutoplayVideoView` API so the SwiftUI parent
/// can branch on container without touching the surrounding chrome.
///
/// Pooled through `WebMPlayerPool` (cap 2). On cap, late views render
/// poster-only via SwiftUI's parent overlay and wait for a slot — when
/// some other webm releases (dismantle) the pool promotes this view via
/// `tryRecreateWebView()` and a WKWebView is attached at that point.
struct WebmInlineWebView: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    let onAspectKnown: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onAspectKnown: onAspectKnown)
    }

    func makeUIView(context: Context) -> WebmContainerView {
        let container = WebmContainerView()
        context.coordinator.container = container
        // Try to acquire a pool slot on initial mount. If denied, the
        // container stays empty; the pool will call back via
        // `tryRecreateWebView()` when a slot frees.
        if WebMPlayerPool.shared.acquire(context.coordinator) {
            context.coordinator.attachWebView()
        }
        return container
    }

    func updateUIView(_ container: WebmContainerView, context: Context) {
        context.coordinator.onAspectKnown = onAspectKnown
        context.coordinator.desiredPlaying = isPlaying
        // If we hold a lease, propagate playback state. If not, nothing
        // to do — the container has no webview to drive.
        if let webView = container.webView {
            context.coordinator.applyPlaybackState(to: webView)
        }
    }

    static func dismantleUIView(_ container: WebmContainerView, coordinator: Coordinator) {
        WebMPlayerPool.shared.release(coordinator)
        container.detach()
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

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WebMPlayerPool.Leaseholder {
        let url: URL
        var onAspectKnown: (CGFloat) -> Void
        var desiredPlaying = false
        weak var container: WebmContainerView?
        /// Tracks whether the initial `loadHTMLString` finished. Until
        /// then any `evaluateJavaScript` is racing the page's parse
        /// and the `document.querySelector('video')` would silently
        /// return null. Gating on this flag means the first state
        /// transition after load applies cleanly.
        private var hasLoaded = false

        init(url: URL, onAspectKnown: @escaping (CGFloat) -> Void) {
            self.url = url
            self.onAspectKnown = onAspectKnown
        }

        /// Build + load the WKWebView into the container. Called from
        /// `makeUIView` (initial mount lease granted) and from
        /// `tryRecreateWebView` (deferred grant after another lease
        /// released).
        func attachWebView() {
            guard let container, container.webView == nil else { return }
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
            userContent.add(self, name: "aspectReady")
            config.userContentController = userContent

            let webView = WKWebView(frame: .zero, configuration: config)
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.bounces = false
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.navigationDelegate = self
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
            webView.loadHTMLString(WebmInlineWebView.htmlForInline(url: safe), baseURL: safe)
            container.attach(webView)
            // Reset `hasLoaded` — a recreated WebView starts fresh, and
            // any previously-cached playback intent will re-apply on
            // didFinish below.
            hasLoaded = false
        }

        /// `WebMPlayerPool.Leaseholder` — pool promoted us from waiter.
        /// Re-attempt acquire (now we're at the head of the queue, the
        /// pool guarantees granting); on success attach the WebView.
        func tryRecreateWebView() {
            guard container?.webView == nil else { return }
            if WebMPlayerPool.shared.acquire(self) {
                attachWebView()
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                hasLoaded = true
                applyPlaybackState(to: webView)
            }
        }

        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "aspectReady",
                  let body = message.body as? [String: Any],
                  let w = (body["width"] as? NSNumber)?.doubleValue,
                  let h = (body["height"] as? NSNumber)?.doubleValue,
                  h > 0
            else { return }
            let aspect = CGFloat(w / h)
            Task { @MainActor in
                onAspectKnown(aspect)
            }
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
