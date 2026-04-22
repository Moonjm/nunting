import Foundation
import SwiftSoup

struct CoolenjoyParser: BoardParser {
    let site: Site = .coolenjoy

    nonisolated init() {}

    func parseList(html: String, board: Board) throws -> [Post] {
        let doc = try SwiftSoup.parse(html)
        let rows = try doc.select("ul.na-table > li.d-md-table-row")

        return try rows.compactMap { row -> Post? in
            guard let titleEl = try row.select("a.na-subject").first() else { return nil }
            if try !titleEl.select("strong > b.text-white").isEmpty() { return nil }

            guard let url = try resolvePostURL(titleEl: titleEl, row: row) else { return nil }

            let title = try cleanedTitle(from: titleEl)
            guard !title.isEmpty else { return nil }

            let author = try authorName(from: row)
            let dateText = try metaValue(from: row, label: "등록일")
                ?? metaValue(from: row, label: "작성일")
                ?? ""
            let commentCount = try commentCountValue(from: row)
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
                url: url
            )
        }
    }

    func commentsURL(for post: Post) -> URL? {
        let comps = post.url.pathComponents
        guard comps.count >= 4 else { return nil }
        let boardTable = comps[2]
        let wrID = comps[3]
        return URL(string: "https://coolenjoy.net/nariya/bbs/comment_view.php?bo_table=\(boardTable)&wr_id=\(wrID)")
    }

    func fetchAllComments(for post: Post, fetcher: @escaping @Sendable (URL) async throws -> String) async throws -> [Comment] {
        guard let baseURL = commentsURL(for: post) else { return [] }

        let firstPageURL = appendingPagingParams(to: baseURL, page: 1)
        let firstHtml = try await fetcher(firstPageURL)
        let totalPages = try totalCommentPages(html: firstHtml)
        let firstPage = try parseComments(html: firstHtml)

        if totalPages <= 1 { return firstPage }

        let pagesToFetch = Array(2...totalPages)
        var pageMap: [Int: [Comment]] = [1: firstPage]

        try await withThrowingTaskGroup(of: (Int, [Comment]).self) { group in
            for page in pagesToFetch {
                let url = appendingPagingParams(to: baseURL, page: page)
                group.addTask {
                    let html = try await fetcher(url)
                    let parsed = try self.parseComments(html: html)
                    return (page, parsed)
                }
            }
            for try await (page, comments) in group {
                pageMap[page] = comments
            }
        }

        return (1...totalPages).flatMap { pageMap[$0] ?? [] }
    }

    private func appendingPagingParams(to url: URL, page: Int) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (comps.queryItems ?? []).filter { $0.name != "page" && $0.name != "cob" }
        items.append(URLQueryItem(name: "cob", value: "old"))
        items.append(URLQueryItem(name: "page", value: "\(page)"))
        comps.queryItems = items
        return comps.url ?? url
    }

    private func totalCommentPages(html: String) throws -> Int {
        let doc = try SwiftSoup.parse(html)
        let items = try doc.select("ul.pagination li.page-item:not(.page-first):not(.page-prev):not(.page-next):not(.page-last)")
        var maxPage = 1
        for item in items {
            let text = try item.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = String(text.prefix { $0.isNumber })
            if let n = Int(digits), n > maxPage { maxPage = n }
        }
        return maxPage
    }

    nonisolated func parseComments(html: String) throws -> [Comment] {
        let doc = try SwiftSoup.parse(html)
        let articles = try doc.select("article[id^=c_]")
        var results: [Comment] = []

        for article in articles {
            let articleID = try article.attr("id")
            let snStart = articleID.index(articleID.startIndex, offsetBy: 2, limitedBy: articleID.endIndex)
            guard let sn = snStart.map({ String(articleID[$0...]) }), !sn.isEmpty else { continue }

            let author = try authorName(from: article)
            let dateText = try article.select("time").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let content = try article.select("textarea[id^=save_comment_]").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !content.isEmpty else { continue }

            let likeText = try article.select("b[id^=c_g]").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            let likeCount = Int(likeText) ?? 0

            results.append(Comment(
                id: "\(site.rawValue)-c-\(sn)",
                author: author,
                dateText: dateText,
                content: content,
                likeCount: likeCount,
                isReply: false
            ))
        }
        return results
    }

    func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)
        guard let article = try doc.select("article#bo_v").first() else {
            throw ParserError.structureChanged("article#bo_v 없음")
        }

        guard let contentEl = try article.select("div.view-content").first() else {
            throw ParserError.structureChanged("view-content 없음")
        }

        var blocks: [ContentBlock] = []
        for child in contentEl.children() {
            try collectBlocks(from: child, into: &blocks)
        }

        let fullDateText = try article.select("time").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let viewCount = try metaValueInArticle(article: article, label: "조회").flatMap(firstInteger)

        return PostDetail(
            post: post,
            blocks: blocks,
            fullDateText: fullDateText,
            viewCount: viewCount,
            source: nil,
            comments: []
        )
    }

    private func resolvePostURL(titleEl: Element, row: Element) throws -> URL? {
        let href = try titleEl.attr("href")
        if !href.isEmpty && href != "#",
           let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }
        let onclick = try row.attr("onclick")
        if let extracted = Self.extractLocationHref(from: onclick),
           let url = URL(string: extracted, relativeTo: site.baseURL)?.absoluteURL {
            return url
        }
        return nil
    }

    private static func extractLocationHref(from onclick: String) -> String? {
        guard let start = onclick.range(of: "location.href='")?.upperBound,
              let end = onclick[start...].range(of: "'")?.lowerBound
        else { return nil }
        return String(onclick[start..<end])
    }

    private func cleanedTitle(from anchor: Element) throws -> String {
        try anchor.select("span.sr-only").remove()
        let text = try anchor.text().trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    private func authorName(from row: Element) throws -> String {
        if let memberEl = try row.select("a.sv_member").first() {
            let titleAttr = try memberEl.attr("title")
            if let stripped = stripSuffix(titleAttr, suffix: " 자기소개"), !stripped.isEmpty {
                return stripped
            }
            let text = try memberEl.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private func metaValue(from row: Element, label: String) throws -> String? {
        let cells = try row.select("div.d-md-table-cell")
        for cell in cells {
            let srOnly = try cell.select("span.sr-only").first()
            if try srOnly?.text() == label {
                let copy = cell.copy() as? Element ?? cell
                try copy.select("span.sr-only").remove()
                try copy.select("i").remove()
                let text = try copy.text().trimmingCharacters(in: .whitespacesAndNewlines)
                return text
            }
        }
        return nil
    }

    private func commentCountValue(from row: Element) throws -> Int {
        guard let countEl = try row.select("span.count-plus").first() else { return 0 }
        let raw = try countEl.text()
        let digits = raw.filter(\.isNumber)
        return Int(digits) ?? 0
    }

    private func metaValueInArticle(article: Element, label: String) throws -> String? {
        let srOnlies = try article.select("span.sr-only")
        for sr in srOnlies {
            if try sr.text() == label {
                if let parent = sr.parent() {
                    let copy = parent.copy() as? Element ?? parent
                    try copy.select("span.sr-only").remove()
                    try copy.select("i").remove()
                    let text = try copy.text().trimmingCharacters(in: .whitespacesAndNewlines)
                    return text
                }
            }
        }
        return nil
    }

    private func collectBlocks(from element: Element, into blocks: inout [ContentBlock]) throws {
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
        if tag == "a" {
            // Pure anchor: no nested media → emit a single inline link and
            // return. When the anchor wraps `<img>` (forums often wrap
            // inline GIFs in a clickable link), fall through to the main
            // child-walking loop below so the nested image becomes a proper
            // block AND sibling TextNodes still contribute text via the
            // existing TextNode branch.
            let nestedImgs = try element.select("img")
            if nestedImgs.isEmpty() {
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
                    if let url = try imageURL(from: el) {
                        blocks.append(.image(url))
                    }
                case "br":
                    inline.appendText("\n")
                case "a":
                    // Anchor wrapping `<img>` falls through to the same
                    // recurse-as-block path the default case uses, so an
                    // inline GIF inside a clickable link still renders as
                    // a media block instead of a bare link label.
                    let nestedImgsInAnchor = try el.select("img")
                    if !nestedImgsInAnchor.isEmpty() {
                        flush()
                        try collectBlocks(from: el, into: &blocks)
                    } else if let resolved = try anchor(from: el) {
                        inline.appendLink(url: resolved.url, label: resolved.label)
                    } else {
                        inline.appendText(try el.text())
                    }
                default:
                    let nestedImgs = try el.select("img")
                    if !nestedImgs.isEmpty() {
                        flush()
                        try collectBlocks(from: el, into: &blocks)
                    } else {
                        try collectInlines(from: el, into: &inline)
                    }
                }
            } else if let textNode = node as? TextNode {
                inline.appendText(textNode.text())
            }
        }
        flush()
    }

    private func collectInlines(from element: Element, into inline: inout InlineAccumulator) throws {
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
                    try collectInlines(from: el, into: &inline)
                }
            } else if let textNode = node as? TextNode {
                inline.appendText(textNode.text())
            }
        }
    }

    private func imageURL(from element: Element) throws -> URL? {
        let src = try element.attr("src")
        guard !src.isEmpty,
              let url = URL(string: src, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private func firstInteger(in text: String) -> Int? {
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

    private func stripSuffix(_ s: String, suffix: String) -> String? {
        guard s.hasSuffix(suffix) else { return nil }
        return String(s.dropLast(suffix.count))
    }
}
