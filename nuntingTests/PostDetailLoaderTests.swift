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

    /// structureChanged 를 유발하는 테스트는 반드시 이걸 주입 — 기본값(.shared)
    /// 은 실서버로 업로드한다.
    private func noopTelemetry() -> ParserFailureTelemetry {
        ParserFailureTelemetry(sender: { _, _, _ in })
    }

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

    func testStructureChangedReportsDetailTelemetry() async {
        let exp = expectation(description: "telemetry sent")
        nonisolated(unsafe) var recorded: (site: String, phase: String)?
        let telemetry = ParserFailureTelemetry(sender: { site, phase, _ in
            recorded = (site, phase)
            exp.fulfill()
        })
        let loader = PostDetailLoader(
            fetcher: { _, _ in
                // 본문 컨테이너도 삭제 안내도 없는 "구조 깨짐" 응답 —
                // BobaeParser 가 structureChanged 를 던진다
                // (ParserStructureChangedTests 와 동일 시나리오).
                "<html><body><div>nothing here</div></body></html>"
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) },
            telemetry: telemetry
        )
        let cache = PostDetailCache(capacity: 4)

        await loader.load(post: bobaePost(), cache: cache, renderReadyAt: now())

        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(recorded?.site, "bobae")
        XCTAssertEqual(recorded?.phase, "detail")
        XCTAssertNotNil(loader.errorMessage, "텔레메트리는 에러 표시를 대체하지 않는다")
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

    func testAagagDirectSourceURLDispatchesToSourceParserWithoutResolver() async {
        // parseList 가 이미 원본 직접 URL 로 재작성한 행(site=.aagag, host=원본
        // 사이트): 미러 리다이렉트 resolver 를 거치지 않고 곧장 원본 파서로
        // 디스패치되어 그 사이트의 인코딩으로 로드돼야 한다.
        let resolverCalled = TestCounter()
        let loader = PostDetailLoader(
            fetcher: { [bobaeDeletedHTML] _, _ in bobaeDeletedHTML },
            resolver: { url in
                resolverCalled.increment()
                return Networking.ResolvedRedirect(url: url, prefetchedBody: nil)
            }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = Post(
            id: "aagag-bobae_42",
            site: .aagag,
            boardID: "mirror",
            title: "미러",
            author: "aagag",
            date: nil,
            dateText: "방금",
            commentCount: 0,
            // AagagParser.directSourceURL 이 재작성한 bobae 원본 모바일 URL
            url: URL(string: "https://m.bobaedream.co.kr/board/bbs_view/strange/42")!
        )

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(resolverCalled.value, 0,
                       "원본 직접 URL 은 리다이렉트 resolver 를 거치지 않음")
        XCTAssertNotNil(loader.detail, "host 로 BobaeParser 디스패치되어 파싱 완료")
        XCTAssertFalse(loader.isLoading)
        XCTAssertNil(loader.errorMessage)
    }

    func testAagagDirectSourceUsesSourceSiteEncodingNotAagag() async {
        // Option 2 의 핵심 리스크: 원본 직접 URL(site=.aagag 유지)을 상세 fetch
        // 할 때 반드시 **원본 사이트** 인코딩을 써야 한다 — ppomppu 는 CP949 라
        // aagag(UTF-8)로 받으면 한글이 깨진다. detail fetch 로 넘어간 encoding 을
        // 캡처해 검증(fetch 가 파싱보다 먼저이므로 파싱 성공 여부와 무관).
        XCTAssertNotEqual(Site.ppomppu.encoding, Site.aagag.encoding,
                          "전제: ppomppu(CP949) 와 aagag(UTF-8) 인코딩이 실제로 다름")
        let recorder = FetchRecorder()
        let loader = PostDetailLoader(
            fetcher: { url, encoding in
                recorder.record(url: url, encoding: encoding)
                return "<html></html>"
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) },
            telemetry: noopTelemetry()  // 빈 HTML → PpomppuParser structureChanged
        )
        let cache = PostDetailCache(capacity: 4)
        let post = Post(
            id: "aagag-ppomppu_1",
            site: .aagag,
            boardID: "mirror",
            title: "미러",
            author: "aagag",
            date: nil,
            dateText: "방금",
            commentCount: 0,
            url: URL(string: "https://m.ppomppu.co.kr/new/bbs_view.php?id=freeboard&no=1")!
        )

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        guard let first = recorder.first else { XCTFail("detail fetcher 미호출"); return }
        XCTAssertEqual(first.url.host, "m.ppomppu.co.kr",
                       "원본 ppomppu URL 로 직접 fetch")
        XCTAssertEqual(first.encoding, Site.ppomppu.encoding,
                       "상세는 원본(ppomppu, CP949) 인코딩으로 fetch — aagag UTF-8 아님")
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
            },
            telemetry: noopTelemetry()  // 빈 HTML → AagagParser structureChanged
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

    // MARK: - 애객 미러 짧은 본문 캡챠 안전망

    func testAagagMirrorShortBodyChallengesThenRefetches() async {
        // /mirror/re 본문이 짧으면(<3KB) detector 통과 여부와 무관하게 챌린지
        // 시트를 띄우고 한 번 재요청한다. 재요청이 충분히 길면 그대로 진행.
        let challengeCount = TestCounter()
        let fetchCount = TestCounter()
        let longBody = String(repeating: "<p>x</p>", count: 500)  // >3000자
        let loader = PostDetailLoader(
            fetcher: { _, _ in
                fetchCount.incrementAndGet() == 1 ? "<html>짧음</html>" : longBody
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) },
            warmHTML: { _ in nil },
            challenger: { _ in challengeCount.increment() },
            telemetry: noopTelemetry()  // 재요청 본문도 AagagParser structureChanged
        )
        let cache = PostDetailCache(capacity: 4)

        await loader.load(post: aagagMirrorPost(), cache: cache, renderReadyAt: now())

        XCTAssertEqual(challengeCount.value, 1, "짧은 미러 본문 → 챌린지 1회")
        XCTAssertEqual(fetchCount.value, 2, "챌린지 후 재요청 1회")
    }

    func testAagagMirrorPersistentShortBodyThrowsCaptchaChallenge() async {
        // 재요청 결과도 여전히 짧으면(시트 닫힘/쿠키 실패) 인터스티셜을 파서로
        // 넘기지 않고 통일된 캡챠 에러로 surface 한다.
        let challengeCount = TestCounter()
        let fetchCount = TestCounter()
        let loader = PostDetailLoader(
            fetcher: { _, _ in fetchCount.increment(); return "<html>짧음</html>" },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) },
            warmHTML: { _ in nil },
            challenger: { _ in challengeCount.increment() }
        )
        let cache = PostDetailCache(capacity: 4)

        await loader.load(post: aagagMirrorPost(), cache: cache, renderReadyAt: now())

        XCTAssertEqual(challengeCount.value, 1)
        XCTAssertEqual(fetchCount.value, 2, "초기 + 재요청")
        XCTAssertEqual(loader.errorMessage, "자동등록방지 통과 실패 — 다시 시도해 주세요",
                       "재요청도 짧으면 캡챠 에러로 surface (파서로 안 넘김)")
        XCTAssertNil(loader.detail, "캡챠 에러 시 detail 미설정")
    }

    func testAagagIssuePageShortBodyDoesNotTriggerChallenge() async {
        // /issue/ 네이티브 페이지는 /mirror/re 가 아니므로 안전망 비대상 —
        // 짧은 정상 본문에 오탐 챌린지가 뜨지 않아야 한다.
        let challengeCount = TestCounter()
        let loader = PostDetailLoader(
            fetcher: { _, _ in "<html>짧음</html>" },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) },
            warmHTML: { _ in nil },
            challenger: { _ in challengeCount.increment() },
            telemetry: noopTelemetry()  // 짧은 본문 → AagagParser structureChanged
        )
        let cache = PostDetailCache(capacity: 4)
        let post = Post(
            id: "x", site: .aagag, boardID: "issue", title: "이슈", author: "a",
            date: nil, dateText: "방금", commentCount: 0,
            url: URL(string: "https://aagag.com/issue/?idx=42")!
        )

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(challengeCount.value, 0, "/issue/ 페이지는 챌린지 안 함")
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

    /// 댓글 병합 재구성(`withComments`)이 fullTitle 등 다른 필드를 보존하는지.
    /// ppomppu 처럼 댓글을 따로 받아 합치는 경로에서 fullTitle 이 떨어져나가
    /// 헤더 제목이 리스트 잘림본으로 되돌아가던 버그의 회귀 네트.
    func testWithCommentsPreservesAllOtherFields() {
        let base = PostDetail(
            post: bobaePost(),
            blocks: [.text("본문")],
            fullDateText: "2026-06-24 15:34",
            viewCount: 1326,
            source: nil,
            comments: [],
            fullTitle: "[지마켓] 마이크로닉스 Classic II 850W (140,550원/무료)"
        )
        let c = PostComment(id: "c", author: "a", dateText: "", content: "댓글",
                            likeCount: 0, isReply: false, stickerURL: nil, videoURL: nil)
        let merged = base.withComments([c])
        XCTAssertEqual(merged.fullTitle, base.fullTitle, "댓글 병합 후에도 fullTitle 보존")
        XCTAssertEqual(merged.comments.count, 1, "comments 는 교체")
        XCTAssertEqual(merged.fullDateText, base.fullDateText)
        XCTAssertEqual(merged.viewCount, base.viewCount)
        XCTAssertEqual(merged.blocks.count, base.blocks.count)
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

    /// `<time>` 마커로 본 버전(v1/v2)을 구분할 수 있는 변형 — CoolenjoyParser 가
    /// `fullDateText` 로 읽어 주므로 어느 본이 살아남았는지 단언 가능.
    private nonisolated static func coolenjoyDetailHTML(dateMarker: String) -> String {
        """
        <html><body>
        <article id="bo_v">
          <time>\(dateMarker)</time>
          <div class="view-content"><p>본문 텍스트</p></div>
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

    func testRetryCommentsDoesNotOverwriteFresherForceFreshLoad() async {
        // 배너가 떠 있는 동안 pull-to-refresh 가 끼어드는 레이스:
        // retry 의 댓글 fetch 가 매달린 사이 forceFresh 로드가 더 신선한
        // 본(v2)을 커밋하면, 늦게 끝난 retry 가 stale 본(v1)으로 detail/캐시를
        // 되돌리면 안 된다.
        let detailCalls = TestCounter()
        let commentCalls = TestCounter()
        let gate = AsyncGate()
        let loader = PostDetailLoader(
            fetcher: { [coolenjoyCommentHTML] url, _ in
                if url.absoluteString.contains("comment_view") {
                    switch commentCalls.incrementAndGet() {
                    case 1: throw CommentStubError()    // 첫 로드: 댓글 실패 → 배너
                    case 2:                              // retry: gate 에 매달림
                        await gate.wait()
                        return coolenjoyCommentHTML
                    default:                             // forceFresh 로드: 즉시 성공
                        return coolenjoyCommentHTML
                    }
                }
                let version = detailCalls.incrementAndGet() == 1 ? "v1" : "v2"
                return Self.coolenjoyDetailHTML(dateMarker: version)
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = coolenjoyPost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())
        XCTAssertTrue(loader.commentsFailed, "전제: 첫 로드에서 댓글 실패")
        XCTAssertEqual(loader.detail?.fullDateText, "v1")

        let retryTask = Task { await loader.retryComments(cache: cache) }
        // retry 의 댓글 fetch 가 gate 에 매달릴 때까지 대기.
        for _ in 0..<500 where commentCalls.value < 2 { await Task.yield() }
        XCTAssertEqual(commentCalls.value, 2, "전제: retry 가 댓글 fetch 에 진입")

        await loader.load(post: post, cache: cache, renderReadyAt: now(), forceFresh: true)
        XCTAssertEqual(loader.detail?.fullDateText, "v2", "전제: refresh 가 신선한 본 커밋")

        await gate.signal()
        await retryTask.value

        XCTAssertEqual(loader.detail?.fullDateText, "v2",
                       "늦게 끝난 retry 가 stale 본으로 덮어쓰면 안 됨")
        XCTAssertEqual(cache.get(id: post.id)?.detail.fullDateText, "v2",
                       "캐시도 신선한 본 유지")
        XCTAssertFalse(loader.commentsFailed)
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

    func testCommentFetchCancellationDoesNotSetCommentsFailed() async {
        // 취소 계열(URLError.cancelled / CancellationError)은 부모 취소의
        // 전파이지 "댓글 로드 실패"가 아니다 — 배너 대상에서 제외.
        for cancellation in [URLError(.cancelled) as Error, CancellationError()] {
            let loader = PostDetailLoader(
                fetcher: { [coolenjoyDetailHTML] url, _ in
                    if url.absoluteString.contains("comment_view") { throw cancellation }
                    return coolenjoyDetailHTML
                },
                resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
            )
            let cache = PostDetailCache(capacity: 4)

            await loader.load(post: coolenjoyPost(), cache: cache, renderReadyAt: now())

            XCTAssertFalse(loader.commentsFailed,
                           "취소(\(type(of: cancellation)))는 실패 배너로 승격하면 안 됨")
        }
    }

    func testCacheHitResetsCommentsFailed() async {
        // 댓글 실패 본은 캐시에 안 들어가지만, 다른 화면의 loader 가 같은
        // 글을 성공적으로 캐시했을 수 있다 — 히트 복원 시 배너는 내려간다.
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

        // 다른 loader 가 완전한 본을 캐시에 넣었다고 가정.
        let complete = PostDetail(
            post: post, blocks: [.text("완전본")], fullDateText: nil,
            viewCount: nil, source: nil, comments: []
        )
        cache.put(id: post.id, detail: complete)

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertFalse(loader.commentsFailed, "캐시 히트 복원 시 실패 배너 해제")
    }

    // MARK: - 댓글 파싱 실행 위치 (off-MainActor 회귀 네트)

    // approachable concurrency(nonsending) 에선 nonisolated async 인
    // `fetchAllComments` 가 **호출자의 executor** 에서 돈다 — @MainActor
    // 메서드에서 직접 await 하면 댓글 SwiftSoup/JSON 파싱이 통째로 메인에서
    // 돈다(실측 hang 원인). 아래 두 테스트는 fetcher 가 불린 스레드를 기록해
    // 이를 고정한다: fetcher(@Sendable=nonsending)는 fetchAllComments 의
    // executor 를 그대로 따르고, 파싱은 fetcher await 복귀 직후 같은 executor
    // 에서 돌므로 "fetcher 가 메인" ⇔ "파싱이 메인" 의 정확한 프록시다.
    // async let 자식(비격리) 형태를 직접 await 로 되돌리는 회귀가 나면
    // 메인 스레드 기록이 잡혀 실패한다.

    func testCommentLegParsesOffMainThreadDuringLoad() async {
        let recorder = MainThreadRecorder()
        let loader = PostDetailLoader(
            fetcher: { [coolenjoyDetailHTML, coolenjoyCommentHTML] url, _ in
                guard url.absoluteString.contains("comment_view") else {
                    return coolenjoyDetailHTML
                }
                recorder.recordCurrentThread()
                return coolenjoyCommentHTML
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)

        await loader.load(post: coolenjoyPost(), cache: cache, renderReadyAt: now())

        XCTAssertGreaterThan(recorder.count, 0, "전제: 댓글 fetch 발생")
        XCTAssertFalse(recorder.sawMainThread,
                       "load() 댓글 leg 는 async let 자식(협력 풀)에서 돌아야 함 — 메인이면 파싱 hang 회귀")
    }

    func testRetryCommentsParsesOffMainThread() async {
        let failComments = TestFlag(true)
        let recorder = MainThreadRecorder()
        let loader = PostDetailLoader(
            fetcher: { [coolenjoyDetailHTML, coolenjoyCommentHTML] url, _ in
                guard url.absoluteString.contains("comment_view") else {
                    return coolenjoyDetailHTML
                }
                if failComments.value { throw CommentStubError() }
                recorder.recordCurrentThread()
                return coolenjoyCommentHTML
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = coolenjoyPost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())
        XCTAssertTrue(loader.commentsFailed, "전제: 첫 로드에서 댓글 실패 → retry 컨텍스트 무장")

        failComments.set(false)
        await loader.retryComments(cache: cache)

        XCTAssertGreaterThan(recorder.count, 0, "전제: retry 가 댓글 fetch 에 진입")
        XCTAssertFalse(recorder.sawMainThread,
                       "retryComments 도 async let 자식(협력 풀)에서 돌아야 함 — 직접 await 로 되돌리면 메인 파싱 회귀")
        XCTAssertFalse(loader.commentsFailed)
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

/// fetcher 로 넘어온 (url, encoding) 을 순서대로 기록하는 스레드-세이프 레코더.
/// 직접-디스패치 경로가 원본 사이트 인코딩을 쓰는지 검증하는 데 쓴다.
private final class FetchRecorder: @unchecked Sendable {
    private var calls: [(url: URL, encoding: String.Encoding)] = []
    private let lock = NSLock()

    func record(url: URL, encoding: String.Encoding) {
        lock.lock()
        defer { lock.unlock() }
        calls.append((url, encoding))
    }

    var first: (url: URL, encoding: String.Encoding)? {
        lock.lock()
        defer { lock.unlock() }
        return calls.first
    }
}

/// fetcher 가 불린 스레드(메인 여부)를 기록 — 댓글 파싱 실행 위치 회귀 네트용.
private final class MainThreadRecorder: @unchecked Sendable {
    private var flags: [Bool] = []
    private let lock = NSLock()

    /// 호출 시점의 스레드를 기록. `Thread.isMainThread` 는 async 컨텍스트에서
    /// 사용 금지(컴파일 에러)라 pthread 로 직접 판별한다 — 여기선 "실행이
    /// 물리적으로 메인 스레드에 있나"가 정확히 묻고 싶은 것이라 적합하다.
    func recordCurrentThread() {
        lock.lock()
        defer { lock.unlock() }
        flags.append(pthread_main_np() != 0)
    }

    var sawMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flags.contains(true)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return flags.count
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

    @discardableResult
    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        return n
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}

/// signal 전까지 wait 호출자를 매달아 두는 1회용 게이트 — 레이스 choreography 용.
private actor AsyncGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
