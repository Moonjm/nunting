import XCTest
@testable import nunting

/// 뽐뿌가 댓글을 서버렌더 HTML(`div.cmAr div.sect-cmt`)에서 per-page JSON
/// 엔드포인트(`ajax_bbs_comment.php?cmd=get_comment_json`)로 옮긴 뒤, 옛 HTML
/// 스크레이퍼가 빈 배열만 반환하던 회귀(댓글이 아예 안 보임)를 막는다. 새
/// 경로의 페이지네이션·병합·실패흡수·매핑을 JSON fixture 로 고정한다.
final class PpomppuCommentPaginationTests: XCTestCase {
    /// 병렬 task group 의 fetcher 가 어떤 URL 을 요청했는지 thread-safe 하게 기록
    /// (자식 task 들이 동시에 append 하므로 plain Array 는 race).
    private actor RequestRecorder {
        private(set) var urls: [URL] = []
        func add(_ u: URL) { urls.append(u) }
    }

    /// 최소 `get_comment_json` 페이지. content-only 댓글을 `no` 오름차순으로 싣는다.
    private static func jsonPage(totalPage: Int, comments: [(no: Int, content: String)]) -> String {
        let items = comments.map { c in
            #"{"no":\#(c.no),"depth":0,"name":"<b>글쓴이</b>","memo":"<p>\#(c.content)</p>","vote_btn":{"vote_count":0},"meta":{"time_display":"2026-07-01 10:00"}}"#
        }.joined(separator: ",")
        return #"{"comments":[\#(items)],"total_page":\#(totalPage),"c_page":1}"#
    }

    private static func cpage(of url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c_page" })?.value ?? "?"
    }

    private func post(no: Int) -> Post {
        Post.fixture(
            id: "freeboard-\(no)", site: .ppomppu, boardID: "freeboard",
            url: URL(string: "https://m.ppomppu.co.kr/new/bbs_view.php?id=freeboard&no=\(no)")!)
    }

    func testMultiPageFetchesEveryPageAndMergesInOrder() async throws {
        let parser = PpomppuParser()
        let recorder = RequestRecorder()
        let comments = try await parser.fetchAllComments(for: post(no: 1), detailHTML: nil) { url in
            await recorder.add(url)
            switch Self.cpage(of: url) {
            case "1": return Self.jsonPage(totalPage: 3, comments: [(1, "p1")])
            case "2": return Self.jsonPage(totalPage: 3, comments: [(2, "p2")])
            case "3": return Self.jsonPage(totalPage: 3, comments: [(3, "p3")])
            default: return Self.jsonPage(totalPage: 3, comments: [])
            }
        }

        XCTAssertEqual(comments.map(\.content), ["p1", "p2", "p3"], "1→N 순서로 병합")
        XCTAssertEqual(Set(comments.map(\.id)).count, 3, "중복 댓글 없어야 함")

        let requested = await recorder.urls
        // 옛 방식과 달리 detailHTML 재사용이 없다 — page 1 도 JSON 으로 fetch.
        XCTAssertEqual(Set(requested.map(Self.cpage(of:))), ["1", "2", "3"])
        // 모든 요청이 sort_asc JSON 엔드포인트로 나가고, id/no 를 post.url 에서 뽑는다.
        for url in requested {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            XCTAssertEqual(url.lastPathComponent, "ajax_bbs_comment.php")
            XCTAssertEqual(comps?.queryItems?.first(where: { $0.name == "cmd" })?.value, "get_comment_json")
            XCTAssertEqual(comps?.queryItems?.first(where: { $0.name == "comment_mode" })?.value, "sort_asc")
            XCTAssertEqual(comps?.queryItems?.first(where: { $0.name == "id" })?.value, "freeboard")
            XCTAssertEqual(comps?.queryItems?.first(where: { $0.name == "no" })?.value, "1")
        }
    }

    func testSinglePageFetchesOnlyPageOne() async throws {
        let parser = PpomppuParser()
        let recorder = RequestRecorder()
        let comments = try await parser.fetchAllComments(for: post(no: 2), detailHTML: nil) { url in
            await recorder.add(url)
            return Self.jsonPage(totalPage: 1, comments: [(10, "only")])
        }
        XCTAssertEqual(comments.map(\.content), ["only"])
        let requested = await recorder.urls
        XCTAssertEqual(requested.map(Self.cpage(of:)), ["1"], "단일 페이지는 page1 만 fetch")
    }

    /// 한 페이지 fetch 가 throw 해도 나머지는 살아야 한다 — throwing group 이던
    /// 시절엔 단일 실패가 그룹 전체를 취소시켜 멀쩡한 페이지까지 사라졌다.
    func testPageFetchFailureIsAbsorbedAndOtherPagesSurvive() async throws {
        struct PageError: Error {}
        let parser = PpomppuParser()
        let comments = try await parser.fetchAllComments(for: post(no: 4), detailHTML: nil) { url in
            switch Self.cpage(of: url) {
            case "1": return Self.jsonPage(totalPage: 3, comments: [(1, "p1")])
            case "2": throw PageError()
            case "3": return Self.jsonPage(totalPage: 3, comments: [(3, "p3")])
            default: return Self.jsonPage(totalPage: 3, comments: [])
            }
        }
        XCTAssertEqual(comments.map(\.content), ["p1", "p3"], "page2 만 빠지고 1·3 은 순서 보존")
    }

