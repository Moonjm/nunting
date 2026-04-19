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
struct DdanziParser: BoardParser {
    let site: Site = .ddanzi

    nonisolated init() {}

    private static let blockTags: Set<String> = [
        "p", "div", "li", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "tr",
    ]
    private static let skipTags: Set<String> = ["script", "style", "noscript"]

    private static let youtubeIDRegex = try! NSRegularExpression(
        pattern: #"youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})"#,
        options: []
    )

    func parseList(html: String, board: Board) throws -> [Post] {
        // Ddanzi is aagag-dispatch-only; list parsing is never invoked.
        []
    }

    func parseDetail(html: String, post: Post) throws -> PostDetail {
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
    func commentsURL(for post: Post) -> URL? { post.url }

    func fetchAllComments(
        for post: Post,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [Comment] {
        // 1) Detail HTML tells us mid + document_srl. URL-based parsing is
        //    brittle (some posts use the `/{srl}` shortcut without a mid),
        //    so read both from the rendered detail page — the URL cache
        //    typically serves this without a network hit.
        let html = try await fetcher(post.url)
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
        let endpoint = URL(string: "https://www.ddanzi.com/")!
        let data = try await Networking.postForm(
            url: endpoint,
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

        return Self.decodeComments(data: data)
    }

    // MARK: - Field extraction

    private func extractTitle(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select(".boardR .top_title h1").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    private func extractAuthor(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select(".boardR .top_title .right .author").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    private func extractDate(in doc: Document) throws -> String? {
        let text = try doc.select(".boardR .top_title .right .time").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private func extractViewCount(in doc: Document) throws -> Int? {
        guard let el = try doc.select(".boardR .meta .sum .read").first() else { return nil }
        let raw = try el.text().filter(\.isNumber)
        return raw.isEmpty ? nil : Int(raw)
    }

    private func extractRecommend(in doc: Document) throws -> Int? {
        // `.sum .voteWrap .vote` contains the `icon_good.png` img plus count.
        guard let el = try doc.select(".boardR .meta .voteWrap .vote").first() else { return nil }
        let raw = try el.text().filter(\.isNumber)
        return raw.isEmpty ? nil : Int(raw)
    }

    // MARK: - Body blocks

    private func extractBlocks(in doc: Document) throws -> [ContentBlock] {
        guard let wrap = try doc.select(".read_content .xe_content").first() else { return [] }
        var blocks: [ContentBlock] = []
        var inline = InlineAccumulator()
        try collectBlocks(from: wrap, into: &blocks, inline: &inline)
        flushInline(into: &blocks, inline: &inline)
        return blocks
    }

    private func flushInline(into blocks: inout [ContentBlock], inline: inout InlineAccumulator) {
        let segments = inline.drain()
        if !segments.isEmpty {
            blocks.append(.richText(segments))
        }
    }

    private func collectBlocks(from element: Element, into blocks: inout [ContentBlock], inline: inout InlineAccumulator) throws {
        for node in element.getChildNodes() {
            if let child = node as? Element {
                try handleElement(child, blocks: &blocks, inline: &inline)
            } else if let text = node as? TextNode {
                let raw = text.text()
                if !raw.isEmpty { inline.appendText(raw) }
            }
        }
    }

    private func handleElement(_ el: Element, blocks: inout [ContentBlock], inline: inout InlineAccumulator) throws {
        let tag = el.tagName().lowercased()
        if Self.skipTags.contains(tag) { return }

        switch tag {
        case "img":
            if let url = try realImageURL(from: el) {
                flushInline(into: &blocks, inline: &inline)
                blocks.append(.image(url))
            }
            return
        case "video":
            if let url = try videoURL(from: el) {
                flushInline(into: &blocks, inline: &inline)
                blocks.append(.video(url))
            }
            return
        case "iframe":
            let src = try el.attr("src")
            if let id = youtubeID(from: src) {
                flushInline(into: &blocks, inline: &inline)
                blocks.append(.embed(.youtube, id: id))
            }
            return
        case "a":
            if let resolved = try anchor(from: el) {
                inline.appendLink(url: resolved.url, label: resolved.label)
            } else {
                inline.appendText(try el.text())
            }
            return
        case "br":
            inline.appendText("\n")
            return
        default:
            break
        }

        try collectBlocks(from: el, into: &blocks, inline: &inline)
        if Self.blockTags.contains(tag) {
            inline.appendText("\n")
        }
    }

    private func realImageURL(from el: Element) throws -> URL? {
        var src = try el.attr("src")
        if src.isEmpty { src = try el.attr("data-src") }
        if src.isEmpty { src = try el.attr("data-original") }
        guard !src.isEmpty else { return nil }
        let normalized = src.hasPrefix("//") ? "https:" + src : src
        guard let url = URL(string: normalized, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private func videoURL(from el: Element) throws -> URL? {
        var raw = try el.attr("src")
        if raw.isEmpty, let source = try el.select("source").first() {
            raw = try source.attr("src")
        }
        guard !raw.isEmpty else { return nil }
        if let hash = raw.firstIndex(of: "#") {
            raw = String(raw[..<hash])
        }
        let normalized = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let url = URL(string: normalized, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private func youtubeID(from src: String) -> String? {
        let ns = src as NSString
        guard let match = Self.youtubeIDRegex.firstMatch(in: src, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - Comment AJAX params

    private struct CommentParams {
        let mid: String
        let documentSrl: String
    }

    private static func extractCommentParams(html: String) throws -> CommentParams? {
        let doc = try SwiftSoup.parse(html)
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
    private struct CommentResponse: Decodable {
        let commentHtml: String?
    }

    private static func decodeComments(data: Data) -> [Comment] {
        guard let payload = try? JSONDecoder().decode(CommentResponse.self, from: data),
              let fragment = payload.commentHtml,
              !fragment.isEmpty
        else { return [] }

        do {
            let doc = try SwiftSoup.parseBodyFragment(fragment)
            let body = doc.body() ?? doc
            let items = try body.select("li[id^=comment_]")

            var results: [Comment] = []
            for li in items {
                let cmtID = try li.attr("id")
                    .replacingOccurrences(of: "comment_", with: "")
                let classAttr = (try? li.attr("class")) ?? ""
                let isReply = classAttr.contains("re_comment")

                let author = try li.select(".fbMeta .author").first()?.text()
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let dateText = try li.select(".fbMeta .time").first()?.text()
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let content = try renderCommentContent(in: li)
                let sticker = try extractCommentSticker(in: li)

                if author.isEmpty, content.isEmpty, sticker == nil { continue }

                results.append(Comment(
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
    private static func extractCommentSticker(in li: Element) throws -> URL? {
        guard let img = try li.select(".fdComment .xe_content img").first() else { return nil }
        var src = try img.attr("src")
        if src.isEmpty { src = try img.attr("data-src") }
        guard !src.isEmpty else { return nil }
        let normalized = src.hasPrefix("//") ? "https:" + src : src
        guard let url = URL(string: normalized, relativeTo: URL(string: "https://www.ddanzi.com")!)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// SwiftSoup's `.text()` normalises whitespace to a single space, so a
    /// raw `<br>` becomes no visible line break. Walk the DOM manually to
    /// preserve `<br>` as `\n` and collapse the result. Also strips
    /// `.re_com_nickname` (the "@targetUser" prefix bubble) from the text
    /// — leaving it in duplicates information the reply indentation already
    /// communicates, and makes every reply look like it starts with `@…`.
    private static func renderCommentContent(in li: Element) throws -> String {
        guard let content = try li.select(".fdComment .xe_content").first() else { return "" }
        guard let copy = content.copy() as? Element else { return "" }
        try copy.select(".re_com_nickname, img, script, style").remove()

        var output = ""
        try walk(copy, into: &output)
        let trimmed = output
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
    }

    private static func walk(_ element: Element, into output: inout String) throws {
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
