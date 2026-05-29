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
            let notice: String
            if body.contains("삭제") || body.contains("존재하지") || body.contains("접근") {
                notice = "삭제되거나 이동된 게시물입니다."
            } else {
                notice = "게시물을 불러올 수 없습니다."
            }
            return PostDetail(
                post: post,
                blocks: [.text(notice)],
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

        let updated = Post(
            id: post.id,
            site: post.site,
            boardID: post.boardID,
            title: title,
            author: author,
            date: post.date,
            dateText: post.dateText,
            commentCount: post.commentCount,
            url: post.url,
            viewCount: viewCount ?? post.viewCount,
            recommendCount: recommend ?? post.recommendCount,
            levelText: post.levelText,
            hasAuthIcon: post.hasAuthIcon
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
        guard let params = try Self.extractCommentParams(html: html) else {
            return []
        }

        // 2) XE `exec_json` is a quirk: the JS library sets the request's
        //    `Content-Type` to `application/json` but still sends the params
        //    URL-encoded in the body. The server-side handler branches on
        //    the `Content-Type` header to decide whether to emit JSON or
        //    render the full HTML layout — so sending
        //    `x-www-form-urlencoded` returns the login / view page instead
        //    of the JSON payload we need here.
        let data = try await Networking.postForm(
            url: site.baseURL,
            parameters: [
                "module": "board",
                "act": "dispBoardContentCommentListHtml",
                "mid": params.mid,
                "document_srl": params.documentSrl,
                "cpage": "0",
            ],
            referer: post.url,
            contentType: "application/json"
        )

        return decodeComments(data: data)
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
        let raw = try el.text().filter(\.isNumber)
        return raw.isEmpty ? nil : Int(raw)
    }

    nonisolated private func extractRecommend(in doc: Document) throws -> Int? {
        // `.sum .voteWrap .vote` contains the `icon_good.png` img plus count.
        guard let el = try doc.select(".boardR .meta .voteWrap .vote").first() else { return nil }
        let raw = try el.text().filter(\.isNumber)
        return raw.isEmpty ? nil : Int(raw)
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

    nonisolated private static func extractCommentParams(html: String) throws -> CommentParams? {
        let doc = try SwiftSoup.parse(html)
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

    nonisolated private func decodeComments(data: Data) -> [PostComment] {
        guard let payload = try? JSONDecoder().decode(CommentResponse.self, from: data),
              let fragment = payload.commentHtml,
              !fragment.isEmpty
        else { return [] }

        do {
            let doc = try SwiftSoup.parseBodyFragment(fragment)
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

                let content = try renderCommentContent(in: li)
                let sticker = extractCommentSticker(in: li)

                if author.isEmpty, content.isEmpty, sticker == nil { continue }

                results.append(PostComment(
                    id: "ddanzi-c-\(cmtID)",
                    author: author,
                    dateText: dateText,
                    content: content,
                    likeCount: 0,
                    isReply: isReply,
                    stickerURL: sticker
                ))
            }
            return results
        } catch {
            return []
        }
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