    /// 0-comment 글은 `{"comments":[],"total_page":0}` 을 반환한다 — throw 하면
    /// 로드된 글에 "댓글 로드 실패" 배너가 뜬다. 빈 배열로 조용히 끝나야 한다.
    func testEmptyThreadYieldsNoCommentsWithoutThrowing() async throws {
        let parser = PpomppuParser()
        let comments = try await parser.fetchAllComments(for: post(no: 5), detailHTML: nil) { _ in
            #"{"comments":[],"total_page":0,"c_page":1,"total_comment":0}"#
        }
        XCTAssertTrue(comments.isEmpty)
    }

    /// JSON → PostComment 매핑: name/ memo HTML flatten, vote_count, time_display,
    /// depth>0=isReply, 그리고 lazy-load 스티커 img 는 stickerURL 로 추출된다.
    /// 대댓글은 부모의 `sub_cmt` 안에 들어오므로, 실제 응답 shape 대로 중첩시킨다.
    func testDecodeMapsFieldsAndExtractsSticker() throws {
        let json = #"""
        {"comments":[
          {"no":100,"depth":0,"name":"<b><a href=\"#\"><i class=\"nlevel lv4\"></i>영희</a></b>","memo":"<p>안녕하세요</p>","vote_btn":{"vote_count":7},"meta":{"time_display":"2026-07-01 16:36"},
           "sub_cmt":[
             {"no":101,"depth":1,"name":"<b>철수</b>","memo":"<img src=\"/images/lazyloading.jpg\" data-original=\"https://cdn2.ppomppu.co.kr/sticker/emo.gif\">","vote_btn":{"vote_count":0},"meta":{"time_display":"2026-07-01 16:40"}}
           ]}
        ],"total_page":1,"c_page":1}
        """#
        let comments = try PpomppuParser().parseCommentPage(json).comments
        XCTAssertEqual(comments.count, 2, "부모 + sub_cmt 대댓글")

        let first = comments[0]
        XCTAssertEqual(first.author, "영희")
        XCTAssertEqual(first.content, "안녕하세요")
        XCTAssertEqual(first.likeCount, 7)
        XCTAssertEqual(first.dateText, "2026-07-01 16:36")
        XCTAssertFalse(first.isReply)
        XCTAssertNil(first.stickerURL)

        let reply = comments[1]
        XCTAssertEqual(reply.author, "철수")
        XCTAssertTrue(reply.isReply, "depth>0 은 대댓글")
        XCTAssertTrue(reply.content.isEmpty, "스티커만 있는 댓글은 본문 비어야")
        XCTAssertEqual(reply.stickerURL?.absoluteString, "https://cdn2.ppomppu.co.kr/sticker/emo.gif")
    }

    /// 뽐뿌 대댓글은 부모 댓글의 `sub_cmt` 배열에 **재귀적으로** 중첩된다(대댓글의
    /// 대댓글까지). 실측: id=car&no=971984 은 top 82 + sub 32 + sub-of-sub 13 = 127.
    /// 평탄화가 없으면 앱은 top-level 만(82) 보여준다 — 이 회귀를 고정한다.
    func testNestedSubCommentsAreFlattenedPreOrder() throws {
        let json = #"""
        {"comments":[
          {"no":1,"depth":0,"name":"<b>A</b>","memo":"<p>a</p>","meta":{"time_display":"t"},
           "sub_cmt":[
             {"no":2,"depth":1,"name":"<b>B</b>","memo":"<p>b</p>","meta":{"time_display":"t"},
              "sub_cmt":[
                {"no":3,"depth":2,"name":"<b>C</b>","memo":"<p>c</p>","meta":{"time_display":"t"},"sub_cmt":null}
              ]},
             {"no":4,"depth":1,"name":"<b>D</b>","memo":"<p>d</p>","meta":{"time_display":"t"},"sub_cmt":null}
           ]},
          {"no":5,"depth":0,"name":"<b>E</b>","memo":"<p>e</p>","meta":{"time_display":"t"},"sub_cmt":null}
        ],"total_page":1,"c_page":1}
        """#
        let comments = try PpomppuParser().parseCommentPage(json).comments
        // pre-order: 부모 → 그 대댓글 서브트리 → 다음 형제.
        XCTAssertEqual(comments.map(\.content), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(comments.map(\.isReply), [false, true, true, true, false])
    }

    /// 개별 댓글이 깨져도(예: `no` 누락) 페이지 전체가 아니라 그 행만 드롭돼야 한다 —
    /// 한 행 파싱 실패로 "댓글 로드 실패" 배너가 뜨면 안 된다.
    func testMalformedCommentIsDroppedNotWholePage() throws {
        let json = #"""
        {"comments":[
          {"no":1,"depth":0,"name":"<b>A</b>","memo":"<p>ok</p>","meta":{"time_display":"t"}},
          {"depth":0,"name":"<b>X</b>","memo":"<p>no-id</p>","meta":{"time_display":"t"}},
          {"no":"3","depth":0,"name":"<b>C</b>","memo":"<p>string-id</p>","meta":{"time_display":"t"}}
        ],"total_page":1,"c_page":1}
        """#
        let comments = try PpomppuParser().parseCommentPage(json).comments
        // no 없는 행만 빠지고, 문자열 no("3") 는 허용된다.
        XCTAssertEqual(comments.map(\.content), ["ok", "string-id"])
        XCTAssertEqual(comments.last?.id, "ppomppu-c-3")
    }
}
