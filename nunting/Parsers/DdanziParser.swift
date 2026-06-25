import Foundation
import SwiftSoup
/// Parses 딴지일보 (Ddanzi) mobile detail pages. Reached exclusively via
/// aagag mirror redirects — Ddanzi is not exposed as a directly-browsable
/// site.
///
/// Ddanzi runs on XpressEngine (XE). The detail page renders title/meta/body
/// inline but leaves `<div id="cmt_list">` empty; the comment HTML arrives
/// through an XE `exec_json` POST to the site root with
/// `module=board&act=dispBoardContentCommentListHtml`. `fetchAllComments`
/// posts that endpoint and parses the returned `commentHtml` fragment.
public struct DdanziParser: BoardParser {
    public let site: Site = .ddanzi

    public nonisolated init() {}

    /// Comment-render helper `walk` 가 사용. 본문 추출은 `ParserBlockWalker`
    /// 가 자체 blockTags 를 들고 있어서 본문 측에서는 참조 안 함.
    nonisolated private static let blockTags: Set<String> = [
        "p", "div", "li", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "tr",
    ]

    public nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        // Ddanzi is aagag-dispatch-only; list parsing is never invoked.
        []
    }

    public nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)

        // Deleted posts replace the boardR wrapper with an error notice.
        if try doc.select(".boardR").isEmpty() {
            let body = try doc.text()
            // Deletion/relocation is a valid response — show a notice. Any
            // other reason `.boardR` is gone means the markup changed; throw
            // so the user sees the "구조가 바뀐 것 같아요" signal instead of a
            // silently blank post.
            guard body.contains("삭제") || body.contains("존재하지") || body.contains("접근") else {
                throw ParserError.structureChanged("boardR 없음")
            }
            return PostDetail(
                post: post,
                blocks: [.text("삭제되거나 이동된 게시물입니다.")],
                fullDateText: nil,
                viewCount: nil,
                source: nil,
                comments: []
            )
        }

        let title = try extractTitle(in: doc, fallback: post.title)
        let author = try extractAuthor(in: doc, fallback: post.author)
        let dateText = try extractDate(in: doc)
        let viewCount = try extractViewCount(in: doc)
        let recommend = try extractRecommend(in: doc)
        let blocks = try extractBlocks(in: doc)

        let updated = post.enrichedForDetail(
            title: title,
            author: author,
            viewCount: viewCount,
            recommendCount: recommend
        )

        return PostDetail(
            post: updated,
            blocks: blocks,
            fullDateText: dateText,
            viewCount: viewCount,
            source: nil,
            comments: [] // filled in by fetchAllComments
        )
    }

    /// Return the detail URL as a sentinel so `PostDetailView` invokes
    /// `fetchAllComments`. We need the detail HTML anyway to read
    /// `_document_srl` and `current_mid`, so reusing the injected fetcher
    /// keeps the dispatch pipeline consistent with other parsers.
    public nonisolated func commentsURL(for post: Post) -> URL? { post.url }

    public nonisolated func fetchAllComments(
        for post: Post,
        detailHTML: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [PostComment] {
        // 1) Detail HTML tells us mid + document_srl. URL-based parsing is
        //    brittle (some posts use the `/{srl}` shortcut without a mid),
        //    so read both from the rendered detail page. Caller threads
        //    through the already-fetched body when it has one, so we
        //    skip the redundant URLCache hit + SwiftSoup parse.
        let html: String
        if let detailHTML {
            html = detailHTML
        } else {
            html = try await fetcher(post.url)
        }
        guard let params = try parsedDocument(html, Self.extractCommentParams(in:)) else {
            return []
        }

        // 2) 댓글은 XE 기본 100개/페이지로 페이지네이션된다. `cpage=0` 은 XE 가
        //    "마지막 페이지(최신)"로 해석하므로 그것만 받으면 100개 넘는 글에서
        //    앞 페이지가 통째로 빠진다. 1페이지를 받아 `_page_no`(총 페이지 수)를
        //    읽고, 나머지(2..N)를 병렬로 받아 시간순(1..N)으로 합친다. ppomppu
        //    파서의 댓글 페이지네이션과 동일한 구조.
        let firstData = try await fetchCommentPage(params: params, cpage: 1, referer: post.url)
        let firstPage = decodeComments(data: firstData)
        let totalPages = min(decodeCommentPageCount(data: firstData), Self.maxCommentPages)
        if totalPages <= 1 { return firstPage }

        // 병렬 fetch + 페이지 단위 실패 흡수 골격은 `mergeCommentPages` 참조.
        return try await mergeCommentPages(
            total: totalPages, inlinePage: 1, inline: firstPage
        ) { page in
            let data = try await self.fetchCommentPage(
                params: params, cpage: page, referer: post.url)
            return self.decodeComments(data: data)
        }
    }

    /// 댓글 페이지 fetch 상한(무한 루프/이상 응답 방어). 100개/페이지 기준
    /// ~5천 댓글이라 실제 딴지 글은 한참 못 미친다.
    nonisolated private static let maxCommentPages = 50

    /// XE `exec_json` 댓글 목록 POST. JS 라이브러리가 `Content-Type` 을
    /// `application/json` 으로 보내면서도 body 는 URL-encoded 로 싣는 quirk가
    /// 있어, 서버가 헤더로 JSON/HTML 분기를 한다 — `x-www-form-urlencoded` 로
    /// 보내면 로그인/뷰 페이지가 돌아온다. `contentType` 오버라이드로 회피.
    nonisolated private func fetchCommentPage(
        params: CommentParams, cpage: Int, referer: URL
    ) async throws -> Data {
        try await Networking.postForm(
            url: site.baseURL,
            parameters: [
                "module": "board",
                "act": "dispBoardContentCommentListHtml",
                "mid": params.mid,
                "document_srl": params.documentSrl,
                "cpage": String(cpage),
            ],
            referer: referer,
            contentType: "application/json"
        )
    }

    // MARK: - Field extraction

    nonisolated private func extractTitle(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select(".boardR .top_title h1").first()?.text() ?? ""
        let cleaned = ParserText.cleanTitle(text)
        return cleaned.isEmpty ? fallback : cleaned
    }

    nonisolated private func extractAuthor(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select(".boardR .top_title .right .author").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    nonisolated private func extractDate(in doc: Document) throws -> String? {
        let text = try doc.select(".boardR .top_title .right .time").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    nonisolated private func extractViewCount(in doc: Document) throws -> Int? {
        guard let el = try doc.select(".boardR .meta .sum .read").first() else { return nil }
        return ParserText.integerFromDigits(in: try el.text())
    }

    nonisolated private func extractRecommend(in doc: Document) throws -> Int? {
        // `.sum .voteWrap .vote` contains the `icon_good.png` img plus count.
        guard let el = try doc.select(".boardR .meta .voteWrap .vote").first() else { return nil }
        return ParserText.integerFromDigits(in: try el.text())
    }

    // MARK: - Body blocks

    nonisolated private func extractBlocks(in doc: Document) throws -> [ContentBlock] {
        guard let wrap = try doc.select(".read_content .xe_content").first() else { return [] }
        // 옛 Ddanzi `<a>` 처리는 `el.select("img, video")` 만 검사해 iframe
        // wrap 케이스를 drop 했지만, walker standard 는 iframe 포함이라
        // `<a><iframe src=youtube/embed/…></a>` 이 YouTube embed 블록으로
        // 새로 surface 됨. 다른 6개 마이그된 파서(Bobae/Ppomppu/Etoland/
        // Clien/Inven/Humor) 와 동일한 동작 — 의도된 개선.
        let rules = WalkerRules.standard(for: self)
        return try ParserBlockWalker(parser: self, rules: rules).walk(wrap)
    }

    // MARK: - Comment AJAX params

    nonisolated private struct CommentParams {
        let mid: String
        let documentSrl: String
    }

    nonisolated private static func extractCommentParams(in doc: Document) throws -> CommentParams? {
        // Bail if the article body is missing — ddanzi's login-required /
        // private-post error pages still ship with widgets that include
        // a `#_document_srl` input and a `#cmt_list` target (for the login
        // redirect flow), so reading the params from such a page would fire
        // a garbage POST. Gating on the article wrapper keeps param
        // extraction scoped to real detail responses.
        guard try !doc.select(".boardR").isEmpty() else { return nil }
        // `<input id="_document_srl" value="..." />` lives inside the comment
        // section wrapper; it's the canonical document id Ddanzi uses.
        let docSrl = try doc.select("#_document_srl").first()?.attr("value")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // `<div id="cmt_list" data-mid="..."></div>` carries the board mid;
        // mid also appears in a `current_mid` JS var — prefer the DOM attr
        // so we don't have to text-scan for it.
        let mid = try doc.select("#cmt_list").first()?.attr("data-mid")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !docSrl.isEmpty, !mid.isEmpty else { return nil }
        return CommentParams(mid: mid, documentSrl: docSrl)
    }

    // MARK: - Comment HTML decoding

    /// Ddanzi returns `{"error":0,"commentHtml":"<ul>...<li id=\"comment_NNN\" …"}`
    /// wrapped in JSON. Each `<li>` is either a top-level comment or a
    /// `.re_comment` reply.
    ///
    /// Comment shape:
    /// ```
    /// <li id="comment_879247979" style="padding-left:10px">
    ///   <div class="fbItem">
    ///     <div class="fbMeta">
    ///       <h4 class="author"><a>닉네임</a></h4>
    ///       <p class="time">14:53:30</p>
    ///     </div>
    ///     <div class="fdComment">
    ///       <div class="... xe_content">내용<br>…</div>
    ///     </div>
    ///   </div>
    /// </li>
    /// <li id="comment_NNN" class="re_comment" style="padding-left:20px">…</li>
    /// ```
    nonisolated private struct CommentResponse: Decodable {
        let commentHtml: String?
    }

    // internal(테스트 접근용): 실제 commentHtml JSON 으로 디코딩 로직 검증.
    nonisolated func decodeComments(data: Data) -> [PostComment] {
        guard let payload = try? JSONDecoder().decode(CommentResponse.self, from: data),
              let fragment = payload.commentHtml,
              !fragment.isEmpty
        else { return [] }

        do {
            return try parsedBodyFragment(fragment) { doc -> [PostComment] in
                let body = doc.body() ?? doc
                let items = try body.select("li[id^=comment_]")

                var results: [PostComment] = []
                for li in items {
                    let cmtID = try li.attr("id")
                        .replacingOccurrences(of: "comment_", with: "")
                    // Exact token match via hasClass — substring `.contains`
                    // would false-positive on future adjacent class names that
                    // happen to carry "re_comment" as a prefix/suffix (e.g.
                    // `re_comment_deleted`) and render a normal comment as an
                    // indented reply.
                    let isReply = li.hasClass("re_comment")

                    let author = try li.select(".fbMeta .author").first()?.text()
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let dateText = try li.select(".fbMeta .time").first()?.text()
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    // 답글 대상 닉네임은 `.re_com_nickname`("@대상") 에 있다. content
                    // 에서는 (중복 방지로) 떼어내지만, 구조화 필드로 넘겨 뷰가 뽐뿌·SLR
                    // 과 동일한 파란 @대상 으로 렌더한다. 앞의 "@" 는 뷰가 다시 붙이므로 제거.
                    let rawTarget = (try? li.select(".re_com_nickname").first()?.text())?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let target = rawTarget.hasPrefix("@") ? String(rawTarget.dropFirst()) : rawTarget

                    let content = try renderCommentContent(in: li)
                    let sticker = extractCommentSticker(in: li)

                    if author.isEmpty, content.isEmpty, sticker == nil, target.isEmpty { continue }

                    results.append(PostComment(
                        id: "ddanzi-c-\(cmtID)",
                        author: author,
                        dateText: dateText,
                        content: content,
                        likeCount: 0,
                        isReply: isReply,
                        replyTarget: target.isEmpty ? nil : target,
                        stickerURL: sticker
                    ))
                }
                return results
            }
        } catch {
            return []
        }
    }

    /// 댓글 fragment 에서 총 댓글 페이지 수를 읽는다. XE 가 심는 hidden
    /// `<input id="_page_no">` 가 현재 페이지와 무관한 **절대 총 페이지 수**라
    /// (cpage=1·2 양쪽에서 동일) 윈도잉되는 `.pagination .number` nav 보다
    /// 신뢰도가 높아 우선한다. `_page_no` 가 없으면 `.number` 앵커 최대값으로
    /// 폴백, 그마저 없으면 1(단일 페이지). internal: 테스트 접근용.
    nonisolated func decodeCommentPageCount(data: Data) -> Int {
        guard let payload = try? JSONDecoder().decode(CommentResponse.self, from: data),
              let fragment = payload.commentHtml, !fragment.isEmpty
        else { return 1 }

        return (try? parsedBodyFragment(fragment) { doc -> Int in
            let body = doc.body() ?? doc

            if let raw = try? body.select("#_page_no").first()?.attr("value"),
               let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), n >= 1 {
                return n
            }
            // 폴백: pagination 의 페이지 번호 앵커 최대값(active 도 `.number` 클래스를
            // 같이 가져 함께 잡힌다). 윈도잉되면 과소집계될 수 있으나 _page_no 부재 시
            // 차선책 — 그래도 "마지막 페이지만" 보다는 낫다.
            if let anchors = try? body.select(".pagination a.number"),
               let maxN = anchors.compactMap({ Int((try? $0.text()) ?? "") }).max(), maxN >= 1 {
                return maxN
            }
            return 1
        }) ?? 1
    }

    /// Pull the first inline image out as a sticker URL so the comment
    /// renders as `[text] + image` the same way other parsers do.
    nonisolated private func extractCommentSticker(in li: Element) -> URL? {
        firstImageURL(
            in: li,
            selector: ".fdComment .xe_content img",
            attributes: ["src", "data-src"]
        )
    }

    /// SwiftSoup's `.text()` normalises whitespace to a single space, so a
    /// raw `<br>` becomes no visible line break. Walk the DOM manually to
    /// preserve `<br>` as `\n` and collapse the result. Also strips
    /// `.re_com_nickname` (the "@targetUser" prefix bubble) from the text
    /// — leaving it in duplicates information the reply indentation already
    /// communicates, and makes every reply look like it starts with `@…`.
    nonisolated private func renderCommentContent(in li: Element) throws -> String {
        guard let content = try li.select(".fdComment .xe_content").first() else { return "" }
        guard let copy = content.copy() as? Element else { return "" }
        try copy.select(".re_com_nickname, img, script, style").remove()
        // Preserve anchors as tappable markdown links — `walk()` below
        // recurses through anchors as plain elements and drops their hrefs.
        convertAnchorsToMarkdown(in: copy)

        var output = ""
        try Self.walk(copy, into: &output)
        let trimmed = output
            // Raw text-node content leaks the source's pretty-print
            // indentation (`"\n    "` between block children) into the
            // rendered text. Strip spaces/tabs around every newline.
            .replacingOccurrences(
                of: #"[ \t]*\n[ \t]*"#,
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    nonisolated private static func walk(_ element: Element, into output: inout String) throws {
        for node in element.getChildNodes() {
            if let text = node as? TextNode {
                output += text.text()
            } else if let el = node as? Element {
                let tag = el.tagName().lowercased()
                switch tag {
                case "br":
                    output += "\n"
                case "img", "script", "style":
                    continue
                default:
                    try walk(el, into: &output)
                    if blockTags.contains(tag) {
                        output += "\n"
                    }
                }
            }
        }
    }
}
