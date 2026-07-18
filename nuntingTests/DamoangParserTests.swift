import XCTest
@testable import nunting

/// 다모앙(damoang.net) 파서 회귀 테스트. 다모앙은 aagag 미러 dispatch 전용
/// 타깃 — 목록은 없고 상세(SSR DOM) + 댓글(JSON API)만 파싱한다.
/// 픽스처는 2026-07-18 실측 SSR(SvelteKit + tiptap 에디터) 마크업을 축약한 것.
final class DamoangParserTests: XCTestCase {

    // MARK: - Site 배선

    func testSiteDetectRoutesDamoangHosts() {
        XCTAssertEqual(Site.detect(host: "damoang.net"), .damoang)
        XCTAssertEqual(Site.detect(host: "www.damoang.net"), .damoang)
        XCTAssertNil(Site.detect(host: "not-damoang.net"))
    }

    func testAagagSSMapsDamoangToFreeBoard() {
        XCTAssertEqual(
            AagagParser.directSourceURL(fromSS: "damoang_6739140")?.absoluteString,
            "https://damoang.net/free/6739140"
        )
    }

    // MARK: - parseDetail

    /// 실측 상세 SSR 축약: 제목은 `[data-slot=card-title]`, 날짜는 작성자
    /// 블록의 `p.text-secondary-foreground`, 조회/공감은 헤더 우측 span,
    /// 본문은 유일한 `div.prose`(tiptap: p / img / youtube iframe).
    private let detailHTML = """
    <html><head>
    <script type="application/ld+json">[{"@context":"https://schema.org","@type":"DiscussionForumPosting","headline":"이재명은 버릴 카드가 아닙니다","datePublished":"2026-07-18T08:43:29+09:00"}]</script>
    </head><body>
    <div data-slot="card-title" class="text-foreground flex flex-wrap items-center gap-2 break-words text-xl font-bold sm:text-2xl"><!--[!--><!--]--> 이재명은 버릴 카드가 아닙니다 <!--[!--><!--]--></div>
    <div class="svelte-d71ywd"><p class="text-foreground flex items-center gap-1.5 font-medium svelte-d71ywd"><span class=" ">살찐곰팅</span><span class="text-muted-foreground ml-1 text-xs font-normal svelte-d71ywd">(1.♡.221.165)</span></p> <p class="text-secondary-foreground svelte-d71ywd" style="font-size: 0.9em;">2026년 7월 18일 AM 08:43 <!--[!--><!--]--></p></div>
    <div class="text-secondary-foreground ml-auto flex gap-2 sm:gap-4 svelte-d71ywd" style="font-size: 0.85em;"><span class="svelte-d71ywd">조회 1,047</span> <span class="svelte-d71ywd">공감 3</span></div>
    <div class="prose prose-neutral dark:prose-invert max-w-none  svelte-1hoexo2" style="font-size: var(--content-font-size, 16px);"><!----><p style="text-align: left">본문 첫 줄</p><img src="https://s3.damoang.net/data/editor/2607/6912101.jpg"><div data-youtube-video=""><iframe class="tiptap-youtube" width="640" height="480" src="https://www.youtube.com/embed/tU_ea5i1jVo?rel=1"></iframe></div><p style="text-align: left">본문 끝 줄</p></div>
    </body></html>
    """

    private func damoangPost(
        url: String = "https://damoang.net/free/6739140"
    ) -> Post {
        Post.fixture(
            id: "aagag-damoang_6739140",
            site: .damoang,
            boardID: "aagag",
            title: "목록 제목",
            url: URL(string: url)!
        )
    }

    func testParseDetailExtractsTitleMetaAndBlocks() throws {
        let parser = DamoangParser()
        let detail = try parser.parseDetail(html: detailHTML, post: damoangPost())

        XCTAssertEqual(detail.fullTitle ?? detail.post.title, "이재명은 버릴 카드가 아닙니다")
        XCTAssertEqual(detail.viewCount, 1047, "조회 1,047 → 1047")
        XCTAssertEqual(detail.post.recommendCount, 3, "공감 3 → 3")
        XCTAssertEqual(detail.fullDateText, "2026년 7월 18일 AM 08:43")

        XCTAssertEqual(
            detail.blocks.imageURLs.map(\.absoluteString),
            ["https://s3.damoang.net/data/editor/2607/6912101.jpg"]
        )
        XCTAssertEqual(detail.blocks.youtubeIDs, ["tU_ea5i1jVo"])
        let text = detail.blocks.plainText
        XCTAssertTrue(text.contains("본문 첫 줄"))
        XCTAssertTrue(text.contains("본문 끝 줄"))
    }

