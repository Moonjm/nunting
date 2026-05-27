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

/// Inline WebM player. AVFoundation can't decode the WebM container
/// (even when the inner codec is VP9, which AVPlayer otherwise
/// supports inside MP4), so we hand the URL to WebKit instead — iOS
/// Safari/WKWebView decode VP8/VP9-in-WebM since 14.1. Mirrors the
/// AVPlayer-based `InlineAutoplayVideoView` API so the SwiftUI parent
/// can branch on container without touching the surrounding chrome.
struct WebmInlineWebView: UIViewRepresentable {
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
