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
    /// Matches the two shapes bobaedream renders for comment timestamps:
    /// `HH:MM` for same-day comments and `YYYY.MM.DD HH:MM` for older ones.
    /// Used to filter the util row's spans so an added badge / IP indicator
    /// doesn't silently replace the timestamp.
    private static let commentTimeRegex = try! NSRegularExpression(
        pattern: #"\d{1,2}:\d{2}|\d{4}\.\d{1,2}\.\d{1,2}"#,
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
        guard let wrap = candidates.compactMap({ $0 }).first else { return [] }
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
                blocks.append(.video(url, posterURL: try videoPoster(from: el)))
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
            // Anchors wrapping `<img>` / `<video>` (Bobaedream wraps almost
            // every inline GIF in a clickable link) would otherwise be
            // consumed here as a bare link label, hiding the media. Recurse
            // into the children first so the nested image becomes a proper
            // block; only treat the anchor as a link/text segment when
            // there's no media inside.
            if try el.select("img, video").first() != nil {
                try collectBlocks(from: el, into: &blocks, inline: &inline)
                return
            }
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

    /// HTML5 `<video poster="...">` — forum posts often ship it so the player
    /// shows something before the user taps, and the tap-to-fullscreen flow
    /// only reveals black otherwise.
    private func videoPoster(from el: Element) throws -> URL? {
        let raw = try el.attr("poster").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let normalized = raw.hasPrefix("//") ? "https:" + raw : raw
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
