import Foundation
import SwiftSoup
/// Parses bobaedream (보배드림) mobile detail pages. Reached exclusively via
/// aagag mirror redirects — bobaedream is not exposed as a directly-browsable
/// site. Replies to comments load asynchronously on the source site so the
/// initial HTML only exposes top-level comments; that's the full scope here.
public struct BobaeParser: BoardParser {
    public let site: Site = .bobae

    public nonisolated init() {}

    /// Matches the two shapes bobaedream renders for comment timestamps:
    /// `HH:MM` for same-day comments and `YYYY.MM.DD HH:MM` for older ones.
    /// Used to filter the util row's spans so an added badge / IP indicator
    /// doesn't silently replace the timestamp.
    nonisolated private static let commentTimeRegex = try! NSRegularExpression(
        pattern: #"\d{1,2}:\d{2}|\d{4}\.\d{1,2}\.\d{1,2}"#,
        options: []
    )

    public nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        // Bobaedream is aagag-dispatch-only; list parsing is never invoked.
        []
    }

    public nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        // Bobaedream signals deleted / invalid posts with a 200 response whose
        // body is literally a single `<script>alert('삭제된 글 입니다.');
        // history.back();</script>`. Detect that BEFORE parsing the DOM, so a
        // future article-wrapper rename doesn't make us misreport legitimate
        // posts as deleted (the body-wrapper check and the deletion check
        // used to share the same selector — coupling they don't need).
        if html.contains("alert('삭제된 글") || html.contains("alert(\"삭제된 글") {
            return PostDetail(
                post: post,
                blocks: [.text("삭제되거나 이동된 게시물입니다.")],
                fullDateText: nil,
                viewCount: nil,
                source: nil,
                comments: []
            )
        }

        let doc = try SwiftSoup.parse(html)

        let title = try extractTitle(in: doc, fallback: post.title)
        let author = try extractAuthor(in: doc, fallback: post.author)
        let fullDateText = try extractFullDate(in: doc)
        let recommend = try extractRecommend(in: doc)
        let viewCount = try extractViewCount(in: doc)
        let blocks = try extractBlocks(in: doc)
        let comments = try extractComments(in: doc)

        let updated = post.enrichedForDetail(
            title: title,
            author: author,
            viewCount: viewCount,
            recommendCount: recommend
        )

        return PostDetail(
            post: updated,
            blocks: blocks,
            fullDateText: fullDateText,
            viewCount: viewCount,
            source: nil,
            comments: comments
        )
    }

    // 댓글 페이지네이션은 detail HTML 안의 `comment_call` 파라미터로만 만들 수
    // 있어(테이블명 `uni_cmt_NNNN` 이 URL 에 없다), commentsURL 은 게이트 통과용
    // sentinel 로 post.url 만 돌려주고 실제 작업은 fetchAllComments 에서 한다.
    // Ppomppu / Ddanzi 와 동일한 구조.
    public nonisolated func commentsURL(for post: Post) -> URL? { post.url }

    /// 보배드림 모바일 detail 은 댓글 **마지막** 페이지(50개/페이지)만 inline 으로
    /// 렌더한다 — 그것만 읽으면 앞 페이지가 통째로 빠진다(61개 글 → 11개만). detail
    /// 의 `.page` 페이저에서 현재/총 페이지를 읽어, inline 을 실제 인덱스에 놓고
    /// 나머지 페이지를 `comment_call` AJAX 로 병렬 fetch 후 1..N 순서로 합친다.
    public nonisolated func fetchAllComments(
        for post: Post,
        detailHTML: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [PostComment] {
        // 호출부가 이미 받아둔 detail 본문을 재사용 — inline 첫 페이지가 그 안에
        // 있어 post.url 재요청은 중복 parse 일 뿐이다.
        let html: String
        if let detailHTML {
            html = detailHTML
        } else {
            html = try await fetcher(post.url)
        }
        let (info, inlinePage) = try parsedDocument(html) { doc -> ((current: Int, total: Int)?, [PostComment]) in
            let info = try commentPageInfo(in: doc)
            let inlinePage = try extractComments(in: doc, page: info?.current ?? 1)
            return (info, inlinePage)
        }

        // 페이저(`.page span.num`)가 없거나 1페이지면 inline 이 전부.
        guard let info, info.total > 1,
              let params = Self.commentCallParams(in: html)
        else { return inlinePage }

        // 병렬 fetch + 페이지 단위 실패 흡수 골격은 `mergeCommentPages` 참조.
        return try await mergeCommentPages(
            total: info.total, inlinePage: info.current, inline: inlinePage
        ) { page in
            guard let url = self.commentPageURL(params: params, page: page) else { return [] }
            let pageHTML = try await fetcher(url)
            return try self.parseCommentFragment(html: pageHTML, page: page)
        }
    }

    /// `comment_call('uni_cmt_2606','strange','6925135','strange','6925135',...)`
    /// 의 앞 5개 인자(테이블·게시판·글번호·원게시판·원글번호). 정렬/페이지 링크
    /// 어디서든 동일하게 나오므로 첫 매치만 쓴다.
    nonisolated private static let commentCallRegex = try! NSRegularExpression(
        pattern: #"comment_call\(\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*'([^']*)'"#,
        options: []
    )

    nonisolated private struct CommentCallParams {
        let selTb: String, mapCD: String, mapNO: String, ocode: String, ono: String
    }

    nonisolated private static func commentCallParams(in html: String) -> CommentCallParams? {
        let ns = html as NSString
        guard let m = commentCallRegex.firstMatch(
            in: html, range: NSRange(location: 0, length: ns.length)),
            m.numberOfRanges >= 6
        else { return nil }
        func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        return CommentCallParams(selTb: g(1), mapCD: g(2), mapNO: g(3), ocode: g(4), ono: g(5))
    }

    nonisolated private func commentPageURL(params: CommentCallParams, page: Int) -> URL? {
        // /board/comment_call/{selTb}/{mapCD}/{mapNO}/{ocode}/{ono}?page=N
        let path = "/board/comment_call/\(params.selTb)/\(params.mapCD)/\(params.mapNO)/\(params.ocode)/\(params.ono)"
        guard var comps = URLComponents(
            url: site.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "secondtime", value: "Y"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "strOrder", value: ""),
        ]
        return comps.url
    }

    /// 댓글 페이저에서 현재/총 페이지. 게시판 목록 페이저 등 다른 `.page` 와
    /// 구분하려고 `comment_call` 링크를 가진 `span.num` 만 본다. 현재 페이지는
    /// `a.on`, 총 페이지는 숫자 앵커 최댓값.
    nonisolated private func commentPageInfo(in doc: Document) throws -> (current: Int, total: Int)? {
        for span in try doc.select("div.page span.num") {
            let anchors = try span.select("a")
            let isCommentPager = try anchors.contains { try $0.attr("href").contains("comment_call") }
            guard isCommentPager else { continue }
            var nums: [Int] = []
            var current: Int?
            for a in anchors {
                let text = try a.text().trimmingCharacters(in: .whitespacesAndNewlines)
                guard let n = Int(text) else { continue }
                nums.append(n)
                if a.hasClass("on") { current = n }
            }
            // `a.on` 이 현재 페이지(=inline 으로 렌더된 페이지). 이게 없으면
            // 마크업이 바뀐 것이라 current 를 임의로 1 로 두면 inline(실제로는
            // 마지막 페이지)이 page 1 슬롯에 들어가 fetch 한 page 1 과 충돌하고
            // 순서가 깨진다. 그럴 땐 nil 을 돌려 inline-only 로 안전하게 내려간다
            // (수정 전 동작과 동일 — 더 나빠지지 않음).
            guard let current, let total = nums.max() else { continue }
            return (current, total)
        }
        return nil
    }

    // MARK: - Field extraction

    nonisolated private func extractTitle(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select("article.article h3.subject").first()?.text() ?? ""
        let cleaned = ParserText.cleanTitle(text)
        return cleaned.isEmpty ? fallback : cleaned
    }

    nonisolated private func extractAuthor(in doc: Document, fallback: String) throws -> String {
        // <div class="info"><span>작성자</span> <button>작성글보기</button></div>
        let text = try doc.select("article.article .util2 .info span").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    nonisolated private func extractFullDate(in doc: Document) throws -> String? {
        guard let el = try doc.select("article.article .util time").first() else { return nil }
        let date = try el.attr("datetime").trimmingCharacters(in: .whitespacesAndNewlines)
        let time = try el.text().trimmingCharacters(in: .whitespacesAndNewlines)
        // `<time datetime="2026-04-19">13:52</time>` → "2026-04-19 13:52"
        switch (date.isEmpty, time.isEmpty) {
        case (true, true): return nil
        case (false, true): return date
        case (true, false): return time
        case (false, false): return "\(date) \(time)"
        }
    }

    nonisolated private func extractRecommend(in doc: Document) throws -> Int? {
        // `<span class="data3">추천 183</span>`
        guard let el = try doc.select("article.article .util .data3").first() else { return nil }
        return ParserText.integerFromDigits(in: try el.text())
    }

    nonisolated private func extractViewCount(in doc: Document) throws -> Int? {
        // `<span class="data4">조회 10639</span>`
        guard let el = try doc.select("article.article .util .data4").first() else { return nil }
        return ParserText.integerFromDigits(in: try el.text())
    }

    // MARK: - Body blocks

    nonisolated private func extractBlocks(in doc: Document) throws -> [ContentBlock] {
        // Fallback chain for the body wrapper. Bobaedream currently renders
        // `.article-body` on mobile, but older posts / migrated articles /
        // subtle server-side A/B variants sometimes drop the wrapper and
        // expose `#body_frame` directly. Trying several candidates keeps a
        // single-class rename from silently returning an empty post body.
        let candidates: [Element?] = [
            try doc.select("article.article .article-body").first(),
            try doc.select(".article-body").first(),
            try doc.select("#body_frame").first(),
            try doc.select("article.article").first(),
        ]
        // None of the body-wrapper candidates matched. Deletion is handled
        // earlier in `parseDetail` (the alert-script check), so reaching here
        // with no wrapper means the markup changed — throw so the user sees
        // the "구조가 바뀐 것 같아요" signal instead of a silently blank post.
        guard let wrap = candidates.compactMap({ $0 }).first else {
            throw ParserError.structureChanged("article-body 없음")
        }

        // resolveImageURL / resolveVideoURL — 둘 다 standard(for:) 기본값이
        // Bobae 의 옛 로컬 헬퍼(realImageURL / videoURL) 와 동일한 동작
        // (data-src 폴백 + `#t=` fragment strip) 을 제공하므로 override 불필요.
        let rules = WalkerRules.standard(for: self)
        return try ParserBlockWalker(parser: self, rules: rules).walk(wrap)
    }

    // MARK: - Comments

    nonisolated private func extractComments(in doc: Document, page: Int = 1) throws -> [PostComment] {
        // Bobaedream's comment markup:
        //   <div class="reple_body"><ul class="list">
        //     <li class="best"> ... </li>      (top-voted, duplicated in normal list)
        //     <li> <div class="ico_area">댓글</div> ... </li>   (reply to above)
        //     <li> ... </li>                                     (top-level comment)
        //     <div id="re_NNNN"></div>                           (empty AJAX slot for login-gated reply inserts)
        //
        // Replies inherit the same <li> shape as top-level comments and are
        // server-rendered inline — the only structural marker that flags a
        // reply is the leading `<div class="ico_area">댓글</div>` badge.
        // Best entries are a duplicated preview of top-voted items from the
        // main list; skip them so we don't render each one twice.
        return try parseCommentNodes(doc.select(".reple_body > ul.list > li"), page: page)
    }

    /// `comment_call` AJAX 응답은 `.reple_body` 래퍼 없이 `ul.list > li` 만 싣는다.
    /// (detail 페이지의 메뉴 등 다른 `ul.list` 와 섞일 일이 없는 fragment 이므로
    /// 셀렉터를 느슨하게 써도 안전하다.)
    nonisolated private func parseCommentFragment(html: String, page: Int) throws -> [PostComment] {
        try parsedDocument(html) { doc in
            try parseCommentNodes(doc.select("ul.list > li"), page: page)
        }
    }

    /// `page` 는 id 없는 댓글의 synthetic id(`idx{n}`)에 섞어 페이지 간 충돌을
    /// 막는다 — 페이지마다 enumerate idx 가 0 부터 다시 시작하므로, page 를 안
    /// 섞으면 서로 다른 페이지의 id 없는 두 댓글이 같은 id 를 받아 SwiftUI
    /// ForEach 키가 충돌한다(멀티페이지 병합 후 발생).
    nonisolated private func parseCommentNodes(_ nodes: Elements, page: Int) throws -> [PostComment] {
        var results: [PostComment] = []
        for (idx, li) in nodes.enumerated() {
            // `.best` entries are a duplicated preview of top-voted comments
            // from the main list — skip them so we don't render each twice.
            // Use hasClass for an exact token match: substring matching would
            // eat future adjacent class names that happen to contain "best"
            // (e.g. `text_best`, `bestreple`).
            if li.hasClass("best") { continue }

            guard let replyEl = try li.select(".con_area > .reply").first() else { continue }
            // Replies carry a leading `<div class="ico_area">댓글</div>` badge
            // the source site renders inline. Match any `.ico_area` descendant
            // (not strictly the direct child) and verify its text so we don't
            // false-positive on a similarly-named container if bobae adds one.
            let isReply: Bool = try {
                for el in try li.select(".ico_area") {
                    if try el.text().contains("댓글") { return true }
                }
                return false
            }()
            let content = try extractCommentContent(replyEl)

            let utilEl = try li.select(".con_area > .util").first()
            let author = try utilEl?.select(".data4").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let dateText = try extractCommentDate(utilEl)
            let likeCount = try extractCommentLikes(in: li)
            let stickerURL = extractCommentSticker(in: replyEl)
            let cmtID = extractCommentID(from: li) ?? "p\(page)idx\(idx)"

            guard !author.isEmpty || !content.isEmpty || stickerURL != nil
            else { continue }

            results.append(PostComment(
                id: "\(site.rawValue)-c-\(cmtID)",
                author: author,
                dateText: dateText,
                content: content,
                likeCount: likeCount,
                isReply: isReply,
                stickerURL: stickerURL,
                videoURL: nil,
                authIconURL: nil,
                levelIconURL: nil
            ))
        }
        return results
    }

    nonisolated private func extractCommentContent(_ replyEl: Element) throws -> String {
        guard let copy = replyEl.copy() as? Element else { return "" }
        // Strip the "베플" (best comment) badge and any inline images so the
        // text reads cleanly, then flatten through the shared pipeline.
        // `<br>` line breaks must go through the blockMarker sentinel —
        // inserting a literal "\n" TextNode doesn't survive `.text()`'s
        // whitespace collapse (newlines flattened to a single space).
        try copy.select(".ico3, img, script, style").remove()
        return renderCommentText(from: copy)
    }

    nonisolated private func extractCommentDate(_ util: Element?) throws -> String {
        // `<div class="util"><span class="data4">author</span><span>14:12</span>...`
        // The time is the bare-span sibling between the author (`.data4`) and
        // the report anchor. Picking "the first non-author, non-anchor span"
        // is brittle — if bobae ever slots an IP / level / badge span in
        // between, we'd display that text as the timestamp. Match against the
        // expected HH:MM or date shape so a new span with other content gets
        // skipped over instead of silently winning.
        guard let util else { return "" }
        for span in try util.select("span") {
            let cls = try span.attr("class")
            if cls.contains("data4") { continue }
            if try !span.select("a").isEmpty() { continue }
            let text = try span.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let ns = text as NSString
            if Self.commentTimeRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
                return text
            }
        }
        return ""
    }

    nonisolated private func extractCommentLikes(in li: Element) throws -> Int {
        // `<div class="util3"><button class="good">37</button><button class="bad">1</button>`
        guard let good = try li.select(".util3 .good").first() else { return 0 }
        return ParserText.integerFromDigits(in: try good.text()) ?? 0
    }

    /// Comment images — bobaedream renders attached images inline within the
    /// .reply div. Strip loading / icon chrome the same way humor does.
    nonisolated private func extractCommentSticker(in replyEl: Element) -> URL? {
        firstImageURL(
            in: replyEl,
            attributes: ["data-original", "data-src", "src"],
            skipMarkers: ["loading", "/icon", "/images/ic"]
        )
    }

    nonisolated private func extractCommentID(from li: Element) -> String? {
        // Bobaedream doesn't put the comment id on the <li> — it lives on a
        // sibling `#repl_NNNN` input or in the onclick `cmt_ok('xxx', 'NNNN', ...)`.
        // Prefer the `repl_` input since it's stable and present on every
        // comment.
        if let input = try? li.select("[id^=repl_length_]").first(),
           let id = try? input.attr("id"),
           id.hasPrefix("repl_length_") {
            return String(id.dropFirst("repl_length_".count))
        }
        if let div = try? li.select("[id^=repl_]").first(),
           let id = try? div.attr("id"),
           id.hasPrefix("repl_") {
            let rest = id.dropFirst("repl_".count)
            if rest.allSatisfy(\.isNumber) { return String(rest) }
        }
        return nil
    }
}
