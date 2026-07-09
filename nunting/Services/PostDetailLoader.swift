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

    /// 봇체크 챌린지 시트를 띄우는 side-effect 시임. 프로덕션은
    /// `BotCheckCoordinator.shared.challenge(url:)` 로 연결되고, 테스트는
    /// no-op 스파이를 주입해 실제 시트/대기 없이 안전망 분기를 검증한다.
    /// (`Networking.recoverFromBotCheckStatus` 의 challenger 와 같은 계약.)
    typealias Challenger = @Sendable (URL) async -> Void

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
    private let challenger: Challenger
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
        },
        challenger: @escaping Challenger = { url in
            await BotCheckCoordinator.shared.challenge(url: url)
        }
    ) {
        self.fetcher = fetcher
        self.resolver = resolver
        self.warmHTML = warmHTML
        self.challenger = challenger
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
                // var: 아래 애객 인터스티셜 안전망에서 재요청 본으로 교체될 수 있다.
                var html: String
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
                // 애객 미러 인터스티셜 2차 안전망. 1차 detector(fetchHTML /
                // applyBotCheckGuard 내부의 `looksLikeBotCheck`)는 마커 substring
                // 에 의존해, 챌린지 페이지 문구가 바뀌면 인터스티셜을 놓쳐
                // AagagParser 로 흘려보내고 사용자는 "불러오기 실패"만 본다.
                // 미러 본문이 비정상적으로 짧으면(정상 미러 상세는 수십 KB) 마커와
                // 무관하게 봇체크로 보고 시트를 띄운 뒤 한 번 재요청한다.
                //
                // 범위를 `/mirror/re` 로 한정: 리다이렉트가 풀린 경우 `resolved.site`
                // 는 소스 사이트라 제외되고, 미러 항목이 리다이렉트에 실패해(=303
                // 챌린지) 애객 호스트가 직접 짧은 응답을 준 경우만 잡는다. 네이티브
                // `/issue/` 페이지나 정상 미러 본문은 대상이 아니다.
                if resolved.site == .aagag,
                   resolved.url.path.hasPrefix("/mirror/re"),
                   html.count < 3_000 {
                    await challenger(resolved.url)
                    try Task.checkCancellation()
                    html = try await fetcher(resolved.url, resolved.site.encoding)
                    // 재요청 결과도 같은 조건으로 재검증. 사용자가 시트를 닫았거나
                    // 쿠키 처리가 실패하면 두 번째 응답도 짧은 인터스티셜일 수 있다 —
                    // 그걸 AagagParser 로 흘리면 "불러오기 실패"로 뭉개지므로,
                    // 통일된 캡챠 에러로 surface 한다(applyBotCheckGuard 의
                    // retry-여전히-막힘 → .captchaChallenge 와 같은 계약; 시트 루프
                    // 없이 outer catch 가 localized 메시지를 띄운다).
                    if html.count < 3_000 {
                        throw NetworkError.captchaChallenge(resolved.url)
                    }
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
                //
                // 이 async let "클로저" 형태는 실행 위치도 지탱한다: 클로저가
                // 비격리 자식 태스크라(컴파일 프로브로 확인 — 내부에서 MainActor
                // 상태 접근이 에러), nonsending 인 `fetchAllComments` 의 댓글
                // 파싱이 협력 풀에서 돈다. @MainActor 메서드에서 직접 await 로
                // 바꾸면 파싱이 통째로 메인으로 온다(retryComments 가 실제로
                // 그랬다) — 리팩터링 시 형태 유지 필수.
                async let commentsTask: Result<[PostComment], Error>? = {
                    guard parser.commentsURL(for: resolved) != nil else { return nil }
                    do {
                        return .success(try await parser.fetchAllComments(
                            for: resolved,
                            detailHTML: parsedHTML
                        ) { url in
                            // 파서가 URL 별 charset 을 지정 — ppomppu 댓글 JSON 은
                            // UTF-8, 페이지는 CP949 라 사이트 단일 인코딩으로는
                            // 한글이 깨진다. `responseEncoding` 이 URL 로 판별.
                            try await fetcher(url, parser.responseEncoding(for: url))
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
        let generation = loadGeneration
        do {
            // async let 자식 태스크로 감싸 파싱을 메인액터 밖으로 보낸다.
            // approachable concurrency(nonsending) 에선 nonisolated async 인
            // `fetchAllComments` 가 호출자 executor 에서 돌므로, @MainActor
            // 메서드에서 직접 await 하면 댓글 SwiftSoup/JSON 파싱이 통째로
            // 메인에서 돈다(수백 댓글 = 수 초 hang). load() 의 댓글 leg 는
            // 이미 async let 클로저(비격리 자식)라 협력 풀에서 돌고 있고,
            // 여기만 직접 호출이라 빠져 있었다. 자식 태스크라 취소 전파는
            // 그대로 유지된다(Task.detached 와 달리).
            async let extrasTask: [PostComment] = {
                try await parser.fetchAllComments(
                    for: context.post,
                    detailHTML: context.detailHTML
                ) { url in
                    try await fetcher(url, parser.responseEncoding(for: url))
                }
            }()
            let extras = try await extrasTask
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
        // Aagag list rows may already carry a direct source-site URL —
        // `AagagParser.directSourceURL` rebuilds the source's canonical URL
        // from the row's `ss`, so we skip the `/mirror/re?ss=…` redirect (and
        // Aagag's Cloudflare/bot-check gate). Such a post keeps `site == .aagag`
        // (list styling + prefetch skip stay put), but its URL host is the
        // source site — dispatch straight to that parser with no round-trip.
        // Native issue rows keep the aagag.com host and fall through below.
        if post.site == .aagag,
           let host = post.url.host,
           !Site.host(host, matches: "aagag.com"),
           let sourceSite = Site.detect(host: host) {
            return .parser(dispatchedPost(post, site: sourceSite, url: post.url),
                           prefetched: nil)
        }

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
        return .parser(dispatchedPost(post, site: sourceSite, url: resolved.url),
                       prefetched: resolved.prefetchedBody)
    }

    /// Rebuild `post` under a source site + resolved URL so dispatch runs the
    /// source parser with the source site's encoding. `id` / `boardID` stay
    /// put so read-state and the owning Aagag board are preserved.
    private func dispatchedPost(_ post: Post, site: Site, url: URL) -> Post {
        Post(
            id: post.id,
            site: site,
            boardID: post.boardID,
            title: post.title,
            author: post.author,
            date: post.date,
            dateText: post.dateText,
            commentCount: post.commentCount,
            url: url,
            viewCount: post.viewCount,
            recommendCount: post.recommendCount,
            levelText: post.levelText,
            hasAuthIcon: post.hasAuthIcon
        )
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
