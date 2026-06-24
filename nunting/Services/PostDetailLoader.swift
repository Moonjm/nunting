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

    /// `DetailPrefetcher` 가 미리 받아 둔 detail HTML 의 1회 소비 시임.
    /// post.id 를 받아 신선한 warm 본이 있으면 반환 — fetch 를 통째로
    /// 건너뛴다. 테스트는 canned HTML 주입.
    typealias WarmHTML = @MainActor (String) -> String?

    // MARK: - Observed state

    private(set) var detail: PostDetail?
    /// Starts true so the first render before `.task` fires shows the
    /// spinner without a 1-frame gap. Mirrors the prior
    /// `@State private var isLoading = true` default in the view.
    private(set) var isLoading: Bool = true
    private(set) var errorMessage: String?
    /// 본문은 받았지만 댓글 leg 만 실패한 상태. "원래 댓글 없는 글"과
    /// "로드 실패"를 뷰에서 구분해 재시도 배너를 띄우기 위한 플래그 —
    /// 본문 에러(`errorMessage`)로 승격하지 않는다.
    private(set) var commentsFailed: Bool = false
    /// `retryComments` 진행 중 — 재시도 버튼의 스피너 표시용.
    private(set) var isRetryingComments: Bool = false

    // MARK: - Private state

    private let fetcher: Fetcher
    private let resolver: Resolver
    private let warmHTML: WarmHTML
    /// 댓글 재시도에 필요한 입력(디스패치 후 resolved Post + 이미 받아 둔
    /// detail HTML). 댓글 실패 시에만 채워진다.
    private var commentRetryContext: (post: Post, detailHTML: String)?
    /// `load()` 진입마다 증가. in-flight `retryComments` 가 fetch 후 자신이
    /// 본 세대와 비교해, 그 사이 새 로드(pull-to-refresh 등)가 커밋한 더
    /// 신선한 본을 stale 본 + 댓글로 되돌리는 레이스를 차단한다.
    private var loadGeneration = 0

    init(
        fetcher: @escaping Fetcher = { url, encoding in
            try await Networking.fetchHTML(url: url, encoding: encoding)
        },
        resolver: @escaping Resolver = { url in
            await Networking.resolveFinalURL(url)
        },
        warmHTML: @escaping WarmHTML = { id in
            DetailPrefetcher.shared.consume(id: id)
        }
    ) {
        self.fetcher = fetcher
        self.resolver = resolver
        self.warmHTML = warmHTML
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
        renderReadyAt: ContinuousClock.Instant,
        forceFresh: Bool = false
    ) async {
        loadGeneration += 1
        // Pull-to-refresh path: drop the in-memory cache entry so the
        // load below goes back to the network. URLSession may still serve
        // a cached HTTP response; that's a separate layer to revisit if
        // refresh stops feeling fresh in the wild.
        if forceFresh {
            cache.remove(id: post.id)
        } else if let entry = cache.get(id: post.id) {
            detail = entry.detail
            isLoading = false
            // 댓글 실패 본은 캐시에 안 넣지만, 다른 화면의 loader 가 같은
            // 글을 성공적으로 캐시했을 수 있다 — 히트 복원 시 배너는 내린다.
            commentsFailed = false
            commentRetryContext = nil
            return
        }
        guard !Task.isCancelled else { return }
        isLoading = true
        errorMessage = nil
        commentsFailed = false
        commentRetryContext = nil
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
                // dealLink 배너뿐이라 needsRenderGate 는 항상 false — 게이트
                // 없이 즉시 commit (parser 경로의 텍스트 전용 면제와 동일 규칙).
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
                    // The prefetched body came from `resolveFinalURL`'s
                    // GET — that path never goes through `fetchHTML`,
                    // so we have to run the bot-check guard here too.
                    // Aagag mirror items are the principal entry point
                    // for this branch, and Aagag is also the only site
                    // currently registered with a CAPTCHA detector — so
                    // a stale-cookie user hitting an Aagag mirror with
                    // an interstitial response would otherwise feed
                    // that interstitial straight to `AagagParser`.
                    let decoded = Networking.decodeHTML(data: prefetched, encoding: resolved.site.encoding)
                    let resolvedURL = resolved.url
                    let resolvedEncoding = resolved.site.encoding
                    let captureFetcher = self.fetcher
                    html = try await Networking.applyBotCheckGuard(url: resolvedURL, body: decoded) {
                        try await captureFetcher(resolvedURL, resolvedEncoding)
                    }
                } else if !forceFresh, let warm = warmHTML(post.id) {
                    // 목록에서 미리 받아 둔 본 — fetch 생략 (RTT 제거).
                    // warm 본은 `Networking.fetchHTML` 경유로 받은 것이라
                    // 봇체크 가드를 이미 통과했다. pull-to-refresh 는 신선도
                    // 보장을 위해 무시.
                    html = warm
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
                    // autoreleasepool: 파싱은 detached(협력 풀) 스레드에서 도는데,
                    // 그 스레드엔 런루프가 없어 ObjC autorelease 풀이 영영 배수되지
                    // 않는다. SwiftSoup 은 NSCopying/NSString/NSRegularExpression 등
                    // ObjC 브릿지로 autorelease 임시객체를 쏟아내고, 그게 안 빠지면
                    // 파싱이 끝나 Document(값 아닌 노드 트리)가 스코프를 벗어나도
                    // 그 노드/속성 그래프가 풀에 붙들려 해제가 무한 지연된다 —
                    // 세션 내내 SwiftSoup.Element/TextNode/Attributes 가 단조 누적
                    // (실측: 90초에 14만 노드, footprint 2.8GB ratchet 의 주범).
                    // 풀로 감싸면 parseDetail 반환 즉시 임시객체가 배수돼 Document
                    // 가 그 자리에서 해제된다. parseDetail 은 값 타입(PostDetail)만
                    // 반환하므로 배수로 사라지는 것 중 이후 필요한 건 없다.
                    try autoreleasepool {
                        try parser.parseDetail(html: parsedHTML, post: parsedPost)
                    }
                }.value
                // Result 로 받아 실패를 분류한다 — `try?` 는 "댓글 없는 글"과
                // "로드 실패"를 구분 불가능하게 뭉갰고, 취소 전파까지 삼켰다.
                async let commentsTask: Result<[PostComment], Error>? = {
                    guard parser.commentsURL(for: resolved) != nil else { return nil }
                    do {
                        return .success(try await parser.fetchAllComments(
                            for: resolved,
                            detailHTML: parsedHTML
                        ) { url in
                            try await fetcher(url, postSite.encoding)
                        })
                    } catch {
                        return .failure(error)
                    }
                }()

                var parsed = try await parsedTask
                try Task.checkCancellation()

                // Gate the first render commit so SwiftUI isn't building an
                // image-heavy subtree during the first animation frames.
                // When parse is slower than the gate this is a no-op.
                // 보호할 미디어가 없는 텍스트 전용 글(본문·댓글 모두)은 게이트
                // 를 건너뛰고 즉시 commit — 빠른 회선에서 고정 400ms 를 매번
                // 지불하지 않게.
                if Self.needsRenderGate(parsed) {
                    await Self.awaitRenderReady(renderReadyAt)
                }
                isLoading = false
                detail = parsed

                switch await commentsTask {
                case .success(let extras):
                    if !extras.isEmpty {
                        parsed = parsed.withComments(extras)
                        detail = parsed
                    }
                case .failure(let error):
                    // 취소 계열은 부모 task 취소가 댓글 leg 로 전파된 것 —
                    // 실패 배너 대상이 아니고, 아래 checkCancellation 이 끊는다.
                    // `!Task.isCancelled` 는 "댓글 leg 가 실 에러로 먼저 끝난
                    // 뒤 부모가 취소된" 죽어가는 로드가 플래그/컨텍스트를
                    // 남기지 않게 — 캐시 쓰기 가드와 같은 규율.
                    if !Task.isCancelled, !Self.isCancellation(error) {
                        commentsFailed = true
                        commentRetryContext = (resolved, parsedHTML)
                    }
                case nil:
                    break
                }
                // Stale-load guard: a popped-and-re-entered view triggers
                // `.task` cancellation, but the comment leg above catches
                // its own errors so a cancelled parent task silently falls
                // through. Re-check before the cache write so an in-flight
                // old load can't clobber a newer cache entry.
                try Task.checkCancellation()
                // 댓글이 빠진 본은 캐시에 남기지 않는다 — 캐시 히트는 실패
                // 플래그 없이 복원되므로, 남기면 재진입마다 "댓글 없는 글"로
                // 보인다. 재진입 풀 리로드가 재시도 기회를 겸한다.
                if !commentsFailed {
                    cache.put(id: post.id, detail: parsed)
                }
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 댓글 leg 만 다시 시도 — 본문 refetch/reparse 없이 실패 시점에 저장해
    /// 둔 (resolved post, detail HTML) 로 `fetchAllComments` 만 재실행한다.
    /// 성공하면 배너를 내리고 완전해진 본을 그제서야 캐시에 넣는다.
    func retryComments(cache: PostDetailCache) async {
        guard commentsFailed, !isRetryingComments,
              let context = commentRetryContext,
              let current = detail,
              let parser = try? ParserFactory.parser(for: context.post.site)
        else { return }
        isRetryingComments = true
        defer { isRetryingComments = false }

        let fetcher = self.fetcher
        let encoding = context.post.site.encoding
        let generation = loadGeneration
        do {
            let extras = try await parser.fetchAllComments(
                for: context.post,
                detailHTML: context.detailHTML
            ) { url in
                try await fetcher(url, encoding)
            }
            // fetch 사이 새 로드가 더 신선한 본을 커밋했으면(세대 변화) 이
            // 결과는 stale — `current` 로 되돌리지 말고 조용히 버린다.
            guard generation == loadGeneration else { return }
            commentsFailed = false
            commentRetryContext = nil
            var updated = current
            if !extras.isEmpty {
                updated = current.withComments(extras)
                detail = updated
            }
            cache.put(id: context.post.id, detail: updated)
        } catch {
            // 취소면 조용히 끝, 그 외 재실패면 배너 유지 — 둘 다 상태 변화 없음.
            return
        }
    }

    // MARK: - Private

    /// 취소 전파로 생긴 에러인가 — 실패 배너(`commentsFailed`) 대상에서 제외.
    private nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

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
              Site.host(post.url.host, matches: "aagag.com"),
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

    /// 첫 commit 이 렌더 게이트를 기다려야 하는가 — 푸시 애니메이션 프레임을
    /// 위협하는 "무거운 서브트리"가 있는 경우만. 본문의 image/video/embed
    /// (embed 배너도 썸네일 이미지를 로드) 또는 댓글의 sticker/video 가
    /// 해당한다. 댓글까지 보는 이유: 본문이 짧은 텍스트면 commit 시점에
    /// 댓글 첫 행들이 이미 화면 안이라 LazyVStack 이 즉시 실현된다.
    /// richText/dealLink/텍스트 댓글은 싸므로 게이트 불필요.
    nonisolated static func needsRenderGate(_ detail: PostDetail) -> Bool {
        let blocksHaveMedia = detail.blocks.contains { block in
            switch block.kind {
            case .image, .video, .embed: true
            case .richText, .dealLink: false
            }
        }
        if blocksHaveMedia { return true }
        return detail.comments.contains { $0.stickerURL != nil || $0.videoURL != nil }
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
