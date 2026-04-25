import SwiftUI
import UIKit

struct PostDetailView: View, Equatable {
    let post: Post
    let readStore: ReadStore
    let cache: PostDetailCache
    /// Flipped by ContentView's `panGesture` while a back-drag is in
    /// flight so an image / video tap firing on the same touch-up
    /// doesn't open a viewer / fullscreen player when the user was only
    /// trying to leave the detail screen.
    var tapGate: TapSuppressionGate? = nil
    /// True while the overlay is actually on-screen. Keep-alive means the
    /// view instance survives `hideDetail()` with only `detailOffset`
    /// animated off — UIKit never deallocates the hosted scrollview, so
    /// `StatusBarTapScrollClaimer` needs an explicit signal to release
    /// its grip on the list's `scrollsToTop` flag when the overlay
    /// slides off-screen.
    var isOverlayVisible: Bool = true
    /// Forwarded to `.scrollDisabled` on the inner `ScrollView` while a
    /// horizontal back-drag is in flight or the post-release spring is
    /// still settling — without it, layout callbacks during the spring
    /// can drift `contentOffset` and the scroll position the user had
    /// on dismiss isn't preserved for re-entry.
    var isScrollingBlocked: Bool = false
    /// Invoked from the custom back button in the header. The parent owns the
    /// overlay offset animation; this view just asks to be dismissed.
    let onDismiss: () -> Void

    // Without this explicit Equatable, SwiftUI can't compare `onDismiss`
    // (closures aren't Equatable) and treats PostDetailView as "possibly
    // changed" on every parent re-eval. During a back-drag the parent
    // re-evaluates every frame (detailOffset animates), so the inner
    // ScrollView + body VStack + comments LazyVStack of a long post gets
    // re-built on every frame too. Combined with heavy async image
    // decode that churn is expensive. Comparing the diffable inputs
    // (`post`, `isOverlayVisible`, `isScrollingBlocked`) lets SwiftUI
    // short-circuit the diff, while still propagating the scroll-lock
    // flip and any post-metadata change (title, commentCount, …) at
    // their edges.
    //
    // Fields deliberately excluded from `==`:
    // - `readStore`, `cache`: read only from `.task { … }`, never from
    //   `body`. Mutations don't need a body re-eval to propagate.
    // - `tapGate`: read synchronously from `.onTapGesture` closures at
    //   tap time, not from `body`. Same reasoning as readStore/cache.
    // - `onDismiss`: deliberately ignored — the closure captures
    //   ContentView's `hideDetail()`, which mutates `@State` via
    //   out-of-line storage, so calling the first-eval closure still
    //   mutates the current state.
    static func == (lhs: PostDetailView, rhs: PostDetailView) -> Bool {
        lhs.post == rhs.post
            && lhs.isOverlayVisible == rhs.isOverlayVisible
            && lhs.isScrollingBlocked == rhs.isScrollingBlocked
    }

    @State private var detail: PostDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedImage: ImageViewerItem?
    @State private var webItem: WebBrowserItem?

