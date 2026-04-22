import Foundation
import SwiftSoup

struct ClienParser: BoardParser {
    let site: Site = .clien

    /// Matches the canonical YouTube embed URL shape — `/embed/{11-char id}`
    /// on `youtube.com` or the no-cookie variant. Shared with every other
    /// parser that promotes `<iframe>` to an inline YouTube block.
    nonisolated private static let youtubeIDRegex = try! NSRegularExpression(
        pattern: #"youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})"#,
        options: [.caseInsensitive]
    )

    /// HTML elements that mark a paragraph / block boundary in Clien post
    /// bodies. We emit a single `\n` after each — combined with the HTML
    /// pretty-print whitespace TextNode that sits between sibling elements
    /// in Clien output (also collapsed to `\n` by `InlineAccumulator.trimmed`),
    /// consecutive `<p>A</p><p>B</p>` becomes "A\n\nB" (1 blank line),
    /// while explicit `<p>A</p><p><br></p><p>B</p>` reaches 5 newlines and
    /// caps at 3 via `\n{4,}` → `\n\n\n` (2 blank lines). That keeps the
    /// distinction between paragraph break and user-typed blank line.
    nonisolated private static let blockTags: Set<String> = [
        "p", "div", "li", "blockquote", "tr",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article",
    ]

    /// `YYYY-MM-DD HH:MM(:SS)` — the timestamp Clien renders inside
    /// `div.post_date`. Used to slice out the modified timestamp when an
    /// edited post advertises both 등록일 and 수정일 in the same block.
    nonisolated private static let postDatePattern = #"\d{4}-\d{2}-\d{2}[\sT]\d{2}:\d{2}(?::\d{2})?"#

    nonisolated init() {}

    nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        let doc = try SwiftSoup.parse(html)
        let rows = try doc.select("a.list_item.symph-row")

