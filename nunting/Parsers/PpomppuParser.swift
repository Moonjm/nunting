import Foundation
import SwiftSoup

struct PpomppuParser: BoardParser {
    let site: Site = .ppomppu

    private static let blockTags: Set<String> = [
        "p", "div", "li", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "tr",
    ]

    private static let skipTags: Set<String> = ["script", "style", "iframe", "noscript"]

    func parseList(html: String, board: Board) throws -> [Post] {
        let doc = try SwiftSoup.parse(html)
        let boardID = ppomppuBoardID(from: board)

        var rows = try doc.select("ul.bbsList_new > li").array()
        if rows.isEmpty {
            rows = try doc.select("ul.bbsList > li").array()
        }

        return try rows.compactMap { row -> Post? in
            // Skip pinned-by-popularity rows that break chronological order.
            let rowClasses = (try? row.attr("class")) ?? ""
            if rowClasses.contains("hotpop_bg_color") { return nil }

            guard let link = try row.select("a[href*=bbs_view.php]").first() else { return nil }
            let href = try link.attr("href")
            guard !href.isEmpty,
                  let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }

            // Skip sponsored / cross-board entries (e.g. id=sponsor at top of freeboard).
            if let postBoardID = queryValue(in: url, name: "id"), postBoardID != boardID {
                return nil
            }

            let titleEl = try row.select("li.title span.cont").first()
                ?? row.select("strong").first()
            guard let titleEl else { return nil }

            let titleCopy = titleEl.copy() as? Element ?? titleEl
            try titleCopy.select("img, span.rp, sup, .baseList-img").remove()
            let title = try titleCopy.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }

            let commentText = try row.select("span.rp").first()?.text() ?? ""
            let commentCount = Int(commentText.filter(\.isNumber)) ?? 0

            let dateText = try row.select("time").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let viewText = try row.select(".view, span.view").first()?.text() ?? ""
            let viewCount = viewText.isEmpty ? nil : Int(viewText.filter(\.isNumber))

            let recoEl = try row.select("span.recs.blue, span.rec.blue").first()
            let recoText = try recoEl?.text() ?? ""
            let recommendCount = recoText.isEmpty ? nil : Int(recoText.filter(\.isNumber))

            let namesText = try row.select("li.names, span.names").first()?.text() ?? ""
            let (category, author) = splitCategoryAuthor(namesText)

            let postNo = queryValue(in: url, name: "no")
                ?? url.pathComponents.last
                ?? url.absoluteString
            let cleanURL = strippingPageQuery(url)