    /// Minimum wall-clock delay between view appearance and the first
    /// `detail = ...` commit. Must exceed the iOS push animation (~350ms);
    /// committing earlier causes SwiftUI to build the image-heavy subtree
    /// on top of still-running animation frames and the push visibly
    /// stutters. Network fetch + SwiftSoup parse + comments fetch all run
    /// in parallel during this window, so the gate is "free" whenever
    /// load work is slower than animation; when load is faster, we pay the
    /// remainder to protect the animation.
    private static let renderCommitDelay: Duration = .milliseconds(400)

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            ScrollView {
                // Claims UIKit's status-bar-tap scroll-to-top for this
                // detail ScrollView. When the overlay is live, the list
                // screen behind is also visible with its own scrollsToTop
                // scroll view; having two in the window makes iOS scroll
                // neither. The claimer disables the other scroll views'
                // scrollsToTop while `isOverlayVisible == true`, and
                // restores them the moment the overlay slides off.
                StatusBarTapScrollClaimer(isActive: isOverlayVisible)
                    .frame(width: 0, height: 0)
                VStack(alignment: .leading, spacing: 16) {
                    WrappingTitleLabel(text: post.title)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Text(post.author)
                        Text(detail?.fullDateText ?? post.dateText)
                        if let views = detail?.viewCount {
                            Text("👁 \(views)")
                        }
                        if post.commentCount > 0 {
                            Text("💬 \(post.commentCount)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let source = detail?.source {
                        SourceBanner(source: source)
                    }

                    Divider()

                    articleContent

                    if let comments = detail?.comments, !comments.isEmpty {
                        CommentsSection(
                            comments: comments,
                            tapGate: tapGate,
                            onImageTap: { url in
                                if tapGate?.suppressed == true { return }
                                selectedImage = ImageViewerItem(url: url)
                            }
                        )
                            .padding(.top, 8)
                    }
                }
                .padding()
            }
            .scrollDisabled(isScrollingBlocked)
        }
        // Fill the hosted container even when the SwiftUI ideal size would
        // otherwise be smaller — UIHostingController inside our overlay
        // representable sizes to its SwiftUI ideal by default, which left
        // the VStack vertically centered within a larger ZStack frame and
        // exposed the list underneath at the top/bottom bands.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Background spans the full frame including under the status
        // bar / notch so the list screen beneath the overlay doesn't
        // peek through the top safe area. The header VStack still
        // respects safe area, so the chevron / site name land below
        // the status bar as expected.
        .background(Color("AppSurface").ignoresSafeArea())
        // Intercept every link tap inside the detail view (body anchor
        // tags, NSDataDetector-autolinked URLs, comment body markdown links,
        // DealLinkBanner, YouTubeBanner, source badges…) and route
        // http/https targets through SFSafariViewController instead of
        // bouncing to the system Safari app. Non-web schemes fall through to
        // system handling so `tel:` / `mailto:` still work. Comment
        // @mentions are text-styled (not assigned a `.link` attribute), so
        // they don't fire `openURL` and aren't affected.
        //
        // `tapGate` short-circuit mirrors the image / video onTapGesture
        // guards: a right-edge back-drag fires `tapGate.suppress()` from
        // `ContentView.panGesture`, and on touch-up SwiftUI still delivers
        // the link tap that landed under the finger. Without this, a
        // back-swipe started over a linked span (body anchor, deal banner,
        // source badge) dismisses the detail AND opens SafariView on top
        // of the list — discard the openURL when the gate is hot.
        .environment(\.openURL, OpenURLAction { url in
            if tapGate?.suppressed == true { return .discarded }
            return presentInBrowser(url) ? .handled : .systemAction
        })
        .task(id: post.id) {
            readStore.markRead(post)
            // Cache hit → restore instantly with no render gate. The push
            // animation isn't at risk when the image subtree was already
            // materialised (and then dropped) once this session; cached
            // URLs are warm in `CachedAsyncImage`'s own store and decoding
            // stays off the main thread.
            if let entry = cache.get(id: post.id) {
                detail = entry.detail
                isLoading = false
                return
            }
            // Anchor the commit gate at view appearance; load() starts work
            // immediately and only waits on this deadline before writing
            // image-heavy state.
            let renderReadyAt = ContinuousClock.now.advanced(by: Self.renderCommitDelay)
            await load(renderReadyAt: renderReadyAt)
        }
        .fullScreenCover(item: $selectedImage) { item in
            ImageViewer(url: item.url)
        }
        .sheet(item: $webItem) { item in
            SafariView(url: item.url)
                .ignoresSafeArea()
        }
    }

    /// Custom top bar. We present this view as a ZStack overlay (not through
    /// NavigationStack), so `.navigationTitle`/`.toolbar` have no effect and
    /// we render chrome ourselves. Fixed-width side buttons keep the site
    /// name visually centred.
    private var detailHeader: some View {
        HStack(spacing: 0) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            Spacer(minLength: 0)
            Text(post.site.displayName)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                presentInBrowser(post.url)
            } label: {
                Image(systemName: "safari")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Color("AppSurface"))
        .overlay(Divider(), alignment: .bottom)
    }

    /// Wraps the scheme gate + state assignment so the header button and
    /// the `openURL` environment override share one code path. Returns
    /// whether the URL was routed in-app so the OpenURLAction can report
    /// `.handled` vs `.systemAction` from the same check.
    @discardableResult
    private func presentInBrowser(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        webItem = WebBrowserItem(url: url)
        return true
    }

    @ViewBuilder
    private var articleContent: some View {
        if isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 40)
        } else if let errorMessage {
            ContentUnavailableView("불러오기 실패", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if let detail {
            // Eager VStack (not LazyVStack): keeps every body block's
            // height pinned once measured. A `LazyVStack` here let SwiftUI
            // derealize body items above the viewport when the user
            // scrolled deep into comments; on re-realize the image
            // placeholders collapsed to `minHeight: 120` before their
            // aspect-ratio frame came back, the running content height
            // contracted, and the viewport (deep at the comments) landed
            // past content-end — "back-drag from comments area → blank
            // screen". Fetch / decode throughput is already bounded by
            // `ImageThrottle` inside `CachedAsyncImage`, so losing the
            // lazy gate doesn't burst concurrent downloads.
            VStack(alignment: .leading, spacing: 12) {
                ForEach(detail.blocks) { block in
                    switch block.kind {
                    case .richText(let segments):
                        Text(attributedString(from: segments))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .image(let url, let aspectRatio):
                        CachedAsyncImage(
                            url: url,
                            maxDimension: 1000,
                            maxPixelArea: 8_000_000,
                            aspectRatio: aspectRatio,
                            cacheVariant: "article-inline"
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if tapGate?.suppressed == true { return }
                            selectedImage = ImageViewerItem(url: url)
                        }
                    case .video(let url, let posterURL):
                        InlineVideoPlayer(url: url, posterURL: posterURL, tapGate: tapGate)
                    case .dealLink(let url, let label):
                        DealLinkBanner(url: url, label: label)
                    case .embed(.youtube, let id):
                        YouTubeBanner(videoID: id)
                    case .embed(.instagram, let id):
                        if let url = URL(string: "https://www.instagram.com/p/\(id)/") {
                            DealLinkBanner(url: url, label: "Instagram 게시물 보기")
                        }
                    }
                }
            }
        }
    }

    private func attributedString(from segments: [InlineSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let s):
                // Source sites often paste URLs as plain text (ddanzi's
                // `autolink` addon, for instance, only wraps them client-side
                // so the server HTML still exposes the bare string). Run
                // NSDataDetector so those become tappable too — explicit <a>
                // tags go through the `.link` branch below and keep their
                // original label.
                result.append(Self.linkifyPlainText(s))
            case .link(let url, let label):
                var part = AttributedString(label)
                part.link = url
                part.foregroundColor = .accentColor
                part.underlineStyle = .single
                result.append(part)
            }
        }
        return result
    }

    /// Shared across post renders; NSDataDetector is thread-safe once
    /// constructed and allocating it per call would dwarf the actual
    /// detection cost on long bodies.
    private static let urlDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func linkifyPlainText(_ s: String) -> AttributedString {
        var attr = AttributedString(s)
        guard !s.isEmpty, let detector = urlDetector else { return attr }
        let ns = s as NSString
        let matches = detector.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return attr }

        for match in matches {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let stringRange = Range(match.range, in: s),
                  let attrRange = Range(stringRange, in: attr)
            else { continue }
            attr[attrRange].link = url
            attr[attrRange].foregroundColor = .accentColor
            attr[attrRange].underlineStyle = .single
        }
        return attr
    }

    private enum Dispatch {
        /// Use the given Post with its site's parser. Optional prefetched body
        /// is the GET response captured by `resolveFinalURL` (avoids re-fetch).
        case parser(Post, prefetched: Data?)
        /// Resolved redirect points at a site we don't parse; render an
        /// external-link banner and skip the parser pipeline.
        case external(URL)
    }

    /// Aagag mirror items have URLs of the form `aagag.com/mirror/re?ss=...`
    /// which 301-redirect to the source site. Resolve and decide how to load:
    /// dispatch to a source parser if we recognise the host, else surface a
    /// "외부 사이트로 이동" banner.
    private func resolveDispatchedPost(_ post: Post) async throws -> Dispatch {
        // Mirror detail URLs always live under /mirror/re and carry the item
        // id in the `ss` query — matching the query is less brittle than a
        // bare path suffix if aagag ever renames the redirect endpoint, and
        // still rejects issue detail URLs (which use /issue/?idx=…).
        guard post.site == .aagag,
              let host = post.url.host?.lowercased(),
              host.hasSuffix("aagag.com"),
              post.url.path.hasPrefix("/mirror/re"),
              URLComponents(url: post.url, resolvingAgainstBaseURL: false)?
                  .queryItems?
                  .contains(where: { $0.name == "ss" }) == true
        else { return .parser(post, prefetched: nil) }

        let resolved = await Networking.resolveFinalURL(post.url)
        guard resolved.url != post.url else {
            return .parser(post, prefetched: nil)
        }
        guard let sourceSite = Site.detect(host: resolved.url.host) else {
            return .external(resolved.url)
        }
        let dispatched = Post(
            id: post.id,
            site: sourceSite,
            boardID: post.boardID,
            title: post.title,
            author: post.author,
            date: post.date,
            dateText: post.dateText,
            commentCount: post.commentCount,
            url: resolved.url,
            viewCount: post.viewCount,
            recommendCount: post.recommendCount,
            levelText: post.levelText,
            hasAuthIcon: post.hasAuthIcon
        )
        return .parser(dispatched, prefetched: resolved.prefetchedBody)
    }

    private func load(renderReadyAt: ContinuousClock.Instant) async {
        guard !Task.isCancelled else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // Aagag mirror items are HTTP redirects to a source site; resolve the
            // target URL and dispatch to the source parser when supported.
            let dispatch = try await resolveDispatchedPost(post)
            try Task.checkCancellation()

            switch dispatch {
            case .external(let externalURL):
                let placeholder = PostDetail(
                    post: post,
                    blocks: [.dealLink(externalURL, label: "외부 사이트로 이동: \(externalURL.host ?? externalURL.absoluteString)")],
                    fullDateText: post.dateText,
                    viewCount: post.viewCount,
                    source: nil,
                    comments: []
                )
                await Self.awaitRenderReady(renderReadyAt)
                try Task.checkCancellation()
                // Toggle isLoading in the same runloop as the detail write so
                // `articleContent`'s `if isLoading` branch doesn't keep the
                // spinner up after we already have content.
                isLoading = false
                detail = placeholder
                cache.put(id: post.id, detail: placeholder)
                return

            case .parser(let resolved, let prefetched):
                let parser = try ParserFactory.parser(for: resolved.site)
                let html: String
                if let prefetched {
                    html = Networking.decodeHTML(data: prefetched, encoding: resolved.site.encoding)
                } else {
                    html = try await Networking.fetchHTML(url: resolved.url, encoding: resolved.site.encoding)
                }
                try Task.checkCancellation()

                // Kick comment fetch off in parallel with the detached detail
                // parse. Parse is CPU-bound, comment fetch is network-bound,
                // so overlapping them shaves the comment leg off the critical
                // path for every site that has an override (Coolenjoy, Inven,
                // Ppomppu, Aagag, SLR, Ddanzi). Parsers without a comments URL
                // keep the detail-embedded comments returned by parseDetail.
                //
                // `detailHTML: html` threads the body we already fetched
                // through the protocol, so Ppomppu / SLR / Ddanzi (which
                // used to re-fetch `post.url` just to extract AJAX params
                // or first-page comment DOM) can reuse it and skip the
                // duplicate SwiftSoup parse their perf log sample showed.
                let parsedHTML = html
                let parsedPost = resolved
                let postSite = resolved.site
                async let parsedTask: PostDetail = Task.detached(priority: .userInitiated) {
                    try parser.parseDetail(html: parsedHTML, post: parsedPost)
                }.value
                async let commentsTask: [Comment]? = {
                    guard parser.commentsURL(for: resolved) != nil else { return nil }
                    return try? await parser.fetchAllComments(
                        for: resolved,
                        detailHTML: parsedHTML
                    ) { url in
                        try await Networking.fetchHTML(url: url, encoding: postSite.encoding)
                    }
                }()

                var parsed = try await parsedTask
                try Task.checkCancellation()

                // Gate the first render commit so SwiftUI isn't building an
                // image-heavy subtree during the first animation frames.
                // When parse is slower than the gate this is a no-op.
                await Self.awaitRenderReady(renderReadyAt)
                // Flip isLoading in the same runloop as the detail write so
                // the spinner disappears the moment the article is ready —
                // otherwise `defer` keeps isLoading=true until the comments
                // leg finishes and the two-phase commit collapses back into
                // a single-flash render.
                isLoading = false
                detail = parsed

                if let extras = await commentsTask, !extras.isEmpty {
                    parsed = PostDetail(
                        post: parsed.post,
                        blocks: parsed.blocks,
                        fullDateText: parsed.fullDateText,
                        viewCount: parsed.viewCount,
                        source: parsed.source,
                        comments: extras
                    )
                    detail = parsed
                }
                // Stale-load guard: a popped-and-re-entered view triggers
                // `.task` cancellation, but `await commentsTask` above sits
                // on `try?` so a cancelled parent task silently falls
                // through. Re-check before the cache write so an in-flight
                // old load can't clobber the new view's fresher cache entry.
                try Task.checkCancellation()
                // Cache the final state so re-entering this post (via a
                // fresh tap after the overlay was replaced) skips network +
                // parse entirely. The overlay itself keeps the rendered view
                // alive across back-swipes, so this cache is really just for
                // when the active post gets evicted by a different tap.
                cache.put(id: post.id, detail: parsed)
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sleep until `deadline` if it's in the future; no-op otherwise. Used to
    /// keep state mutations that trigger image-subtree construction out of
    /// the navigation push animation's opening frames.
    private static func awaitRenderReady(_ deadline: ContinuousClock.Instant) async {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return }
        try? await Task.sleep(for: remaining)
    }
}

