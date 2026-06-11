import XCTest
@testable import nunting
/// State-machine + side-effect tests for `PostDetailLoader`.
///
/// Mirrors `BoardListLoaderTests`: stub fetcher / resolver via the
/// loader's seam typealiases, then drive `load(post:cache:renderReadyAt:)`
/// directly. The production parsers run unmodified so we exercise the
/// real BobaeParser / AagagParser dispatch instead of a parsed-result
/// fake.
///
/// Bobaedream's "삭제된 글" sentinel HTML (`<script>alert('삭제된 글 ...
/// ');history.back();</script>`) is BobaeParser's pre-DOM short-circuit
/// — it produces a deterministic `PostDetail` with a single placeholder
/// text block without needing a full DOM fixture, which keeps the cold-
/// load tests focused on loader plumbing rather than parser markup.
///
/// `renderReadyAt: .now` skips the navigation-push render gate (the gate
/// only sleeps when the deadline is in the future), so tests don't pay
/// the 400 ms wall-clock the production view does.
@MainActor
final class PostDetailLoaderTests: XCTestCase {

    // BobaeParser's pre-DOM sentinel: returns a placeholder PostDetail
    // with `.text("삭제되거나 이동된 게시물입니다.")` blocks, no fetch
    // through SwiftSoup. Reused across happy-path / dispatch tests.
    private let bobaeDeletedHTML = """
    <html><body>
    <script>alert('삭제된 글 입니다.'); history.back();</script>
    </body></html>
    """

    private func bobaePost(id: String = "bobae-1") -> Post {
        Post(
            id: id,
            site: .bobae,
            boardID: "freeb",
            title: "테스트",
            author: "작성자",
            date: nil,
            dateText: "방금",
            commentCount: 0,
            url: URL(string: "https://m.bobaedream.co.kr/board/bbs_view/freeb/\(id)")!
        )
    }

    private func aagagMirrorPost(id: String = "aagag-1") -> Post {
        Post(
            id: id,
            site: .aagag,
            boardID: "mirror",
            title: "미러",
            author: "aagag",
            date: nil,
            dateText: "방금",
            commentCount: 0,
            url: URL(string: "https://aagag.com/mirror/re?ss=\(id)")!
        )
    }

    private func now() -> ContinuousClock.Instant { ContinuousClock.now }

    // MARK: - Cache short-circuit

