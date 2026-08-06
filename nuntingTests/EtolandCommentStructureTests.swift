import XCTest
@testable import nunting

/// 회귀 가드: 2026-08-06 라이브 샘플링에서 확인된 이토랜드 구조 변경 2종.
///
/// (1) SSR flight 페이로드의 댓글 배열 키가 `"comments"` → `"commentList"` 로
///     바뀌었다. 샘플 5건(9241090/9240813/9241057/9241045/9241075) 전부 옛 키는
///     0건, 새 키는 1건. 인접 키 `bestCommentList`(빈 배열)·
///     `commentListPagination`(객체) 가 같은 페이로드에 함께 있어서, 마커는
///     이 둘에 걸리지 않아야 한다.
///
/// (2) 댓글 API 가 Accept 헤더로 content negotiation 을 한다. 앱의 기본 Accept
///     (`text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8`) 로
///     요청하면 JSON 이 아니라 `application/xhtml+xml`(<BaseResponse>…</>) 을
///     돌려줘 `JSONDecoder` 가 통째로 실패한다 → 모든 글이 댓글 실패 배너.
///     `Accept: application/json` 을 명시해야 JSON 이 온다.
final class EtolandCommentStructureTests: XCTestCase {
    private let parser = EtolandParser()

    private func post(
        _ url: String = "https://etoland.co.kr/b/etohumor07/view/-9241075"
    ) -> Post {
        Post.fixture(id: "x", site: .etoland, boardID: "aagag", url: URL(string: url)!)
    }

    /// 라이브 페이로드 축약본 — `commentList` 앞뒤로 실제와 같은 이웃 키를
    /// 두어 마커가 그것들에 걸리지 않는지도 함께 본다.
    private func inlineHTML(commentsKey: String) -> String {
        let comment = #"{\"wrId\":9241075,\"commentId\":70469751,\"parentId\":null,\"writeDateTimestamp\":1786000579000,\"recommendCount\":3,\"content\":\"본문 [대괄호] 포함\",\"isAnonymous\":false,\"member\":{\"nickname\":\"미나루\",\"image\":null},\"file\":null,\"childrenComments\":[]}"#
        return """
        <html><body>
        <article>
          <h1><span class="truncate">제목</span></h1>
          <div><div class="caption-s"><span class="nickname">글쓴이</span><time>2026-08-06 12:00:00</time></div></div>
          <div class="view-content"><p>본문</p></div>
        </article>
        <script>self.__next_f.push([1,"4f:[\\"$\\",\\"$L57\\",null,{\\"isMobile\\":true,\\"\(commentsKey)\\":[\(comment)],\\"commentListPagination\\":{\\"page\\":1,\\"size\\":50,\\"totalCount\\":1},\\"bestCommentList\\":[]}]"])</script>
        </body></html>
        """
    }

    // MARK: - (1) SSR 키 rename

    func testParseDetailExtractsInlineCommentListKey() throws {
        let detail = try parser.parseDetail(html: inlineHTML(commentsKey: "commentList"), post: post())
        XCTAssertEqual(detail.comments.count, 1, #"현행 SSR 키 \"commentList\" 에서 댓글을 뽑아야 함"#)
        XCTAssertEqual(detail.comments[0].author, "미나루")
        XCTAssertEqual(detail.comments[0].content, "본문 [대괄호] 포함")
        XCTAssertEqual(detail.comments[0].likeCount, 3)
    }

    func testInlineCommentListShortCircuitsAPIFetch() async throws {
        // 인라인이 이겼으면 병렬 API 왕복을 하지 않는다(= parseDetail 결과 유지).
        let comments = try await parser.fetchAllComments(
            for: post(), detailHTML: inlineHTML(commentsKey: "commentList")
        ) { _ in
            XCTFail("인라인 우선 경로는 fetch 하면 안 됨")
            return ""
        }
        XCTAssertTrue(comments.isEmpty)
    }

    func testBestCommentListAloneIsNotMistakenForCommentList() throws {
        // `\"bestCommentList\":[` 는 `\"commentList\":[` 를 부분 문자열로 갖지
        // 않는다(앞의 `\"` 덕분). 베스트 댓글만 있는 페이로드에서 오탐 금지.
        let html = """
        <html><body>
        <article>
          <h1><span class="truncate">제목</span></h1>
          <div class="view-content"><p>본문</p></div>
        </article>
        <script>self.__next_f.push([1,"4f:[{\\"bestCommentList\\":[{\\"commentId\\":1,\\"content\\":\\"베스트\\"}]}]"])</script>
        </body></html>
        """
        XCTAssertTrue(try parser.parseDetail(html: html, post: post()).comments.isEmpty)
    }

    func testLegacyCommentsKeyStillExtracted() throws {
        // 롤백/부분 배포 대비로 옛 봉투(`\"data\":{\"comments\":[`)도 유지.
        let legacy = """
        <html><body>
        <article>
          <h1><span class="truncate">제목</span></h1>
          <div class="view-content"><p>본문</p></div>
        </article>
        <script>self.__next_f.push([1,"6:[\\"$\\",\\"$L32\\",null,{\\"data\\":{\\"comments\\":[{\\"commentId\\":1,\\"parentId\\":null,\\"writeDateTimestamp\\":1,\\"recommendCount\\":0,\\"content\\":\\"옛 봉투\\",\\"isAnonymous\\":false,\\"member\\":{\\"nickname\\":\\"a\\"},\\"file\\":null,\\"childrenComments\\":[]}]}}]"])</script>
        </body></html>
        """
        let detail = try parser.parseDetail(html: legacy, post: post())
        XCTAssertEqual(detail.comments.count, 1)
        XCTAssertEqual(detail.comments[0].content, "옛 봉투")
    }

    // MARK: - (2) Accept content negotiation

    func testCommentsAPIRequestsJSONExplicitly() throws {
        let url = try XCTUnwrap(parser.commentsURL(for: post()))
        XCTAssertEqual(
            parser.acceptHeader(for: url), "application/json",
            "앱 기본 Accept 로는 서버가 XML(<BaseResponse>)을 돌려준다"
        )
    }

    func testAcceptOverrideIsScopedToTheCommentsAPI() {
        // 상세 페이지 HTML 요청까지 JSON 으로 바꾸면 안 된다.
        XCTAssertNil(parser.acceptHeader(for: post().url))
    }

    func testXMLResponseIsReportedAsStructureChanged() async {
        // 그래도 XML 이 오면(협상 실패) 조용히 [] 로 뭉개지 말고 배너를 띄운다.
        let xml = "<BaseResponse><status>ETOCD200000</status><data><comments/></data></BaseResponse>"
        do {
            _ = try await parser.fetchAllComments(for: post(), detailHTML: nil) { _ in xml }
            XCTFail("XML 응답은 throw 해야 함")
        } catch {
            guard case ParserError.structureChanged = error else {
                return XCTFail("expected .structureChanged, got \(error)")
            }
        }
    }

    // MARK: - 댓글이 막힌 글

    func testCommentsDisabledArticleIsEmptyNotAFailure() async throws {
        // uneedcar(중고차 판매) 같은 게시판은 댓글 자체가 막혀 있고 API 가
        // ETOCD400015 를 준다 — "댓글 없는 글"이지 파손이 아니므로 헛배너 금지.
        let body = #"{"status":"ETOCD400015","data":null,"message":"이 글은 댓글을 읽거나 작성할 수 없습니다."}"#
        let comments = try await parser.fetchAllComments(for: post(), detailHTML: nil) { _ in body }
        XCTAssertTrue(comments.isEmpty)
    }
}
