import Foundation
import SwiftSoup

/// Parses bobaedream (보배드림) mobile detail pages. Reached exclusively via
/// aagag mirror redirects — bobaedream is not exposed as a directly-browsable
/// site. Replies to comments load asynchronously on the source site so the
/// initial HTML only exposes top-level comments; that's the full scope here.
struct BobaeParser: BoardParser {
    let site: Site = .bobae

    nonisolated init() {}

    private static let youtubeIDRegex = try! NSRegularExpression(
        pattern: #"youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})"#,
        options: []
    )

    private static let blockTags: Set<String> = [
        "p", "div", "li", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "tr",
    ]
    private static let skipTags: Set<String> = ["script", "style", "noscript"]

    func parseList(html: String, board: Board) throws -> [Post] {
        // Bobaedream is aagag-dispatch-only; list parsing is never invoked.
        []
    }

    func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)

        // Bobaedream returns a 200 with a "게시글이 존재하지 않습니다" alert
        // for deleted / removed posts. Detect by absence of the article body.
        if try doc.select("article.article .article-body").isEmpty() {
            let body = try doc.text()
            let notice: String
            if body.contains("삭제") || body.contains("존재하지 않") {
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
        let fullDateText = try extractFullDate(in: doc)
        let recommend = try extractRecommend(in: doc)
        let viewCount = try extractViewCount(in: doc)
        let blocks = try extractBlocks(in: doc)
        let comments = try extractComments(in: doc)

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
            fullDateText: fullDateText,
            viewCount: viewCount,
            source: nil,
            comments: comments
        )
    }

    // Comments live in the same detail page — no separate fetch needed.
    func commentsURL(for post: Post) -> URL? { nil }

    // MARK: - Field extraction

    private func extractTitle(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select("article.article h3.subject").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    private func extractAuthor(in doc: Document, fallback: String) throws -> String {
        // <div class="info"><span>작성자</span> <button>작성글보기</button></div>
        let text = try doc.select("article.article .util2 .info span").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    private func extractFullDate(in doc: Document) throws -> String? {
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

    private func extractRecommend(in doc: Document) throws -> Int? {
        // `<span class="data3">추천 183</span>`
        guard let el = try doc.select("article.article .util .data3").first() else { return nil }
        let raw = try el.text().filter(\.isNumber)
        return raw.isEmpty ? nil : Int(raw)
    }

    private func extractViewCount(in doc: Document) throws -> Int? {
        // `<span class="data4">조회 10639</span>`
        guard let el = try doc.select("article.article .util .data4").first() else { return nil }
        let raw = try el.text().filter(\.isNumber)
        return raw.isEmpty ? nil : Int(raw)
    }

    // MARK: - Body blocks

    private func extractBlocks(in doc: Document) throws -> [ContentBlock] {
        guard let wrap = try doc.select("article.article .article-body").first() else { return [] }
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
        // Strip media fragments like `#t=0.05` that the source site uses as a
        // poster hint — AVURLAsset treats them as seek targets and breaks the
        // initial frame render.
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

    // MARK: - Comments

    private func extractComments(in doc: Document) throws -> [Comment] {
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
        let nodes = try doc.select(".reple_body > ul.list > li")
        var results: [Comment] = []
        for (idx, li) in nodes.enumerated() {
            let classAttr = (try? li.attr("class")) ?? ""
            if classAttr.contains("best") { continue }

            guard let replyEl = try li.select(".con_area > .reply").first() else { continue }
            let isReply = try !li.select("> .ico_area").isEmpty()
            let content = try extractCommentContent(replyEl)

            let utilEl = try li.select(".con_area > .util").first()
            let author = try utilEl?.select(".data4").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let dateText = try extractCommentDate(utilEl)
            let likeCount = try extractCommentLikes(in: li)
            let stickerURL = try extractCommentSticker(in: replyEl)
            let cmtID = extractCommentID(from: li) ?? "idx\(idx)"

            guard !author.isEmpty || !content.isEmpty || stickerURL != nil
            else { continue }

            results.append(Comment(
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

    private func extractCommentContent(_ replyEl: Element) throws -> String {
        guard let copy = replyEl.copy() as? Element else { return "" }
        // Strip the "베플" (best comment) badge and any inline images so the
        // text reads cleanly. Line breaks in the DOM come from <br>, which
        // SwiftSoup's .text() collapses — convert them to newlines first.
        try copy.select(".ico3, img, script, style").remove()
        try copy.select("br").forEach { br in
            try br.before(TextNode("\n", ""))
        }
        return try copy.text().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractCommentDate(_ util: Element?) throws -> String {
        // `<div class="util"><span class="data4">author</span><span>14:12</span>...`
        // The second span is the time; `.data4` and the report anchor's
        // parent span sandwich it. Grab every child span, drop ones that
        // carry .data4 or wrap an <a>.
        guard let util else { return "" }
        for span in try util.select("span") {
            let cls = try span.attr("class")
            if cls.contains("data4") { continue }
            if try !span.select("a").isEmpty() { continue }
            let text = try span.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private func extractCommentLikes(in li: Element) throws -> Int {
        // `<div class="util3"><button class="good">37</button><button class="bad">1</button>`
        guard let good = try li.select(".util3 .good").first() else { return 0 }
        let raw = try good.text().filter(\.isNumber)
        return Int(raw) ?? 0
    }

    private func extractCommentSticker(in replyEl: Element) throws -> URL? {
        // Comment images — bobaedream renders attached images inline within
        // the .reply div. Strip loading/icon chrome the same way humor does.
        for img in try replyEl.select("img") {
            let candidates = [
                try img.attr("data-original"),
                try img.attr("data-src"),
                try img.attr("src"),
            ]
            for raw in candidates {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.contains("loading"),
                      !trimmed.contains("/icon"),
                      !trimmed.contains("/images/ic")
                else { continue }
                let normalized = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
                guard let url = URL(string: normalized, relativeTo: site.baseURL)?.absoluteURL,
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else { continue }
                return url
            }
        }
        return nil
    }

    private func extractCommentID(from li: Element) -> String? {
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