        return try rows.compactMap { row -> Post? in
            // Skip pinned notice rows (jirum's "알리정보" sponsored items
            // appear with class "list_item notice symph-row" containing a
            // `<div class="ad">알리정보</div>` badge — not real posts).
            let classAttr = (try? row.attr("class")) ?? ""
            let classTokens = classAttr.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if classTokens.contains("notice") { return nil }
            if try !row.select("div.ad").isEmpty() { return nil }

            let href = try row.attr("href")
            guard !href.isEmpty,
                  let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL
            else { return nil }

            let title = try row.select("span[data-role=list-title-text]").first()?.text()
                ?? row.select("div.list_subject").first()?.text()
                ?? ""

            let author = try row.select("div.list_author span.nickname").first()?.text()
                ?? row.attr("data-author-id")

            let dateText = try row.select("div.list_time span").first()?.text() ?? ""

            let commentCount = Int(try row.attr("data-comment-count")) ?? 0
            let boardSN = try row.attr("data-board-sn")
            let postID: String = if !boardSN.isEmpty {
                boardSN
            } else {
                url.pathComponents.last ?? url.path
            }

            return Post(
                id: "\(board.id)-\(postID)",
                site: site,
                boardID: board.id,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                author: author,
                date: nil,
                dateText: dateText,
                commentCount: commentCount,
                url: url
            )
        }
    }

    nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)
        guard let article = try doc.select("div.post_article").first() else {
            throw ParserError.structureChanged("post_article 없음")
        }

        let (source, skipFirstParagraph) = try extractSource(from: article)

        // Walk the article body via the shared collector so HTML
        // pretty-print whitespace TextNodes between top-level `<p>` siblings
        // reach the inline accumulator. Iterating `article.children()`
        // (Elements only) and re-entering `collectBlocks` per child loses
        // those TextNodes, splits each `<p>` into its own ContentBlock,
        // and forces every paragraph gap down to the LazyVStack's fixed
        // 12pt spacing — so the explicit-blank-line vs. paragraph-break
        // distinction encoded in the markup never reaches the renderer.
        var blocks: [ContentBlock] = []
        if skipFirstParagraph, let firstP = article.children().first() {
            try firstP.remove()
        }
        try collectBlocks(from: article, into: &blocks)

        let rawDate = try doc.select("div.post_date").first()?.text() ?? ""
        let fullDateText = collapsePostDate(rawDate)
        let viewCountText = try doc.select("div.view_count").first()?.text() ?? ""
        let viewCount = firstInteger(in: viewCountText)

        let comments = try parseComments(doc: doc)

        return PostDetail(
            post: post,
            blocks: blocks,
            fullDateText: fullDateText,
            viewCount: viewCount,
            source: source,
            comments: comments
        )
    }

    /// Clien stuffs the registered date and modified date into the same
    /// `div.post_date` block when an article has been edited (both stamps
    /// appear, separated by a "수정" label). Surface only the modified
    /// stamp in that case so the header reads cleanly; pass through any
    /// other shape (single date, no edit) unchanged after light whitespace
    /// normalization.
    nonisolated private func collapsePostDate(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let keyword = normalized.range(of: "수정"),
           let date = normalized.range(
               of: Self.postDatePattern,
               options: .regularExpression,
               range: keyword.upperBound..<normalized.endIndex
           ) {
            return String(normalized[date])
        }
        return normalized
    }

    nonisolated private func extractSource(from article: Element) throws -> (source: PostSource?, skipFirstParagraph: Bool) {
        guard let firstP = article.children().first(),
              firstP.tagName().lowercased() == "p"
        else { return (nil, false) }

        let paragraphText = try firstP.text()
        guard let pipeRange = paragraphText.range(of: "|", options: .backwards) else {
            return (nil, false)
        }
        let afterPipe = paragraphText[pipeRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !afterPipe.isEmpty else { return (nil, false) }

        guard let anchor = try firstP.select("a").first() else {
            return (nil, false)
        }
        let anchorText = try anchor.text()
        guard let anchorPos = paragraphText.range(of: anchorText),
              anchorPos.lowerBound < pipeRange.lowerBound
        else { return (nil, false) }

        let href = try anchor.attr("href")
        guard let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.hasSuffix(".clien.net"),
              host != "clien.net"
        else { return (nil, false) }

        return (PostSource(name: afterPipe, url: url), true)
    }

    nonisolated private func collectBlocks(from element: Element, into blocks: inout [ContentBlock]) throws {
        var inline = InlineAccumulator()

        func flush() {
            let segs = inline.drain()
            if !segs.isEmpty {
                blocks.append(.richText(segs))
            }
        }

        let tag = element.tagName().lowercased()
        if tag == "img" {
            if let image = try image(from: element) {
                blocks.append(.image(image.url, aspectRatio: image.aspectRatio))
            }
            return
        }
        if tag == "a" {
            // Pure anchor: no nested media → emit a single inline link and
            // return. When the anchor wraps `<img>` / `<iframe>` (forums
            // often wrap inline GIFs in a clickable link), fall through to
            // the main child-walking loop below so the nested media becomes
            // a proper block AND sibling TextNodes still contribute text
            // via the existing TextNode branch.
            let nestedImgs = try element.select("img")
            let nestedIframes = try element.select("iframe")
            if nestedImgs.isEmpty() && nestedIframes.isEmpty() {
                if let resolved = try anchor(from: element) {
                    inline.appendLink(url: resolved.url, label: resolved.label)
                    flush()
                }
                return
            }
        }

        for node in element.getChildNodes() {
            if let el = node as? Element {
                let childTag = el.tagName().lowercased()
                switch childTag {
                case "img":
                    flush()
                    if let image = try image(from: el) {
                        blocks.append(.image(image.url, aspectRatio: image.aspectRatio))
                    }
                case "iframe":
                    // Clien embeds YouTube as <iframe src="…/embed/{id}">.
                    // Promote to an inline `.embed(.youtube, id:)` block so
                    // PostDetailView renders the thumbnail + tap-to-open
                    // affordance instead of silently dropping the iframe.
                    if let id = youtubeID(from: (try? el.attr("src")) ?? "") {
                        flush()
                        blocks.append(.embed(.youtube, id: id))
                    }
                case "br":
                    inline.appendText("\n")
                case "a":
                    // Anchor wrapping `<img>` / `<iframe>` falls through to
                    // the same recurse-as-block path the default case uses,
                    // so an inline GIF wrapped in a clickable link still
                    // renders as a media block instead of a bare link label.
                    let nestedImgsInAnchor = try el.select("img")
                    let nestedIframesInAnchor = try el.select("iframe")
                    if !nestedImgsInAnchor.isEmpty() || !nestedIframesInAnchor.isEmpty() {
                        flush()
                        try collectBlocks(from: el, into: &blocks)
                    } else if let resolved = try anchor(from: el) {
                        inline.appendLink(url: resolved.url, label: resolved.label)
                    } else {
                        inline.appendText(try el.text())
                    }
                default:
                    let nestedImgs = try el.select("img")
                    let nestedIframes = try el.select("iframe")
                    if !nestedImgs.isEmpty() || !nestedIframes.isEmpty() {
                        flush()
                        try collectBlocks(from: el, into: &blocks)
                    } else {
                        try collectInlines(from: el, into: &inline)
                    }
                    if Self.blockTags.contains(childTag) {
                        inline.appendText("\n")
                    }
                }
            } else if let textNode = node as? TextNode {
                inline.appendText(textNode.text())
            }
        }
        flush()
    }

    /// Extract a YouTube video ID from an `<iframe src>` value. Returns nil
    /// for non-YouTube iframes so the default path can still recurse or
    /// drop silently without surfacing a broken embed card.
    nonisolated private func youtubeID(from src: String) -> String? {
        let ns = src as NSString
        guard let match = Self.youtubeIDRegex.firstMatch(
                in: src,
                range: NSRange(location: 0, length: ns.length)
              ),
              match.numberOfRanges >= 2
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    nonisolated private func collectInlines(from element: Element, into inline: inout InlineAccumulator) throws {
        for node in element.getChildNodes() {
            if let el = node as? Element {
                let childTag = el.tagName().lowercased()
                switch childTag {
                case "br":
                    inline.appendText("\n")
                case "a":
                    if let resolved = try anchor(from: el) {
                        inline.appendLink(url: resolved.url, label: resolved.label)
                    } else {
                        inline.appendText(try el.text())
                    }
                default:
                    // Recurse first, then append `\n` for block-level tags
                    // so user-typed Enter keystrokes nested inside non-block
                    // wrappers (e.g. `<table><tr><td><p>...</p></td></tr>` —
                    // Clien's legacy editor still emits these) survive into
                    // the rendered text.
                    try collectInlines(from: el, into: &inline)
                    if Self.blockTags.contains(childTag) {
                        inline.appendText("\n")
                    }
                }
            } else if let textNode = node as? TextNode {
                inline.appendText(textNode.text())
            }
        }
    }

    nonisolated private func image(from element: Element) throws -> (url: URL, aspectRatio: CGFloat?)? {
        let src = try element.attr("src")
        guard !src.isEmpty,
              let url = URL(string: src, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        let width = CGFloat(Double(try element.attr("data-img-width")) ?? 0)
        let height = CGFloat(Double(try element.attr("data-img-height")) ?? 0)
        let aspectRatio = width > 0 && height > 0 ? width / height : nil
        return (url, aspectRatio)
    }

    nonisolated private func parseComments(doc: Document) throws -> [Comment] {
        let rows = try doc.select("div.comment_row[data-role=comment-row]")
        var results: [Comment] = []

        for row in rows {
            let sn = try row.attr("data-comment-sn").trimmingCharacters(in: .whitespaces)
            let authorID = try row.attr("data-author-id")

            let nicknameText = try row.select("span.nickname").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let nickImgAlt = try row.select("span.nickimg img").first()?.attr("alt")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let author = !nicknameText.isEmpty ? nicknameText
                : !nickImgAlt.isEmpty ? nickImgAlt
                : authorID

            let dateText = try row.select("span.timestamp").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard let viewEl = try row.select("div.comment_view").first() else { continue }
            try viewEl.select("input").remove()
            let content = try viewEl.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }

            let likeText = try row.select("strong[id^=setLikeCount_]").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            let likeCount = Int(likeText) ?? 0

            let isReply = try row.classNames().contains { $0.lowercased().contains("re") && $0.lowercased() != "comment_row" }

            let commentID: String = sn.isEmpty
                ? "\(site.rawValue)-c-\(results.count)"
                : "\(site.rawValue)-c-\(sn)"

            results.append(Comment(
                id: commentID,
                author: author,
                dateText: dateText,
                content: content,
                likeCount: likeCount,
                isReply: isReply
            ))
        }
        return results
    }

    nonisolated private func firstInteger(in text: String) -> Int? {
        var digits = ""
        for char in text {
            if char.isNumber {
                digits.append(char)
            } else if !digits.isEmpty && char != "," {
                break
            }
        }
        return digits.isEmpty ? nil : Int(digits)
    }
}