    func testCacheHitRestoresInstantlyAndSkipsFetch() async {
        let fetchCount = TestCounter()
        let loader = PostDetailLoader(
            fetcher: { _, _ in
                fetchCount.increment()
                return ""
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = bobaePost()
        let cached = PostDetail(
            post: post,
            blocks: [.text("warm")],
            fullDateText: "캐시",
            viewCount: 99,
            source: nil,
            comments: []
        )
        cache.put(id: post.id, detail: cached)

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(fetchCount.value, 0,
                       "캐시 히트 시 fetcher 호출 안 함")
        XCTAssertEqual(loader.detail?.fullDateText, "캐시")
        XCTAssertFalse(loader.isLoading)
        XCTAssertNil(loader.errorMessage)
    }

    // MARK: - Cold path

    func testColdLoadPopulatesDetailAndCaches() async {
        let fetchCount = TestCounter()
        let loader = PostDetailLoader(
            fetcher: { [bobaeDeletedHTML] _, _ in
                fetchCount.increment()
                return bobaeDeletedHTML
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = bobaePost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertNotNil(loader.detail)
        XCTAssertFalse(loader.isLoading)
        XCTAssertNil(loader.errorMessage)
        XCTAssertNotNil(cache.get(id: post.id),
                        "성공 시 cache.put 으로 결과 저장")
    }

    func testFetcherErrorSurfacesErrorMessageAndSkipsCache() async {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "fetch failed" }
        }
        let loader = PostDetailLoader(
            fetcher: { _, _ in throw StubError() },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = bobaePost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(loader.errorMessage, "fetch failed")
        XCTAssertNil(loader.detail)
        XCTAssertFalse(loader.isLoading)
        XCTAssertNil(cache.get(id: post.id),
                     "에러 시 cache 미오염")
    }

    // MARK: - Aagag dispatch

    func testAagagMirrorToUnknownHostYieldsExternalPlaceholder() async {
        // Resolver redirects to a site we don't recognise → loader builds
        // a "외부 사이트로 이동" placeholder, no fetcher / parser call.
        let fetchCount = TestCounter()
        let loader = PostDetailLoader(
            fetcher: { _, _ in
                fetchCount.increment()
                return ""
            },
            resolver: { _ in
                Networking.ResolvedRedirect(url: URL(string: "https://example.com/article/42")!,
                      prefetchedBody: nil)
            }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = aagagMirrorPost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(fetchCount.value, 0,
                       "외부 host 로 dispatch → fetcher 통과 안 함")
        guard let detail = loader.detail else {
            XCTFail("external placeholder detail 누락"); return
        }
        XCTAssertEqual(detail.blocks.count, 1)
        if case .dealLink(let url, let label) = detail.blocks[0].kind {
            XCTAssertEqual(url.host, "example.com")
            XCTAssertTrue(label.hasPrefix("외부 사이트로 이동"))
        } else {
            XCTFail("blocks[0] 가 dealLink 아님: \(detail.blocks[0].kind)")
        }
        XCTAssertNotNil(cache.get(id: post.id),
                        "external placeholder 도 캐시 저장")
    }

    func testAagagMirrorToKnownSourceDispatchesToSourceParser() async {
        // Resolver redirects aagag mirror → bobaedream → BobaeParser
        // sentinel placeholder. Fetcher should NOT be called because the
        // resolved redirect carries `prefetchedBody`.
        let fetchCount = TestCounter()
        let prefetched = bobaeDeletedHTML.data(using: .utf8)!
        let loader = PostDetailLoader(
            fetcher: { _, _ in
                fetchCount.increment()
                return ""
            },
            resolver: { _ in
                Networking.ResolvedRedirect(url: URL(string: "https://m.bobaedream.co.kr/board/bbs_view/freeb/42")!,
                      prefetchedBody: prefetched)
            }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = aagagMirrorPost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(fetchCount.value, 0,
                       "prefetched body 가 있으면 fetcher 재호출 안 함")
        XCTAssertNotNil(loader.detail)
        XCTAssertFalse(loader.isLoading)
    }

    func testAagagMirrorWithoutSsQueryFallsThroughToAagagParser() async {
        // post.url 이 /mirror/re 패턴이지만 ss 쿼리 없음 → resolver 우회,
        // 원본 post (aagag) 로 parser 디스패치. AagagParser 가 입력을
        // 받아 throw 하면 errorMessage, 아니면 detail. 여기선 빈 HTML →
        // 일반적으로 AagagParser 가 structureChanged 류를 throw 하므로
        // errorMessage 가 채워지면 충분.
        let resolverCalled = TestCounter()
        let loader = PostDetailLoader(
            fetcher: { _, _ in "<html></html>" },
            resolver: { url in
                resolverCalled.increment()
                return Networking.ResolvedRedirect(url: url, prefetchedBody: nil)
            }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = Post(
            id: "x",
            site: .aagag,
            boardID: "issue",
            title: "이슈",
            author: "aagag",
            date: nil,
            dateText: "방금",
            commentCount: 0,
            // /mirror/re 아닌 경로 → 미러 분기 우회
            url: URL(string: "https://aagag.com/issue/?idx=42")!
        )

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(resolverCalled.value, 0,
                       "/mirror/re ss=… 매칭 실패 시 resolver 호출 안 함")
        // AagagParser 가 빈 HTML 을 거부하면 errorMessage, 통과하면 detail.
        // 두 경로 모두 isLoading=false 로 정착하면 OK.
        XCTAssertFalse(loader.isLoading)
    }

    // MARK: - Render gate (텍스트 전용 글 면제)

    /// 400ms 렌더 게이트는 푸시 애니메이션 중 이미지 서브트리 빌드를 막는
    /// 장치 — 보호할 미디어가 없는 텍스트 전용 글은 게이트 없이 즉시 commit.
    func testTextOnlyDetailSkipsRenderGate() async {
        let loader = PostDetailLoader(
            fetcher: { [bobaeDeletedHTML] _, _ in bobaeDeletedHTML },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)
        let start = ContinuousClock.now
        // 게이트가 무시되지 않으면 5초를 통째로 기다린다.
        await loader.load(post: bobaePost(), cache: cache, renderReadyAt: now() + .seconds(5))
        let elapsed = ContinuousClock.now - start
        XCTAssertNotNil(loader.detail)
        XCTAssertLessThan(elapsed, .seconds(2), "텍스트 전용 글은 렌더 게이트를 기다리면 안 됨")
    }

    func testNeedsRenderGatePredicate() {
        func detail(_ blocks: [ContentBlock], comments: [PostComment] = []) -> PostDetail {
            PostDetail(post: bobaePost(), blocks: blocks, fullDateText: nil,
                       viewCount: nil, source: nil, comments: comments)
        }
        func comment(sticker: URL? = nil, video: URL? = nil) -> PostComment {
            PostComment(id: "c", author: "a", dateText: "", content: "텍스트",
                        likeCount: 0, isReply: false, stickerURL: sticker, videoURL: video)
        }
        let img = URL(string: "https://e.com/a.png")!

        XCTAssertFalse(PostDetailLoader.needsRenderGate(detail([.text("본문")])))
        XCTAssertFalse(PostDetailLoader.needsRenderGate(
            detail([.text("a"), .dealLink(img, label: "링크")], comments: [comment()])),
            "텍스트+링크 본문, 미디어 없는 댓글 — 게이트 불필요")

        XCTAssertTrue(PostDetailLoader.needsRenderGate(detail([.image(img)])))
        XCTAssertTrue(PostDetailLoader.needsRenderGate(detail([.video(img)])))
        XCTAssertTrue(PostDetailLoader.needsRenderGate(detail([.embed(.youtube, id: "abc")])),
                      "embed 배너는 썸네일 이미지를 로드함")
        XCTAssertTrue(PostDetailLoader.needsRenderGate(
            detail([.text("본문")], comments: [comment(sticker: img)])),
            "짧은 텍스트 본문이면 commit 시점에 댓글이 화면에 보임 — 스티커 댓글도 게이트 대상")
        XCTAssertTrue(PostDetailLoader.needsRenderGate(
            detail([.text("본문")], comments: [comment(video: img)])))
    }

    // MARK: - Warm HTML (DetailPrefetcher 소비)

    func testWarmHTMLSkipsNetworkFetch() async {
        let loader = PostDetailLoader(
            fetcher: { _, _ in
                XCTFail("warm HTML 이 있으면 detail fetch 는 생략돼야 함")
                return ""
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) },
            warmHTML: { [bobaeDeletedHTML] id in id == "bobae-1" ? bobaeDeletedHTML : nil }
        )
        let cache = PostDetailCache(capacity: 4)

        await loader.load(post: bobaePost(), cache: cache, renderReadyAt: now())

        XCTAssertNotNil(loader.detail, "prefetch 본으로 파싱 완료")
        XCTAssertNil(loader.errorMessage)
    }

    func testForceFreshIgnoresWarmHTML() async {
        let fetchCount = TestCounter()
        let loader = PostDetailLoader(
            fetcher: { [bobaeDeletedHTML] _, _ in
                fetchCount.increment()
                return bobaeDeletedHTML
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) },
            warmHTML: { [bobaeDeletedHTML] _ in bobaeDeletedHTML }
        )
        let cache = PostDetailCache(capacity: 4)

        await loader.load(post: bobaePost(), cache: cache, renderReadyAt: now(), forceFresh: true)

        XCTAssertEqual(fetchCount.value, 1,
                       "pull-to-refresh 는 prefetch 본 무시하고 재페치 (신선도 보장)")
    }

    // MARK: - 댓글 fetch 실패 노출 (commentsFailed / retryComments)

    // Coolenjoy 는 fetchAllComments 가 항상 별도 comment_view.php 엔드포인트를
    // fetcher 로 받는다 — fetcher 가 그 URL 에서만 throw 하게 해 "본문 성공 +
    // 댓글 실패"를 결정적으로 재현할 수 있는 유일하게 단순한 픽스처.
    private var coolenjoyDetailHTML: String {
        """
        <html><body>
        <article id="bo_v"><div class="view-content"><p>본문 텍스트</p></div></article>
        </body></html>
        """
    }

    private var coolenjoyCommentHTML: String {
        """
        <html><body>
        <article id="c_77">
          <a class="sv_member" title="댓글러 자기소개"></a>
          <time>06-11</time>
          <textarea id="save_comment_77">첫 댓글</textarea>
        </article>
        </body></html>
        """
    }

    private func coolenjoyPost() -> Post {
        Post.fixture(
            id: "cool-1",
            site: .coolenjoy,
            boardID: "free",
            url: URL(string: "https://coolenjoy.net/bbs/free/42")!
        )
    }

    private struct CommentStubError: Error, LocalizedError {
        var errorDescription: String? { "comment fetch failed" }
    }

    func testCommentFetchFailureSetsCommentsFailedAndSkipsCacheWrite() async {
        let loader = PostDetailLoader(
            fetcher: { [coolenjoyDetailHTML] url, _ in
                if url.absoluteString.contains("comment_view") { throw CommentStubError() }
                return coolenjoyDetailHTML
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = coolenjoyPost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertNotNil(loader.detail, "본문은 정상 커밋")
        XCTAssertNil(loader.errorMessage, "댓글 실패는 본문 에러로 승격하지 않음")
        XCTAssertTrue(loader.commentsFailed)
        XCTAssertNil(cache.get(id: post.id),
                     "댓글이 빠진 본은 캐시에 남기지 않음 — 재진입 시 재시도 기회 보존")
    }

    func testCommentFetchSuccessLeavesCommentsFailedFalse() async {
        let loader = PostDetailLoader(
            fetcher: { [coolenjoyDetailHTML, coolenjoyCommentHTML] url, _ in
                url.absoluteString.contains("comment_view")
                    ? coolenjoyCommentHTML
                    : coolenjoyDetailHTML
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = coolenjoyPost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertFalse(loader.commentsFailed)
        XCTAssertEqual(loader.detail?.comments.count, 1)
        XCTAssertNotNil(cache.get(id: post.id))
    }

    func testRetryCommentsSuccessClearsFlagAndCaches() async {
        let failComments = TestFlag(true)
        let loader = PostDetailLoader(
            fetcher: { [coolenjoyDetailHTML, coolenjoyCommentHTML] url, _ in
                guard url.absoluteString.contains("comment_view") else {
                    return coolenjoyDetailHTML
                }
                if failComments.value { throw CommentStubError() }
                return coolenjoyCommentHTML
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = coolenjoyPost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())
        XCTAssertTrue(loader.commentsFailed, "전제: 첫 로드에서 댓글 실패")

        failComments.set(false)
        await loader.retryComments(cache: cache)

        XCTAssertFalse(loader.commentsFailed)
        XCTAssertEqual(loader.detail?.comments.count, 1,
                       "retry 성공 시 댓글이 기존 본문에 붙음")
        XCTAssertNotNil(cache.get(id: post.id),
                        "완전해진 본은 캐시에 저장")
    }

    func testRetryCommentsFailureKeepsFlag() async {
        let loader = PostDetailLoader(
            fetcher: { [coolenjoyDetailHTML] url, _ in
                if url.absoluteString.contains("comment_view") { throw CommentStubError() }
                return coolenjoyDetailHTML
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = coolenjoyPost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())
        XCTAssertTrue(loader.commentsFailed, "전제: 첫 로드에서 댓글 실패")

        await loader.retryComments(cache: cache)

        XCTAssertTrue(loader.commentsFailed, "재실패 시 배너 유지")
        XCTAssertNil(cache.get(id: post.id))
    }

    // MARK: - Initial state

    func testInitialIsLoadingTrueBeforeFirstLoadCall() {
        let loader = PostDetailLoader(
            fetcher: { _, _ in "" },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        XCTAssertTrue(loader.isLoading,
                      "init 직후 isLoading=true 로 시작 (첫 frame 에서 spinner)")
        XCTAssertNil(loader.detail)
        XCTAssertNil(loader.errorMessage)
    }
}

// MARK: - Test helpers

/// 테스트 중간에 fetcher 동작을 바꾸는 스위치 (예: "첫 로드는 실패, retry 는 성공").
private final class TestFlag: @unchecked Sendable {
    private var flag: Bool
    private let lock = NSLock()

    init(_ initial: Bool) { flag = initial }

    func set(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        flag = newValue
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

private final class TestCounter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        n += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}
