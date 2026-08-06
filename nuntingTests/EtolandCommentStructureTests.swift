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
    /// 두어 마커가 그것들에 걸리지 않는지도 함께 본다. `comments` 를 비우면
    /// "진짜 댓글 0개인 글" 페이로드가 된다.
    private func inlineHTML(commentsKey: String, comments: Bool = true) -> String {
        let comment = comments
            ? #"{\"wrId\":9241075,\"commentId\":70469751,\"parentId\":null,\"writeDateTimestamp\":1786000579000,\"recommendCount\":3,\"content\":\"본문 [대괄호] 포함\",\"isAnonymous\":false,\"member\":{\"nickname\":\"미나루\",\"image\":null},\"file\":null,\"childrenComments\":[]}"#
            : ""
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

    // MARK: - 본문발 마커 오탐 (Codex 리뷰 P2)

    /// 이스케이프된 JSON 을 붙여넣은 본문(프로그래밍 스레드)은 마커 문자열을
    /// 그대로 품는다. 마커는 문자열 매칭이라 이걸 못 가리므로, 디코드까지
    /// 성공해야 "인라인이 이겼다"고 본다.
    /// **디코드까지 성공하는** 인용이라는 점이 핵심 — `RawComment` 는
    /// `commentId` 만 필수라 이 조각도 댓글 1개로 멀쩡히 디코드된다. 그래서
    /// 디코드 성공만으로는 본문과 payload 를 가를 수 없고, flight 페이로드
    /// 형제 키(`commentListPagination`)가 최종 판정 근거다.
    private let bodyThatQuotesTheMarker =
        #"<p>이 응답 이렇게 옵니다: {\"commentList\":[{\"commentId\":1}]} 왜 이러죠?</p>"#

    func testDecodableInlinePayloadWinsOverMarkerQuotedInBody() throws {
        // 본문 오탐이 진짜 payload보다 **앞**에 있어도 진짜 쪽이 이겨야 한다.
        let html = inlineHTML(commentsKey: "commentList")
            .replacingOccurrences(of: "<p>본문</p>", with: bodyThatQuotesTheMarker)
        let detail = try parser.parseDetail(html: html, post: post())
        XCTAssertEqual(detail.comments.count, 1, "본문 오탐 뒤의 진짜 payload 를 찾아야 함")
        XCTAssertEqual(detail.comments[0].author, "미나루")
    }

    func testMarkerQuotedInBodyAloneStillFallsBackToAPI() async throws {
        // 오탐만 있고 진짜 payload 가 없으면(=SSR bailout) API 폴백을 타야 한다.
        // 여기서 short-circuit 하면 인용된 조각이 댓글로 표시되고, 진짜 댓글은
        // 통째로 사라진다. (Codex 리뷰 P2 3차 — 비어 있지 않은 인용)
        let html = """
        <html><body>
        <article>
          <h1><span class="truncate">제목</span></h1>
          <div class="view-content">\(bodyThatQuotesTheMarker)</div>
        </article>
        <template data-dgst="BAILOUT_TO_CLIENT_SIDE_RENDERING"></template>
        </body></html>
        """
        XCTAssertTrue(try parser.parseDetail(html: html, post: post()).comments.isEmpty,
                      "형제 키 없는 인용은 디코드에 성공해도 인라인이 아니다")

        let api = #"{"status":"ETOCD200000","data":{"comments":[{"commentId":7,"parentId":null,"writeDateTimestamp":1,"recommendCount":0,"content":"API 댓글","isAnonymous":false,"member":{"nickname":"a"},"file":null,"childrenComments":[]}]}}"#
        let fetched = TestFlag()
        let comments = try await parser.fetchAllComments(for: post(), detailHTML: html) { _ in
            fetched.set()
            return api
        }
        XCTAssertTrue(fetched.value, "오탐 때문에 API 폴백을 건너뛰면 안 된다")
        XCTAssertEqual(comments.map(\.content), ["API 댓글"])
    }

    func testGenuinelyEmptyInlineListStillShortCircuits() async throws {
        // 진짜로 댓글 0개인 글은 인라인이 이긴 것 — 헛왕복 금지. 판정 근거는
        // 배열 바로 뒤의 pagination 형제 키(라이브 페이로드와 동일 배치).
        let html = inlineHTML(commentsKey: "commentList", comments: false)
        let comments = try await parser.fetchAllComments(for: post(), detailHTML: html) { _ in
            XCTFail("빈 인라인 배열도 인라인이 이긴 것")
            return ""
        }
        XCTAssertTrue(comments.isEmpty)
    }

    func testEmptyArrayQuotedInBodyAloneStillFallsBackToAPI() async throws {
        // 본문에 붙여넣어진 `\"commentList\":[]` 는 디코드는 되지만 flight
        // 페이로드가 아니다 — 형제 키가 없다. 이걸 "진짜 0개"로 받아들이면
        // SSR bailout 글의 댓글이 통째로 사라진다. (Codex 리뷰 P2 2차)
        let html = """
        <html><body>
        <article>
          <h1><span class="truncate">제목</span></h1>
          <div class="view-content"><p>응답이 {\\"commentList\\":[]} 로만 와요</p></div>
        </article>
        <template data-dgst="BAILOUT_TO_CLIENT_SIDE_RENDERING"></template>
        </body></html>
        """
        let api = #"{"status":"ETOCD200000","data":{"comments":[{"commentId":9,"parentId":null,"writeDateTimestamp":1,"recommendCount":0,"content":"진짜 댓글","isAnonymous":false,"member":{"nickname":"a"},"file":null,"childrenComments":[]}]}}"#
        let fetched = TestFlag()
        let comments = try await parser.fetchAllComments(for: post(), detailHTML: html) { _ in
            fetched.set()
            return api
        }
        XCTAssertTrue(fetched.value, "형제 키 없는 빈 배열은 인라인으로 인정하면 안 된다")
        XCTAssertEqual(comments.map(\.content), ["진짜 댓글"])
    }

    func testLegacyCommentsKeyFallsBackToAPI() async throws {
        // 옛 봉투(`\"data\":{\"comments\":[`)는 더 이상 인라인으로 안 친다 —
        // 라이브에 0건이고 검증된 앵커 샘플도 없어, 남기면 앵커 없는 오탐
        // 경로만 하나 더 생긴다. 이토랜드가 되돌리면 API 폴백이 받아낸다.
        let legacy = """
        <html><body>
        <article>
          <h1><span class="truncate">제목</span></h1>
          <div class="view-content"><p>본문</p></div>
        </article>
        <script>self.__next_f.push([1,"6:[\\"$\\",\\"$L32\\",null,{\\"data\\":{\\"comments\\":[{\\"commentId\\":1,\\"content\\":\\"옛 봉투\\",\\"member\\":{\\"nickname\\":\\"a\\"},\\"childrenComments\\":[]}]}}]"])</script>
        </body></html>
        """
        XCTAssertTrue(try parser.parseDetail(html: legacy, post: post()).comments.isEmpty)

        let api = #"{"status":"ETOCD200000","data":{"comments":[{"commentId":3,"content":"API 댓글","member":{"nickname":"a"}}]}}"#
        let fetched = TestFlag()
        let comments = try await parser.fetchAllComments(for: post(), detailHTML: legacy) { _ in
            fetched.set()
            return api
        }
        XCTAssertTrue(fetched.value, "옛 봉투는 폴백으로 넘어가야 한다")
        XCTAssertEqual(comments.map(\.content), ["API 댓글"])
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

/// `@Sendable` fetcher 클로저 안에서 "불렸다"를 기록하는 최소 플래그.
private final class TestFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()

    func set() {
        lock.lock()
        defer { lock.unlock() }
        flag = true
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