    /// 삭제/이동된 글: SvelteKit 404 셸(제목 "게시글을 찾을 수 없습니다",
    /// 본문 "요청하신 게시글이 삭제되었거나…")에는 prose 가 없다 — 구조 파손
    /// 오인 대신 안내 블록을 렌더해야 한다.
    func testParseDetailDeletedPostRendersNotice() throws {
        let html = """
        <html><body>
        <h1>게시글을 찾을 수 없습니다</h1>
        <p>요청하신 게시글이 삭제되었거나, 주소가 변경되었을 수 있습니다.</p>
        </body></html>
        """
        let parser = DamoangParser()
        let detail = try parser.parseDetail(html: html, post: damoangPost())
        XCTAssertEqual(detail.blocks.count, 1)
        XCTAssertTrue(detail.blocks.plainText.contains("삭제"))
    }

    /// prose 도 없고 삭제 안내 키워드도 없으면 마크업 변경 — structureChanged
    /// 로 던져 텔레메트리/배너 신호를 살린다.
    func testParseDetailMissingProseWithoutNoticeThrows() {
        let html = "<html><body><div>전혀 다른 페이지</div></body></html>"
        let parser = DamoangParser()
        XCTAssertThrowsError(
            try parser.parseDetail(html: html, post: damoangPost())
        ) { error in
            guard case ParserError.structureChanged = error else {
                return XCTFail("structureChanged 가 아님: \(error)")
            }
        }
    }

    // MARK: - 댓글 JSON API

    func testCommentsURLBuildsBoardScopedAPIURL() {
        let parser = DamoangParser()
        XCTAssertEqual(
            parser.commentsURL(for: damoangPost())?.absoluteString,
            "https://damoang.net/api/boards/free/posts/6739140/comments?page=1&limit=20"
        )
        // 게시판 슬러그는 URL 경로에서 그대로 딴다 — free 외 보드도 성립.
        XCTAssertEqual(
            parser.commentsURL(for: damoangPost(url: "https://damoang.net/promotion/1234"))?.absoluteString,
            "https://damoang.net/api/boards/promotion/posts/1234/comments?page=1&limit=20"
        )
        // 경로가 {board}/{숫자 id} 꼴이 아니면 nil — 댓글 fetch 를 걸지 않는다.
        XCTAssertNil(parser.commentsURL(for: damoangPost(url: "https://damoang.net/free")))
    }

    /// 실측 `/api/boards/free/posts/{id}/comments` 응답 축약. content 는 HTML,
    /// created_at 은 UTC(Z) ISO8601(밀리초 포함), depth 1+ 는 답글.
    private func commentJSON(
        page: Int, totalPages: Int, comments: [(id: Int, content: String, depth: Int)]
    ) -> String {
        let items = comments.map { c in
            """
            {"id":\(c.id),"content":"\(c.content)","link1":"","link2":"",
             "author":"세상여행","author_id":"google_86e00856",
             "author_image":"https://r2.damoang.net/data/editor/2607/ee34299.jpg",
             "author_ip":"61.♡.129.130","likes":14,"dislikes":0,
             "depth":\(c.depth),"parent_id":6739140,
             "created_at":"2026-07-17T23:51:10.000Z","updated_at":null,
             "is_secret":false,"deleted_at":null,"deleted_by":null,"edit_count":1}
            """
        }.joined(separator: ",")
        return """
        {"success":true,"data":{"comments":[\(items)],"total":24,"page":\(page),
         "limit":20,"total_pages":\(totalPages)},
         "meta":{"comment_edit_policy":{"cost":50000,"grace_seconds":300}}}
        """
    }