private struct YouTubeBanner: View {
    let videoID: String

    private var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(videoID)")! }
    private var thumbnailURL: URL { URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg")! }

    var body: some View {
        Link(destination: watchURL) {
            ZStack(alignment: .center) {
                // Branded gradient backstop so layout stays intact when the
                // thumbnail 404s (e.g. very new uploads, age-restricted, deleted).
                LinearGradient(
                    colors: [Color.red.opacity(0.55), Color.black.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                CachedAsyncImage(url: thumbnailURL, maxDimension: 720)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.18)))

                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(Color.red, Color.white)
                    .shadow(radius: 4)

                VStack {
                    HStack {
                        Spacer()
                        Label("YouTube", systemImage: "play.tv")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red, in: Capsule())
                            .padding(8)
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Text("youtu.be/\(videoID)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(8)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("YouTube 영상 \(videoID), 외부 앱에서 열기")
    }
}

private struct DealLinkBanner: View {
    let url: URL
    let label: String

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                Text(label)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color("AppSurface2"), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("딜 링크 \(label), 외부 사이트 열기")
    }
}

private struct SourceBanner: View {
    let source: PostSource

    var body: some View {
        Link(destination: source.url) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                VStack(alignment: .leading, spacing: 2) {
                    Text("출처").font(.caption2).foregroundStyle(.secondary)
                    Text(source.name).font(.callout).fontWeight(.medium)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color("AppSurface2"), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("출처 \(source.name), 외부 사이트 열기")
    }
}

private struct CommentsSection: View {
    let comments: [Comment]
    var tapGate: TapSuppressionGate? = nil
    let onImageTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("댓글")
                    .font(.headline)
                Text("\(comments.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // LazyVStack so off-screen comments don't kick off markdown
            // parses / image fetches / AVPlayer setup at the same time
            // the user is trying to scroll the top of a long thread.
            // Back-drag is a SwiftUI `.offset(x:)` transform rather than
            // a SwiftUI layout op, so contentSize churn as new rows
            // materialise doesn't bleed into the drag position either.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                    CommentRow(comment: comment, tapGate: tapGate, onImageTap: onImageTap)
                    if index < comments.count - 1 {
                        Divider().padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

private struct CommentRow: View {
    let comment: Comment
    var tapGate: TapSuppressionGate? = nil
    let onImageTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let levelURL = comment.levelIconURL {
                    CachedAsyncImage(url: levelURL, maxDimension: 48, showsPlaceholder: false)
                        .frame(width: 16, height: 16)
                }
                Text(comment.author)
                    .font(.caption)
                    .fontWeight(.medium)
                if let iconURL = comment.authIconURL {
                    CachedAsyncImage(url: iconURL, maxDimension: 48, showsPlaceholder: false)
                        .frame(width: 14, height: 14)
                }
                Text(comment.dateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if comment.likeCount > 0 {
                    Label("\(comment.likeCount)", systemImage: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.pink)
                }
            }
            if !comment.content.isEmpty {
                Text(styledContent(comment.content))
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let videoURL = comment.videoURL {
                HStack(spacing: 0) {
                    InlineVideoPlayer(url: videoURL, tapGate: tapGate)
                        .frame(maxWidth: 320, maxHeight: 240)
                    Spacer(minLength: 0)
                }
            } else if let stickerURL = comment.stickerURL {
                HStack(spacing: 0) {
                    CachedAsyncImage(url: stickerURL, maxDimension: 280)
                        .frame(maxWidth: 200, maxHeight: 140)
                        .contentShape(Rectangle())
                        .onTapGesture { onImageTap(stickerURL) }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, comment.isReply ? 20 : 0)
    }

    private func styledContent(_ text: String) -> AttributedString {
        // First parse markdown so any `[label](<url>)` anchors that the
        // parser preserved become real `.link` spans. Falls back to plain
        // text if the parser rejects the input. Then apply the @mention
        // coloring on top of whatever the markdown parser produced.
        //
        // Escape `~` before parsing so range notations like "1995~1996"
        // don't trigger the markdown parser's strikethrough handling
        // (which consumed the tilde and rendered the trailing digits with
        // a line through them — Aagag comments use `~` for ranges/aliases
        // far more often than they use intentional strikethrough).
        let escaped = text.replacingOccurrences(of: "~", with: "\\~")
        var base: AttributedString
        if let attributed = try? AttributedString(
            markdown: escaped,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            base = attributed
        } else {
            base = AttributedString(text)
        }

        // Apply consistent link styling so embedded URLs are visibly tappable.
        for run in base.runs {
            if run.link != nil {
                base[run.range].foregroundColor = .accentColor
                base[run.range].underlineStyle = .single
            }
        }

        // Highlight `@nickname` mentions. Walks the plain-string view of the
        // attributed result so we don't have to re-parse the original input.
        let plain = String(base.characters)
        var mentionRanges: [Range<String.Index>] = []
        var i = plain.startIndex
        while i < plain.endIndex {
            guard plain[i] == "@" else {
                i = plain.index(after: i)
                continue
            }
            var end = plain.index(after: i)
            while end < plain.endIndex,
                  plain[end].isLetter || plain[end].isNumber || plain[end] == "_" {
                end = plain.index(after: end)
            }
            if end > plain.index(after: i) {
                mentionRanges.append(i..<end)
            }
            i = end
        }
        for range in mentionRanges {
            if let attrRange = Range(range, in: base) {
                base[attrRange].foregroundColor = .blue
                base[attrRange].font = .subheadline.bold()
            }
        }
        return base
    }
}

/// Bridges to UILabel so the title can use `.lineBreakStrategy = .standard`,
/// which SwiftUI `Text` doesn't expose. SwiftUI's default for Korean text
/// keeps mixed-script tokens like "(gpt-image-2)" glued to the preceding
/// Hangul word, leaving the previous line short. The standard strategy
/// allows breaking between Hangul and adjacent punctuation/Latin tokens.
struct WrappingTitleLabel: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.lineBreakStrategy = .standard
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        if label.text != text {
            label.text = text
            label.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UILabel,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? 0
        guard width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(fitted.height))
    }
}

/// When the detail view is visible, iOS's status-bar-tap scroll-to-top
/// quietly stops working because both the list's backing `UIScrollView`
/// (from `List`) and the detail's `ScrollView` sit in the window with
/// `scrollsToTop = true`. iOS only fires the behaviour when exactly one
/// candidate is eligible; ties resolve to none.
///
/// Drop this zero-sized view inside the detail's `ScrollView`. When
/// `isActive` is true it walks up to the enclosing scroll view (the
/// detail's), pins that one as the claimant, and disables
/// `scrollsToTop` on every *other* scroll view in the same window.
/// When `isActive` flips to false it restores each original setting.
///
/// `isActive` must be driven by the caller, not by UIKit lifecycle —
/// the detail overlay is keep-alive (`activePost` stays set after
/// `hideDetail`, so `willMove(toWindow: nil)` would never fire on a
/// plain dismissal). Without an explicit signal from the `detailOffset`
/// state the list's `scrollsToTop` would stay `false` for the rest of
/// the session after the first dismissal, silently breaking the
/// list's own status-bar-tap behaviour.
struct StatusBarTapScrollClaimer: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> ClaimerView {
        let v = ClaimerView()
        v.isActive = isActive
        return v
    }

    func updateUIView(_ view: ClaimerView, context: Context) {
        // SwiftUI fires `updateUIView` on every parent re-eval. Scanning
        // the window tree on each call is wasteful and — worse — breaks
        // transient scroll views (e.g. the Safari reader sheet) whose
        // `scrollsToTop` we shouldn't be disabling at all. Only re-apply
        // when the caller actually flipped `isActive`; mount-time apply
        // still runs from `didMoveToWindow`.
        guard view.isActive != isActive else { return }
        view.isActive = isActive
        view.apply()
    }

    final class ClaimerView: UIView {
        private struct Managed {
            weak var scrollView: UIScrollView?
            let originalScrollsToTop: Bool
        }
        private var managed: [Managed] = []
        var isActive: Bool = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            guard isActive, let window else {
                restoreManaged()
                return
            }
            // Our enclosing scroll view is the detail view's ScrollView.
            // Walk the superview chain to find it.
            var current: UIView? = self
            var enclosing: UIScrollView?
            while let c = current {
                if let sv = c as? UIScrollView {
                    enclosing = sv
                    break
                }
                current = c.superview
            }
            enclosing?.scrollsToTop = true

            // Find every *other* UIScrollView in the window. Disable
            // scrollsToTop on them and remember the prior value so we can
            // restore when `isActive` flips to false.
            //
            // Scope to scroll views whose owning view controller shares a
            // top-level parent with ours. That's the rootVC's subtree,
            // which contains the list behind our overlay (both are child
            // VCs of the app's root hosting controller). Presented sheets
            // and full-screen covers (SafariView, ImageViewer) live under
            // a different top-level chain — their scroll views are THEIRS
            // to manage, not ours.
            let ourTopVC = Self.topLevelViewController(of: self)
            var all: [UIScrollView] = []
            Self.collectScrollViews(in: window, into: &all)
            let alreadyManaged = Set(managed.compactMap { $0.scrollView.map(ObjectIdentifier.init) })
            for sv in all {
                if sv === enclosing { continue }
                if alreadyManaged.contains(ObjectIdentifier(sv)) { continue }
                let theirTopVC = Self.topLevelViewController(of: sv)
                if let ourTopVC, let theirTopVC, ourTopVC !== theirTopVC {
                    continue
                }
                managed.append(Managed(
                    scrollView: sv,
                    originalScrollsToTop: sv.scrollsToTop
                ))
                sv.scrollsToTop = false
            }
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil {
                restoreManaged()
            }
            super.willMove(toWindow: newWindow)
        }

        private func restoreManaged() {
            for m in managed {
                m.scrollView?.scrollsToTop = m.originalScrollsToTop
            }
            managed.removeAll()
        }

        private static func collectScrollViews(in root: UIView, into acc: inout [UIScrollView]) {
            if let sv = root as? UIScrollView {
                acc.append(sv)
            }
            for sub in root.subviews {
                collectScrollViews(in: sub, into: &acc)
            }
        }

        /// Walks the responder chain to find the view's owning
        /// UIViewController, then follows `.parent` to the top. Presented
        /// (modal) view controllers have no `.parent`, so `topLevel` on a
        /// sheet's VC returns the sheet's own root VC — different object
        /// from the app's rootVC, which is how we tell them apart.
        private static func topLevelViewController(of view: UIView) -> UIViewController? {
            var responder: UIResponder? = view
            var owner: UIViewController?
            while let r = responder {
                if let vc = r as? UIViewController {
                    owner = vc
                    break
                }
                responder = r.next
            }
            var current = owner
            while let c = current, let p = c.parent {
                current = p
            }
            return current
        }
    }
}
