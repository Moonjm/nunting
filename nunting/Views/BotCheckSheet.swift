import SwiftUI
import WebKit

/// Modal sheet shown when `Networking` detects a site has served a
/// CAPTCHA interstitial. Loads the original URL inside a WKWebView so
/// the user can solve the challenge interactively; once each top-level
/// navigation finishes, evaluates the page's outerHTML against the
/// same per-host detector that triggered the sheet — when the detector
/// no longer matches (i.e. the page is no longer the challenge),
/// copies cookies from `WKHTTPCookieStore` into `HTTPCookieStorage.shared`
/// (the store URLSession reads from) and signals the coordinator to
/// wake awaiting fetches.
///
/// Using the detector for the solved-signal — rather than a "second
/// didFinish wins" counter — closes two gaps:
///  * Sites that JS-redirect within the challenge page generate
///    multiple `didFinish` calls and would otherwise cookie-bridge
///    mid-challenge.
///  * If the WKWebView happens to land directly on the real content
///    (cached cookie, no challenge served at all), a counter-based
///    solve would wait for a second navigation that never arrives;
///    the detector check resolves on the first finish instead.
struct BotCheckSheet: View {
    let url: URL
    let onResolve: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Re-derive the detector here instead of storing it as a struct
        // property. SwiftUI Views are MainActor-isolated under Swift 6,
        // and a stored `(@Sendable (String) -> Bool)?` field would get
        // captured as a non-Sendable region when forwarded into the
        // child `BotCheckWebView` (which takes a @Sendable closure).
        // The registry lookup is a constant-time host-suffix branch, so
        // calling it inside body costs nothing and keeps the host shell
        // (`RootTabView`) free of the detector wiring too.
        let detector = BotCheckRegistry.detector(for: url)
        return NavigationStack {
            VStack(spacing: 0) {
                Text("이 사이트가 자동등록방지를 요구합니다. 문자를 입력한 뒤 페이지가 넘어가면 자동으로 닫힙니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                BotCheckWebView(
                    url: url,
                    detector: detector,
                    onSolved: {
                        onResolve()
                        dismiss()
                    }
                )
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("자동등록방지")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") {
                        // Manual close — still notify so any in-flight
                        // fetch is unblocked. If the user dismissed before
                        // solving, the retry will fail and surface normally.
                        onResolve()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(true) // Force the toolbar button so we always run onResolve
    }
}

/// UIViewRepresentable for the in-sheet WKWebView. On every top-level
/// navigation `didFinish`, runs the per-host detector against the
/// document's outerHTML; when the detector returns false (i.e. we're
/// no longer on the challenge page), bridges cookies and fires
/// `onSolved`.
private struct BotCheckWebView: UIViewRepresentable {
    let url: URL
    let detector: (@Sendable (String) -> Bool)?
    let onSolved: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSolved: onSolved, detector: detector) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Default data store — its httpCookieStore is what we'll drain
        // into HTTPCookieStorage.shared on success. A nonPersistent
        // store would leave nothing to copy.
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        // Match the URLSession UA so the site doesn't fingerprint a
        // mismatch and re-throw the challenge in the WebView. Using
        // `customUserAgent` (not `applicationNameForUserAgent`) so
        // the Safari/CFNetwork header is fully overridden — the
        // application-name path only edits a suffix.
        webView.customUserAgent = Networking.userAgent

        var request = URLRequest(url: url)
        request.setValue("ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        webView.load(request)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // No-op: URL is set once in makeUIView; navigation drives the
        // rest of the lifecycle.
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSolved: () -> Void
        let detector: (@Sendable (String) -> Bool)?
        /// Guards against `onSolved` firing twice — e.g. a navigation
        /// finishes, we bridge cookies, then a stray pageshow event or
        /// JS-driven SPA navigation produces another `didFinish` before
        /// the sheet has finished dismissing.
        private var didSolve = false

        init(onSolved: @escaping () -> Void, detector: (@Sendable (String) -> Bool)?) {
            self.onSolved = onSolved
            self.detector = detector
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didSolve else { return }
            // No detector registered for this host (shouldn't happen in
            // production — the sheet is only opened from challenges that
            // came through a host the registry covers — but defensive):
            // fall back to "first didFinish = solved" so the sheet
            // doesn't hang.
            guard let detector = detector else {
                Task { @MainActor [self] in
                    await Self.bridgeCookies(from: webView)
                    if !didSolve {
                        didSolve = true
                        onSolved()
                    }
                }
                return
            }
            // Sniff the document body and re-run the detector. Only
            // resolve when the page is no longer the challenge — this
            // way the WebView can re-finish navigations during the
            // challenge (e.g. the form submitting back to itself on a
            // wrong answer) without prematurely closing the sheet.
            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
                guard let self else { return }
                let html = (result as? String) ?? ""
                if detector(html) {
                    // Still on the challenge — wait for the next
                    // didFinish (i.e. user has solved it and the
                    // server has redirected to the real content).
                    return
                }
                Task { @MainActor [self] in
                    await Self.bridgeCookies(from: webView)
                    if !self.didSolve {
                        self.didSolve = true
                        self.onSolved()
                    }
                }
            }
        }

        /// Copies every cookie from WKWebView's cookie store into
        /// `HTTPCookieStorage.shared`. URLSession's default config reads
        /// from the shared store, so freshly-issued bot-check session
        /// cookies become visible to subsequent fetches. Logs counts in
        /// DEBUG so a "user solved but retry still fails" report can be
        /// triaged by checking whether anything actually bridged.
        @MainActor
        private static func bridgeCookies(from webView: WKWebView) async {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
                store.getAllCookies { cont.resume(returning: $0) }
            }
            let shared = HTTPCookieStorage.shared
            for cookie in cookies {
                shared.setCookie(cookie)
            }
            #if DEBUG
            let hosts = Set(cookies.map(\.domain)).sorted().joined(separator: ", ")
            print("[BotCheckSheet] bridged \(cookies.count) cookies (domains: \(hosts.isEmpty ? "<none>" : hosts))")
            #endif
        }
    }
}