    func testDecodeCommentsMapsFieldsAndFlattensHTML() throws {
        let parser = DamoangParser()
        let json = commentJSON(page: 1, totalPages: 1, comments: [
            (id: 6739157, content: "<p>배신의 감정은 치유되지 않죠.</p><p>둘째 줄</p>", depth: 0),
            (id: 6739169, content: "<p>답글입니다</p>", depth: 1),
        ])
        let page = try parser.decodeCommentPage(json)

        XCTAssertEqual(page.totalPages, 1)
        XCTAssertEqual(page.comments.count, 2)

        let first = try XCTUnwrap(page.comments.first)
        XCTAssertEqual(first.id, "damoang-c-6739157")
        XCTAssertEqual(first.author, "세상여행")
        XCTAssertEqual(first.likeCount, 14)
        XCTAssertFalse(first.isReply)
        XCTAssertEqual(first.content, "배신의 감정은 치유되지 않죠.\n둘째 줄")
        // UTC ISO(created_at) → 로컬 타임존 `yyyy-MM-dd HH:mm` (에토랜드
        // 댓글과 동일 표기). 기대값은 같은 변환으로 산출해 타임존 독립.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.locale = Locale(identifier: "ko_KR")
        let expected = fmt.string(from: try XCTUnwrap(iso.date(from: "2026-07-17T23:51:10.000Z")))
        XCTAssertEqual(first.dateText, expected)

        XCTAssertTrue(try XCTUnwrap(page.comments.last).isReply)
    }

    func testDecodeCommentExtractsInlineImageAsSticker() throws {
        let parser = DamoangParser()
        let json = commentJSON(page: 1, totalPages: 1, comments: [
            (id: 1, content: "<p>움짤</p><img src=\\\"https://r2.damoang.net/data/editor/2607/meme.png\\\">", depth: 0),
        ])
        let page = try parser.decodeCommentPage(json)
        let comment = try XCTUnwrap(page.comments.first)
        XCTAssertEqual(
            comment.stickerURL?.absoluteString,
            "https://r2.damoang.net/data/editor/2607/meme.png"
        )
        XCTAssertEqual(comment.content, "움짤")
    }

    func testFetchAllCommentsPagesThroughTotalPages() async throws {
        let page1 = commentJSON(page: 1, totalPages: 2, comments: [(id: 1, content: "<p>1페이지</p>", depth: 0)])
        let page2 = commentJSON(page: 2, totalPages: 2, comments: [(id: 2, content: "<p>2페이지</p>", depth: 0)])

        let requested = Requested()
        let parser = DamoangParser(commentFetch: { url, _ in
            await requested.append(url.absoluteString)
            return url.absoluteString.contains("page=2") ? page2 : page1
        })
        let comments = try await parser.fetchAllComments(
            for: damoangPost(), detailHTML: nil
        ) { _ in
            XCTFail("댓글 leg 는 Referer 를 실을 수 없는 프로토콜 fetcher 를 쓰지 않는다")
            return ""
        }

        XCTAssertEqual(comments.map(\.content), ["1페이지", "2페이지"])
        let urls = await requested.urls
        XCTAssertEqual(urls.filter { $0.contains("page=1") }.count, 1)
        XCTAssertEqual(urls.filter { $0.contains("page=2") }.count, 1)
    }

    /// 다모앙 댓글 API 는 page≥2 를 Referer(글 URL) 없이는 403 으로 거절한다
    /// (실측 2026-07-18: page=1 은 무-Referer 허용). Referer 가 빠지면
    /// `mergeCommentPages` 의 페이지 실패 흡수에 삼켜져 "댓글 28개 중 20개만
    /// 표시" 꼴로 조용히 잘린다 — 모든 페이지 요청에 글 URL 이 실려야 한다.
    func testFetchAllCommentsSendsPostURLAsRefererOnEveryPage() async throws {
        let post = damoangPost()
        let page1 = commentJSON(page: 1, totalPages: 2, comments: [(id: 1, content: "<p>1페이지</p>", depth: 0)])
        let page2 = commentJSON(page: 2, totalPages: 2, comments: [(id: 2, content: "<p>2페이지</p>", depth: 0)])

        let parser = DamoangParser(commentFetch: { url, referer in
            guard referer == post.url else { throw NetworkError.badResponse(403) }
            return url.absoluteString.contains("page=2") ? page2 : page1
        })
        let comments = try await parser.fetchAllComments(for: post, detailHTML: nil) { _ in
            XCTFail("댓글 leg 는 프로토콜 fetcher 를 쓰지 않는다")
            return ""
        }

        XCTAssertEqual(comments.map(\.content), ["1페이지", "2페이지"],
                       "Referer 누락 페이지가 있으면 403 → 해당 페이지가 조용히 빠진다")
    }

    /// fetcher 호출 기록용 — @Sendable 클로저에서 안전하게 누적.
    private actor Requested {
        var urls: [String] = []
        func append(_ url: String) { urls.append(url) }
    }
}
