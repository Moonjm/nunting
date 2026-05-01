import Foundation
import Observation

/// Owns the network + parse + state-machine for `PostDetailView`.
///
/// Pulled out of the view so:
///  - Tests can drive the cache-hit / cold / aagag-redirect / error
///    branches without spinning up SwiftUI.
///  - The view stays close to "render this state" with `.task(id:)` as
///    the only lifecycle hook.
///  - Future loader features (offline mode, prefetch, retry) only touch
///    this file.
///
/// Mirrors the prior in-view implementation byte-for-byte on observable
/// state and timing: cache hit short-circuits with no render gate; cold
/// path runs `resolveDispatchedPost` (aagag mirror redirect resolution)
/// then either yields an external-link placeholder or dispatches to the
/// source-site parser; the parse runs detached, comments fetch in
/// parallel, and `isLoading` flips to false in the same runloop as the
/// detail commit so the spinner doesn't outlive the article (otherwise
/// the trailing comment-fetch leg would keep it up and the two-phase
/// commit would look like a single flash).
@Observable
@MainActor
final class PostDetailLoader {
    /// Routes every HTML fetch through one seam so test fakes can intercept
    /// detail + comment traffic uniformly. Production wires both legs to
    /// `Networking.fetchHTML(url:encoding:)`.
    typealias Fetcher = @Sendable (URL, String.Encoding) async throws -> String

    /// Aagag mirror items 301-redirect through `aagag.com/mirror/re?ss=…`
    /// to a source-site URL. Routing the resolution through a seam lets
    /// tests inject canned redirects without an HTTP stack.
    typealias Resolver = @Sendable (URL) async -> Networking.ResolvedRedirect

    // MARK: - Observed state

    private(set) var detail: PostDetail?
    /// Starts true so the first render before `.task` fires shows the
    /// spinner without a 1-frame gap. Mirrors the prior
    /// `@State private var isLoading = true` default in the view.
    private(set) var isLoading: Bool = true
    private(set) var errorMessage: String?

    // MARK: - Private state

    private let fetcher: Fetcher
    private let resolver: Resolver

    init(
        fetcher: @escaping Fetcher = { url, encoding in
            try await Networking.fetchHTML(url: url, encoding: encoding)
        },
        resolver: @escaping Resolver = { url in
            await Networking.resolveFinalURL(url)
        }
    ) {
        self.fetcher = fetcher
        self.resolver = resolver
    }

    // MARK: - Public API

    /// Drive from `PostDetailView.task(id: post.id)`. Cache hit restores
    /// instantly with no render gate (the image subtree was already
    /// materialised this session, so the navigation push isn't at risk).
    /// Cold path resolves aagag mirrors, fetches + parses, runs comment
    /// fetch in parallel, and gates the first commit on `renderReadyAt`
    /// to keep image-heavy state mutations out of the push animation's
    /// opening frames.
    func load(
        post: Post,
        cache: PostDetailCache,
        renderReadyAt: ContinuousClock.Instant
    ) async {
        if let entry = cache.get(id: post.id) {
            detail = entry.detail
            isLoading = false
            return
        }
        guard !Task.isCancelled else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
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
                    html = try await fetcher(resolved.url, resolved.site.encoding)
                }
                try Task.checkCancellation()

                // Kick comment fetch off in parallel with the detached detail
                // parse. Parse is CPU-bound, comment fetch is network-bound,
                // so overlapping them shaves the comment leg off the critical
                // path for every site that has a separate comments URL.
                //
                // `detailHTML: html` threads the body we already fetched
                // through the protocol, so Ppomppu / SLR / Ddanzi (which
                // used to re-fetch `post.url` just to extract AJAX params
                // or first-page comment DOM) can reuse it.
                let parsedHTML = html
                let parsedPost = resolved
                let postSite = resolved.site
                let fetcher = self.fetcher
                async let parsedTask: PostDetail = Task.detached(priority: .userInitiated) {
                    try parser.parseDetail(html: parsedHTML, post: parsedPost)
                }.value
                async let commentsTask: [Comment]? = {
                    guard parser.commentsURL(for: resolved) != nil else { return nil }
                    return try? await parser.fetchAllComments(
                        for: resolved,
                        detailHTML: parsedHTML
                    ) { url in
                        try await fetcher(url, postSite.encoding)
                    }
                }()

                var parsed = try await parsedTask
                try Task.checkCancellation()

                // Gate the first render commit so SwiftUI isn't building an
                // image-heavy subtree during the first animation frames.
                // When parse is slower than the gate this is a no-op.
                await Self.awaitRenderReady(renderReadyAt)
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
                // old load can't clobber a newer cache entry.
                try Task.checkCancellation()
                cache.put(id: post.id, detail: parsed)
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private

    private enum Dispatch {
        /// Use the given Post with its site's parser. Optional prefetched
        /// body is the GET response captured by `resolveFinalURL`
        /// (avoids re-fetch).
        case parser(Post, prefetched: Data?)
        /// Resolved redirect points at a site we don't parse; render an
        /// external-link banner and skip the parser pipeline.
        case external(URL)
    }

    /// Aagag mirror items have URLs of the form `aagag.com/mirror/re?ss=...`
    /// which 301-redirect to the source site. Resolve and decide how to
    /// load: dispatch to a source parser if we recognise the host, else
    /// surface a "외부 사이트로 이동" banner.
    private func resolveDispatchedPost(_ post: Post) async throws -> Dispatch {
        // Mirror detail URLs always live under /mirror/re and carry the
        // item id in the `ss` query — matching the query is less brittle
        // than a bare path suffix if aagag ever renames the redirect
        // endpoint, and still rejects issue detail URLs (which use
        // /issue/?idx=…).
        guard post.site == .aagag,
              let host = post.url.host?.lowercased(),
              host.hasSuffix("aagag.com"),
              post.url.path.hasPrefix("/mirror/re"),
              URLComponents(url: post.url, resolvingAgainstBaseURL: false)?
                  .queryItems?
                  .contains(where: { $0.name == "ss" }) == true
        else { return .parser(post, prefetched: nil) }

        let resolved = await resolver(post.url)
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

    /// Sleep until `deadline` if it's in the future; no-op otherwise.
    /// Keeps state mutations that trigger image-subtree construction out
    /// of the navigation push animation's opening frames.
    private nonisolated static func awaitRenderReady(_ deadline: ContinuousClock.Instant) async {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return }
        try? await Task.sleep(for: remaining)
    }
}
