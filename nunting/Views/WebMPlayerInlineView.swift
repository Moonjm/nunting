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
        // No pool acquire here: the host stacks are eager, so mounting
        // is not evidence that this webm is on-screen. `updateUIView`
        // runs immediately after with the real `isPlaying` and drives
        // the lease from viewport visibility instead. Acquiring at mount
        // let the first two webm rows of a post hold both slots for the
        // whole detail lifetime — every later webm stayed poster-only.
        return container
    }

    func updateUIView(_ container: WebmContainerView, context: Context) {
        context.coordinator.onAspectKnown = onAspectKnown
        context.coordinator.setPlaying(isPlaying)
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
        /// 영상 준비 계측(`kind=media`, t=video)의 기산점 — WKWebView 에 문서를 물린 순간.
        /// webm 은 AVPlayer 를 못 쓰고 WebKit 이 소프트 디코드하므로 준비까지가 더 길다.
        /// 그 길이를 mp4 와 같은 채널에 실어야 "영상이 느리다"가 컨테이너별로 갈린다.
        private var loadStartedAt: Date?
        /// 한 로드당 한 번만 싣기 위한 래치(`loadedmetadata` 는 재부착마다 다시 온다).
        private var didRecordReadiness = false

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
            loadStartedAt = Date()
            didRecordReadiness = false
            webView.loadHTMLString(WebmInlineWebView.htmlForInline(url: safe), baseURL: safe)
            container.attach(webView)
            // Reset `hasLoaded` — a recreated WebView starts fresh, and
            // any previously-cached playback intent will re-apply on
            // didFinish below.
            hasLoaded = false
        }

        /// Viewport-visibility driver, mirroring
        /// `InlineAutoplayUIView.setPlaying`. The lease follows what the
        /// user can see, not the view's lifetime:
        ///   * visible, no webview → try to acquire (poster-only + queued
        ///     as waiter if every slot is busy on-screen).
        ///   * visible, webview alive → tell the pool we're back so the
        ///     slot stops being eviction-eligible.
        ///   * off-screen, webview alive → keep it warm but mark the slot
        ///     eviction-eligible for anyone who needs it.
        ///   * off-screen, no webview → drop out of the waiter queue.
        func setPlaying(_ playing: Bool) {
            desiredPlaying = playing
            if playing {
                if container?.webView == nil {
                    tryRecreateWebView()
                } else {
                    WebMPlayerPool.shared.notifyResumed(self)
                }
            } else {
                if container?.webView == nil {
                    WebMPlayerPool.shared.release(self)
                } else {
                    WebMPlayerPool.shared.notifyPaused(self)
                }
            }
            if let webView = container?.webView {
                applyPlaybackState(to: webView)
            }
        }

        /// `WebMPlayerPool.Leaseholder` — the pool pulled this (off-screen)
        /// lease for a visible view. Drop the WKWebView; `setPlaying(true)`
        /// on the next visible transition re-acquires and reloads.
        func releaseWebViewForPoolEviction() {
            container?.detach()
            hasLoaded = false
        }

        /// `WebMPlayerPool.Leaseholder` — pool promoted us from waiter.
        /// Pool contract: this method MUST call back into `acquire(...)`
        /// so the speculative `waiters.removeFirst()` settles. Calling
        /// acquire unconditionally (rather than guarding on container
        /// state first) satisfies the contract; the `container?.webView
        /// == nil` guard is moved to the *attach* step so a stale
        /// promotion (container already has a webview for some other
        /// reason) doesn't drain the waiter queue without filling the
        /// slot.
        func tryRecreateWebView() {
            guard WebMPlayerPool.shared.acquire(self) else { return }
            if container?.webView == nil {
                attachWebView()
            }
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
            // `aspectReady` 는 `loadedmetadata` 에서 발화한다 — 디코더가 첫 프레임을
            // 낼 준비가 된 시점이라 AVPlayer 의 `.readyToPlay` 와 같은 의미의 지점.
            if !didRecordReadiness, let startedAt = loadStartedAt {
                didRecordReadiness = true
                let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                MediaLoadTelemetry.shared.record(
                    .video(kind: "webm", host: url.host ?? "?", ms: max(0, ms),
                           ctx: "body", ok: true))
            }
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
