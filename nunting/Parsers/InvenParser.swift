import Foundation
import SwiftSoup

struct InvenParser: BoardParser {
    let site: Site = .inven

    nonisolated init() {}

    /// Matches decimal (`&#1234;`) and hexadecimal (`&#xAF;`) HTML numeric
    /// character references. Hoisted because `cleanCommentText` runs once per
    /// Inven comment; per-call `NSRegularExpression` construction showed up on
    /// long threads.
    nonisolated private static let numericEntityRegex = try! NSRegularExpression(
        pattern: #"&#(x?)([0-9a-fA-F]+);"#,
        options: [.caseInsensitive]
    )

    nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        let doc = try SwiftSoup.parse(html)
        let rows = try doc.select("section.mo-board-list li.list")

        return try rows.compactMap { row -> Post? in
            guard let titleLink = try row.select("a.contentLink").first() else { return nil }
            let href = try titleLink.attr("href")
            guard !href.isEmpty,
                  let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }

            let title = try titleLink.select("span.subject").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }

            let author = try row.select("span.layerNickName").first()?.ownText()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? row.select(".user_info .nick").first()?.text()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""

            let dateText = try row.select("span.time").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let commentText = try row.select("a.com-btn span.num").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            let commentCount = Int(commentText) ?? 0

            let levelText = try row.select("span.lv").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let viewText = try row.select("span.view").first()?.text() ?? ""
            let viewCount = viewText.isEmpty ? nil : Int(viewText.filter(\.isNumber))
            let recoText = try row.select("span.reco").first()?.text() ?? ""
            let recommendCount = recoText.isEmpty ? nil : Int(recoText.filter(\.isNumber))
            let hasAuthIcon = try !row.select("span.layerNickName .maple").isEmpty()

            let postID = url.pathComponents.last ?? url.absoluteString

            return Post(
                id: "\(board.id)-\(postID)",
                site: site,
                boardID: board.id,
                title: title,
                author: author,
                date: nil,
                dateText: dateText,
                commentCount: commentCount,
                url: url,
                viewCount: viewCount,
                recommendCount: recommendCount,
                levelText: levelText,
                hasAuthIcon: hasAuthIcon
            )
        }
    }

    nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)
        guard let section = try doc.select("section.mo-board-view").first() else {
            throw ParserError.structureChanged("mo-board-view 없음")
        }

        guard let body = try section.select("div.bbs-con").first() else {
            throw ParserError.structureChanged("bbs-con 없음")
        }

        let imageHolder = try body.select("div#imageCollectDiv").first() ?? body
        var blocks: [ContentBlock] = []
        try collectBlocks(from: imageHolder, into: &blocks)

        let fullDateText = try section.select("div.date").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let viewText = try section.select("div.hit span").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let viewCount = Int(viewText.filter(\.isNumber))

        return PostDetail(
            post: post,
            blocks: blocks,
            fullDateText: fullDateText,
            viewCount: viewCount,
            source: nil,
            comments: []
        )
    }

    nonisolated private static let blockTags: Set<String> = [
        "p", "div", "li", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article",
    ]

    /// Tags the block-walker promotes to a media block. Paired with
    /// `hasAnyDescendant(of:taggedAnyOf:)` so wrapper elements decide
    /// recurse-vs-inline without doing a full `select("img"|"video")` walk.
    nonisolated private static let mediaTags: Set<String> = ["img", "video"]

    nonisolated private func collectBlocks(from element: Element, into blocks: inout [ContentBlock]) throws {
        if isHidden(element) { return }
        var inline = InlineAccumulator()

        func flush() {
            let segs = inline.drain()
            if !segs.isEmpty {
                blocks.append(.richText(segs))
            }
        }

        let tag = element.tagName().lowercased()
        if tag == "img" {
            if let url = try imageURL(from: element) {
                blocks.append(.image(url))
            }
            return
        }
        if tag == "video" {
            if let url = try videoURL(from: element) {
                blocks.append(.video(url, posterURL: try videoPoster(from: element)))
            }
            return
        }
        if tag == "a" {
            // Pure anchor: no nested media → emit a single inline link and
            // return. When the anchor wraps `<img>` / `<video>` (forums
            // often wrap inline GIFs in a clickable link), fall through to
            // the main child-walking loop below so the nested media becomes
            // a proper block AND sibling TextNodes still contribute text
            // via the existing TextNode branch.
            if !hasAnyDescendant(of: element, taggedAnyOf: Self.mediaTags) {
                if let resolved = try anchor(from: element) {
                    inline.appendLink(url: resolved.url, label: resolved.label)
                    flush()
                }
                return
            }
        }
        if tag == "script" || tag == "style" || tag == "iframe" {
            return
        }

        for node in element.getChildNodes() {
            if let el = node as? Element {
                if isHidden(el) { continue }
                let childTag = el.tagName().lowercased()
                switch childTag {
                case "img":
                    flush()
                    if let url = try imageURL(from: el) {
                        blocks.append(.image(url))
                    }
                case "video":
                    flush()
                    if let url = try videoURL(from: el) {
                        blocks.append(.video(url, posterURL: try videoPoster(from: el)))
                    }
                case "br":
                    inline.appendText("\n")
                case "script", "style", "iframe":
                    continue
                case "a":
                    // Anchor wrapping `<img>` / `<video>` falls through to
                    // the same recurse-as-block path the default case uses,
                    // so an inline GIF wrapped in a clickable link still
                    // renders as a media block instead of a bare link label.
                    if hasAnyDescendant(of: el, taggedAnyOf: Self.mediaTags) {
                        flush()
                        try collectBlocks(from: el, into: &blocks)
                    } else if let resolved = try anchor(from: el) {
                        inline.appendLink(url: resolved.url, label: resolved.label)
                    } else {
                        inline.appendText(try el.text())
                    }
                default:
                    let isBlock = Self.blockTags.contains(childTag)
                    if hasAnyDescendant(of: el, taggedAnyOf: Self.mediaTags) {
                        flush()
                        try collectBlocks(from: el, into: &blocks)
                    } else {
                        try collectInlines(from: el, into: &inline)
                    }
                    if isBlock {
                        inline.appendText("\n")
                    }
                }
            } else if let textNode = node as? TextNode {
                inline.appendText(textNode.text())
            }
        }
        flush()
    }

    nonisolated private func collectInlines(from element: Element, into inline: inout InlineAccumulator) throws {
        for node in element.getChildNodes() {
            if let el = node as? Element {
                if isHidden(el) { continue }
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
                case "script", "style", "iframe":
                    continue
                default:
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

    nonisolated private func imageURL(from element: Element) throws -> URL? {
        let src = try element.attr("src")
        guard !src.isEmpty,
              let url = URL(string: src, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// Pick up HTML5 `<video poster="...">` so the tap-to-play frame shows
    /// the site's intended thumbnail instead of a black placeholder.
    nonisolated private func videoPoster(from el: Element) throws -> URL? {
        let raw = try el.attr("poster").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let normalized = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let url = URL(string: normalized, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    nonisolated private func videoURL(from element: Element) throws -> URL? {
        let dataSrc = try element.attr("data-src")
        let raw = dataSrc.isEmpty ? try element.attr("src") : dataSrc
        guard !raw.isEmpty,
              let url = URL(string: raw, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    nonisolated func commentsURL(for post: Post) -> URL? {
        URL(string: "https://www.inven.co.kr/common/board/comment.json.php")
    }

    nonisolated func fetchAllComments(
        for post: Post,
        detailHTML _: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [Comment] {
        // Inven comments live at a separate JSON endpoint, unrelated
        // to the detail HTML — `detailHTML` is unused.
        let numericComponents = post.url.pathComponents.filter { $0.allSatisfy(\.isNumber) && !$0.isEmpty }
        guard numericComponents.count >= 2 else { return [] }
        let comeidx = numericComponents[numericComponents.count - 2]
        let articlecode = numericComponents[numericComponents.count - 1]

        guard let apiURL = URL(string: "https://www.inven.co.kr/common/board/comment.json.php") else {
            return []
        }

        let baseParams: [String: String] = [
            "act": "list",
            "out": "json",
            "comeidx": comeidx,
            "articlecode": articlecode,
            "sortorder": "date",
            "replynick": "",
            "replyidx": "0",
        ]

        let firstData = try await Networking.postForm(url: apiURL, parameters: baseParams, referer: post.url)
        let firstResponse = try JSONDecoder().decode(InvenCommentResponse.self, from: firstData)

        let collapsed = firstResponse.commentlist
            .filter { $0.attr.titlenum > 0 && $0.list.isEmpty }
            .map { $0.attr.titlenum }

        let blocks: [InvenCommentBlock]
        if collapsed.isEmpty {
            blocks = firstResponse.commentlist
        } else {
            var paramsWithTitles = baseParams
            paramsWithTitles["titles"] = collapsed.map(String.init).joined(separator: "|")
            let extraData = try await Networking.postForm(url: apiURL, parameters: paramsWithTitles, referer: post.url)
            let extraResponse = try JSONDecoder().decode(InvenCommentResponse.self, from: extraData)
            blocks = extraResponse.commentlist
        }

        return convertToComments(blocks: blocks)
    }

    nonisolated private func convertToComments(blocks: [InvenCommentBlock]) -> [Comment] {
        // titlenum 0 = latest block; positive titlenums are older slices ordered ascending.
        let sortedBlocks = blocks.sorted { lhs, rhs in
            let l = lhs.attr.titlenum == 0 ? Int.max : lhs.attr.titlenum
            let r = rhs.attr.titlenum == 0 ? Int.max : rhs.attr.titlenum
            return l < r
        }

        var results: [Comment] = []
        for block in sortedBlocks {
            for raw in block.list {
                let stickerURL = extractStickerURL(from: raw.comment)
                let content = cleanCommentText(raw.comment)
                guard !content.isEmpty || stickerURL != nil else { continue }
                let isReply = raw.attr.cmtidx != raw.attr.cmtpidx
                results.append(Comment(
                    id: "\(site.rawValue)-c-\(raw.attr.cmtidx)",
                    author: raw.name,
                    dateText: raw.date,
                    content: content,
                    likeCount: raw.recommend,
                    isReply: isReply,
                    stickerURL: stickerURL
                ))
            }
        }
        return results
    }

    nonisolated private func extractStickerURL(from rawHTML: String) -> URL? {
        // Inven ships sticker comments as entity-encoded HTML
        // (`&lt;div class=...&gt;&lt;img src=...&gt;&lt;/div&gt;`). SwiftSoup
        // decodes entities inside text/attribute values but does NOT re-parse
        // those decoded strings as markup — so `parseBodyFragment` on the raw
        // payload sees no img tag and returns nil. Peel the entity layers
        // with the same cheap decoder `cleanCommentText` uses before looking
        // for an image.
        var working = rawHTML
        for _ in 0..<3 {
            guard working.contains("&") else { break }
            let decoded = Self.decodeHTMLEntities(working)
            if decoded == working { break }
            working = decoded
        }

        guard let doc = try? SwiftSoup.parseBodyFragment(working),
              let img = try? doc.select("img").first(),
              let src = try? img.attr("src"),
              !src.isEmpty,
              let url = URL(string: src),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    nonisolated private func cleanCommentText(_ raw: String) -> String {
        // Inven sometimes ships HTML that's been entity-encoded one or more
        // times (e.g. sticker comments come back as `&lt;div class=...&gt;`).
        // Peel layers with a cheap string-level entity decoder so we avoid
        // running a full SwiftSoup parse per layer (each pass used to dominate
        // long-thread CPU profiles). Capped at 3 to bound worst case.
        var working = raw
        for _ in 0..<3 {
            guard working.contains("&") else { break }
            let decoded = Self.decodeHTMLEntities(working)
            if decoded == working { break }
            working = decoded
        }

        // Final pass: parse as HTML so block tags get the newline marker treatment.
        guard let doc = try? SwiftSoup.parseBodyFragment(working),
              let body = doc.body()
        else { return working }

        // Stamp a non-whitespace marker before block-level breaks so they survive
        // SwiftSoup's text() whitespace collapsing; we replace it with \n afterwards.
        let blockMarker = "\u{0001}NL\u{0001}"
        if let blocks = try? body.select("br, p, div, li, blockquote") {
            for el in blocks {
                _ = try? el.before(blockMarker)
            }
        }

        let text = (try? body.text()) ?? raw
        var result = text.replacingOccurrences(of: blockMarker, with: "\n")
        // SwiftSoup's text() leaves whitespace flanking the block marker,
        // so once the marker becomes a newline each continuation line
        // starts with a space and renders as a visible indent. Collapse
        // any whitespace hugging a newline before the run-length cleanup.
        result = result.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes one layer of HTML character references without invoking a
    /// full HTML parse. Handles the named entities Inven comments actually
    /// emit plus decimal/hex numeric references. `&amp;` is processed last
    /// so `&amp;lt;` decodes to `&lt;` this pass and unwraps further on
    /// subsequent iterations instead of collapsing in one step.
    nonisolated private static func decodeHTMLEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }

        // First, rewrite numeric refs via regex so decimal/hex are both covered.
        let ns = input as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var numericReplaced = ""
        numericReplaced.reserveCapacity(input.count)
        var cursor = 0
        numericEntityRegex.enumerateMatches(in: input, options: [], range: fullRange) { match, _, _ in
            guard let match else { return }
            let matchRange = match.range
            numericReplaced.append(ns.substring(with: NSRange(location: cursor, length: matchRange.location - cursor)))
            let isHex = match.range(at: 1).length > 0
            let digits = ns.substring(with: match.range(at: 2))
            let codepoint: Int? = isHex ? Int(digits, radix: 16) : Int(digits)
            if let cp = codepoint, let scalar = Unicode.Scalar(cp) {
                numericReplaced.append(Character(scalar))
            } else {
                numericReplaced.append(ns.substring(with: matchRange))
            }
            cursor = matchRange.location + matchRange.length
        }
        if cursor < ns.length {
            numericReplaced.append(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
        }

        return numericReplaced
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    nonisolated private struct InvenCommentResponse: Decodable {
        let commentlist: [InvenCommentBlock]
    }

    nonisolated private struct InvenCommentBlock: Decodable {
        let attr: InvenBlockAttr
        let list: [InvenComment]

        enum CodingKeys: String, CodingKey {
            case attr = "__attr__"
            case list
        }
    }

    nonisolated private struct InvenBlockAttr: Decodable {
        let titlenum: Int
    }

    nonisolated private struct InvenComment: Decodable {
        let attr: InvenCommentAttr
        let date: String
        let name: String
        let comment: String
        let recommend: Int

        enum CodingKeys: String, CodingKey {
            case attr = "__attr__"
            case date = "o_date"
            case name = "o_name"
            case comment = "o_comment"
            case recommend = "o_recommend"
        }
    }

    nonisolated private struct InvenCommentAttr: Decodable {
        let cmtidx: Int
        let cmtpidx: Int
    }
}