            return Post(
                id: "\(board.id)-\(postNo)",
                site: site,
                boardID: board.id,
                title: title,
                author: author,
                date: nil,
                dateText: dateText,
                commentCount: commentCount,
                url: cleanURL,
                viewCount: viewCount,
                recommendCount: recommendCount,
                levelText: category,
                hasAuthIcon: false
            )
        }
    }

    func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)
        guard let view = try doc.select("div.bbs.view, div.bbs_view, div.view").first() else {
            throw ParserError.structureChanged("bbs.view 없음")
        }

        guard let content = try view.select("div.cont#KH_Content, div#KH_Content, div.cont").first() else {
            throw ParserError.structureChanged("KH_Content 없음")
        }

        var blocks: [ContentBlock] = []
        if let dealLink = try dealLinkBlock(from: view) {
            blocks.append(dealLink)
        }
        try collectBlocks(from: content, into: &blocks)
        blocks = mergeAdjacentText(blocks)

        let header = try view.select("h4").first()
        let fullDateText = try header?.select("span.hi").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let viewCount: Int? = try {
            guard let header else { return nil }
            let headerText = try header.text()
            // Header text contains "조회 : 15016".
            guard let range = headerText.range(of: "조회") else { return nil }
            let tail = headerText[range.upperBound...]
            let digits = tail.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber || $0 == "," })
            return Int(digits.filter(\.isNumber))
        }()

        let comments = try parseComments(in: doc)

        return PostDetail(
            post: post,
            blocks: blocks,
            fullDateText: fullDateText,
            viewCount: viewCount,
            source: nil,
            comments: comments
        )
    }

    func commentsURL(for post: Post) -> URL? {
        // Comments are embedded in the detail page; pagination uses ?c_page=N on the same URL.
        post.url
    }

    func fetchAllComments(for post: Post, fetcher: @escaping @Sendable (URL) async throws -> String) async throws -> [Comment] {
        let firstHtml = try await fetcher(post.url)
        let firstDoc = try SwiftSoup.parse(firstHtml)
        let firstPage = try parseComments(in: firstDoc)
        let totalPages = try totalCommentPages(in: firstDoc)
        if totalPages <= 1 { return firstPage }

        var pageMap: [Int: [Comment]] = [1: firstPage]
        try await withThrowingTaskGroup(of: (Int, [Comment]).self) { group in
            for page in 2...totalPages {
                guard let pageURL = appendingCommentPage(to: post.url, page: page) else { continue }
                group.addTask {
                    let html = try await fetcher(pageURL)
                    let comments = try self.parseComments(html: html)
                    return (page, comments)
                }
            }
            for try await (page, comments) in group {
                pageMap[page] = comments
            }
        }
        return (1...totalPages).flatMap { pageMap[$0] ?? [] }
    }

    func parseComments(html: String) throws -> [Comment] {
        let doc = try SwiftSoup.parse(html)
        return try parseComments(in: doc)
    }

    private func parseComments(in doc: Document) throws -> [Comment] {
        let nodes = try doc.select("div.cmAr div[class*=sect-cmt]")
        var results: [Comment] = []
        for node in nodes {
            // Ignore nested wrappers if any: only take elements whose own class includes sect-cmt.
            let classAttr = (try? node.attr("class")) ?? ""
            let classTokens = classAttr.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard classTokens.contains("sect-cmt") else { continue }

            let depthAttr = try node.attr("data-depth")
            let isReply = (Int(depthAttr) ?? 0) > 0

            // Comment ID lives on the preceding anchor, or inside ctx_{id}.
            let cmtID: String = try {
                if let anchor = try node.previousElementSibling(),
                   anchor.tagName().lowercased() == "a" {
                    let id = try anchor.attr("id")
                    if !id.isEmpty { return id }
                }
                if let ctx = try node.select("[id^=ctx_]").first() {
                    let raw = try ctx.attr("id")
                    return String(raw.dropFirst(4))
                }
                return UUID().uuidString
            }()

            let writerEl = try node.select("h6.com_name span.com_name_writer").first()
            let writerCopy = writerEl.flatMap { $0.copy() as? Element } ?? writerEl
            try writerCopy?.select("i, span, img").remove()
            let author = try writerCopy?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let levelClass = try node.select("h6.com_name i.nlevel").first()
                .flatMap { try? $0.classNames() }
                .flatMap { $0.first(where: { $0.hasPrefix("lv") }) }
            let levelIconURL = Self.levelIconURL(level: levelClass)

            let likeText = try node.select("[id^=vote_cnt_]").first()?.text() ?? "0"
            let likeCount = Int(likeText.filter(\.isNumber)) ?? 0

            let dateText = try node.select("div.cin_02 time").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let contentEl = try node.select("[id^=ctx_]").first()
            let content = try contentEl.map { try cleanCommentText(from: $0) } ?? ""
            let stickerURL = try contentEl.flatMap { try extractStickerURL(from: $0) }

            guard !content.isEmpty || stickerURL != nil else { continue }

            results.append(Comment(
                id: "\(site.rawValue)-c-\(cmtID)",
                author: author,
                dateText: dateText,
                content: content,
                likeCount: likeCount,
                isReply: isReply,
                stickerURL: stickerURL,
                authIconURL: nil,
                levelIconURL: levelIconURL
            ))
        }
        return results
    }

    private func totalCommentPages(in doc: Document) throws -> Int {
        guard let pageEl = try doc.select("div.cmt-topInfo span.cmt-page").first() else { return 1 }
        let text = try pageEl.text()
        // Format: "1 / N"
        let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let total = Int(parts[1].filter(\.isNumber)) else { return 1 }
        return max(1, total)
    }

    private func appendingCommentPage(to url: URL, page: Int) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (comps.queryItems ?? []).filter { $0.name != "c_page" }
        items.append(URLQueryItem(name: "c_page", value: "\(page)"))
        comps.queryItems = items
        return comps.url
    }

    private func collectBlocks(from element: Element, into blocks: inout [ContentBlock]) throws {
        var textBuffer = ""

        func flushText() {
            let trimmed = textBuffer
                .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                blocks.append(.text(trimmed))
            }
            textBuffer = ""
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
                blocks.append(.video(url))
            }
            return
        }
        if Self.skipTags.contains(tag) { return }

        for node in element.getChildNodes() {
            if let el = node as? Element {
                let childTag = el.tagName().lowercased()
                switch childTag {
                case "img":
                    flushText()
                    if let url = try imageURL(from: el) {
                        blocks.append(.image(url))
                    }
                case "video":
                    flushText()
                    if let url = try videoURL(from: el) {
                        blocks.append(.video(url))
                    }
                case "br":
                    textBuffer += "\n"
                case "a":
                    if let markdown = try anchorMarkdown(from: el) {
                        textBuffer += markdown
                    } else {
                        textBuffer += try el.text()
                    }
                default:
                    if Self.skipTags.contains(childTag) { continue }
                    let nestedImgs = try el.select("img")
                    let nestedVideos = try el.select("video")
                    let nestedAnchors = try el.select("a")
                    let isBlock = Self.blockTags.contains(childTag)
                    if !nestedImgs.isEmpty() || !nestedVideos.isEmpty() || !nestedAnchors.isEmpty() {
                        flushText()
                        try collectBlocks(from: el, into: &blocks)
                    } else {
                        textBuffer += try el.text()
                    }
                    if isBlock {
                        textBuffer += "\n"
                    }
                }
            } else if let textNode = node as? TextNode {
                textBuffer += textNode.text()
            }
        }
        flushText()
    }

    private func mergeAdjacentText(_ blocks: [ContentBlock]) -> [ContentBlock] {
        var result: [ContentBlock] = []
        for block in blocks {
            if case .text(let next) = block.kind,
               let last = result.last,
               case .text(let prev) = last.kind {
                result.removeLast()
                result.append(.text(prev + "\n\n" + next))
            } else {
                result.append(block)
            }
        }
        return result
    }

    private func imageURL(from element: Element) throws -> URL? {
        var src = try element.attr("src")
        if src.isEmpty {
            src = try element.attr("data-src")
        }
        guard !src.isEmpty,
              let url = URL(string: src, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private func dealLinkBlock(from view: Element) throws -> ContentBlock? {
        // Mobile: <div class="link-box"> inside <h4>.
        // Desktop: <li class="topTitle-link partner"> inside <ul class="topTitle-mainbox">.
        let anchor = try view.select("div.link-box a[href], li.topTitle-link a[href]").first()
        guard let anchor, let markdown = try anchorMarkdown(from: anchor) else { return nil }
        return .text("🔗 \(markdown)")
    }

    private func videoURL(from element: Element) throws -> URL? {
        let dataSrc = try element.attr("data-src")
        let raw = dataSrc.isEmpty ? try element.attr("src") : dataSrc
        guard !raw.isEmpty,
              let url = URL(string: raw, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private func extractStickerURL(from element: Element) throws -> URL? {
        guard let img = try element.select("img").first() else { return nil }
        return try imageURL(from: img)
    }

    private func cleanCommentText(from element: Element) throws -> String {
        let copy = (element.copy() as? Element) ?? element
        try copy.select("img, script, style").remove()
        let blockMarker = "\u{0001}NL\u{0001}"
        let blocks = try copy.select("br, p, div, li, blockquote, tr")
        for el in blocks where el.parent() != nil {
            try? el.before(blockMarker)
        }
        let text = try copy.text()
        var result = text.replacingOccurrences(of: blockMarker, with: "\n")
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitCategoryAuthor(_ raw: String) -> (category: String?, author: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") else { return (nil, trimmed) }
        guard let close = trimmed.firstIndex(of: "]") else { return (nil, trimmed) }
        let category = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        let rest = trimmed[trimmed.index(after: close)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (category.isEmpty ? nil : category, rest)
    }

    private func queryValue(in url: URL, name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private func strippingPageQuery(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = comps.queryItems?.filter { $0.name != "page" }
        if comps.queryItems?.isEmpty == true { comps.queryItems = nil }
        return comps.url ?? url
    }

    private func ppomppuBoardID(from board: Board) -> String? {
        guard let comps = URLComponents(string: board.path) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "id" })?.value
    }

    private static func levelIconURL(level: String?) -> URL? {
        // Ppomppu levels are CSS sprites without standalone image URLs; show plain text instead.
        _ = level
        return nil
    }
}
