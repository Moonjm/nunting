import Foundation
import SwiftSoup
public struct CoolenjoyParser: BoardParser {
    public let site: Site = .coolenjoy

    public nonisolated init() {}

    public nonisolated func parseList(html: String, board: Board) throws -> [Post] {
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

    public nonisolated func commentsURL(for post: Post) -> URL? {
        let comps = post.url.pathComponents
        guard comps.count >= 4 else { return nil }
        let boardTable = comps[2]
        let wrID = comps[3]
        return URL(string: "https://coolenjoy.net/nariya/bbs/comment_view.php?bo_table=\(boardTable)&wr_id=\(wrID)")
    }

    public nonisolated func fetchAllComments(
        for post: Post,
        detailHTML _: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [PostComment] {
        // Coolenjoy fetches its own paginated comment endpoint —
        // detailHTML is unrelated and unused here.
        guard let baseURL = commentsURL(for: post) else { return [] }

        let firstPageURL = appendingPagingParams(to: baseURL, page: 1)
        let firstHtml = try await fetcher(firstPageURL)
        let totalPages = try totalCommentPages(html: firstHtml)
        let firstPage = try parseComments(html: firstHtml)

        if totalPages <= 1 { return firstPage }

        // 병렬 fetch + 페이지 단위 실패 흡수 골격은 `mergeCommentPages` 참조.
        return try await mergeCommentPages(
            total: totalPages, inlinePage: 1, inline: firstPage
        ) { page in
            let url = self.appendingPagingParams(to: baseURL, page: page)
            let html = try await fetcher(url)
            return try self.parseComments(html: html)
        }
    }

    nonisolated private func appendingPagingParams(to url: URL, page: Int) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (comps.queryItems ?? []).filter { $0.name != "page" && $0.name != "cob" }
        items.append(URLQueryItem(name: "cob", value: "old"))
        items.append(URLQueryItem(name: "page", value: "\(page)"))
        comps.queryItems = items
        return comps.url ?? url
    }

    nonisolated private func totalCommentPages(html: String) throws -> Int {
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

    public nonisolated func parseComments(html: String) throws -> [PostComment] {
        let doc = try SwiftSoup.parse(html)
        let articles = try doc.select("article[id^=c_]")
        var results: [PostComment] = []

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

            results.append(PostComment(
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

    public nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)
        guard let article = try doc.select("article#bo_v").first() else {
            throw ParserError.structureChanged("article#bo_v 없음")
        }

        guard let contentEl = try article.select("div.view-content").first() else {
            throw ParserError.structureChanged("view-content 없음")
        }

        var rules = WalkerRules.standard(for: self)
        // Coolenjoy 옛 파서는 <a> 안쪽 media-wrap 판정에 ["img"] 만 사용했고
        // <video>/<iframe> 케이스가 없어 본문에 표시 안 함. legacy parity 유지.
        rules.mediaTags = ["img"]
        rules.skipTags.formUnion(["video", "iframe"])
        let blocks = try ParserBlockWalker(parser: self, rules: rules).walk(contentEl)

        let fullDateText = try article.select("time").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let viewCount = try metaValueInArticle(article: article, label: "조회").flatMap(ParserText.firstInteger(in:))

        return PostDetail(
            post: post,
            blocks: blocks,
            fullDateText: fullDateText,
            viewCount: viewCount,
            source: nil,
            comments: []
        )
    }

    nonisolated private func resolvePostURL(titleEl: Element, row: Element) throws -> URL? {
        let href = try titleEl.attr("href")
        // resolveHTTPURL covers the empty / scheme checks; the explicit
        // `!= "#"` guard stays because a bare "#" resolves to the board page
        // (base URL + empty fragment) and would otherwise pass.
        if href != "#", let url = resolveHTTPURL(href) {
            return url
        }
        let onclick = try row.attr("onclick")
        if let extracted = Self.extractLocationHref(from: onclick),
           let url = URL(string: extracted, relativeTo: site.baseURL)?.absoluteURL {
            return url
        }
        return nil
    }

    nonisolated private static func extractLocationHref(from onclick: String) -> String? {
        guard let start = onclick.range(of: "location.href='")?.upperBound,
              let end = onclick[start...].range(of: "'")?.lowerBound
        else { return nil }
        return String(onclick[start..<end])
    }

    nonisolated private func cleanedTitle(from anchor: Element) throws -> String {
        try anchor.select("span.sr-only").remove()
        return ParserText.cleanTitle(try anchor.text())
    }

    nonisolated private func authorName(from row: Element) throws -> String {
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

    nonisolated private func metaValue(from row: Element, label: String) throws -> String? {
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

    nonisolated private func commentCountValue(from row: Element) throws -> Int {
        guard let countEl = try row.select("span.count-plus").first() else { return 0 }
        return ParserText.integerFromDigits(in: try countEl.text()) ?? 0
    }

    nonisolated private func metaValueInArticle(article: Element, label: String) throws -> String? {
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

    nonisolated private func stripSuffix(_ s: String, suffix: String) -> String? {
        guard s.hasSuffix(suffix) else { return nil }
        return String(s.dropLast(suffix.count))
    }
}
