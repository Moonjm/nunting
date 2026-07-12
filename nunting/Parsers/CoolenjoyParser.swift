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
        try parsedDocument(html) { doc in
            let items = try doc.select("ul.pagination li.page-item:not(.page-first):not(.page-prev):not(.page-next):not(.page-last)")
            var maxPage = 1
            for item in items {
                let text = try item.text().trimmingCharacters(in: .whitespacesAndNewlines)
                let digits = String(text.prefix { $0.isNumber })
                if let n = Int(digits), n > maxPage { maxPage = n }
            }
            return maxPage
        }
    }

    public nonisolated func parseComments(html: String) throws -> [PostComment] {
        try parsedDocument(html) { doc in
            let articles = try doc.select("article[id^=c_]")
            var results: [PostComment] = []

            for article in articles {
                let articleID = try article.attr("id")
                let snStart = articleID.index(articleID.startIndex, offsetBy: 2, limitedBy: articleID.endIndex)
                guard let sn = snStart.map({ String(articleID[$0...]) }), !sn.isEmpty else { continue }

                let author = try authorName(from: article)
                let dateText = try article.select("time").first()?.text()
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                // 업로드 이미지는 렌더된 `div.cmt_contents` 안 bare `<img
                // class="img-fluid">` 로만 옴(실측 2026-07-12, 29/29 article
                // 에 cmt_contents 존재). textarea 만 읽던 시절엔 이미지가
                // 통째로 사라졌다. 이모티콘(`/nariya/skin/emo/`)은 사용자
                // 첨부가 아니므로 건너뛴다. article 전체가 아니라
                // cmt_contents 로 좁히는 이유: 프로필 사진(.pf_img)·레벨
                // 배지(header) 등 chrome 이미지가 바깥에 산다.
                let stickerURL = firstImageURL(
                    in: article,
                    selector: ".cmt_contents img",
                    attributes: ["src", "data-src"],
                    skipMarkers: ["/nariya/skin/emo/"]
                )

                let rawContent = try article.select("textarea[id^=save_comment_]").first()?.text()
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let content = Self.strippingAttachmentTokens(rawContent, stickerURL: stickerURL)
                // Keep author-only comments (empty body, no media) — they
                // still render as an author line. Drop only the genuinely
                // empty row (no content, no nickname, no attachment).
                guard !content.isEmpty || !author.isEmpty || stickerURL != nil else { continue }

                let likeText = try article.select("b[id^=c_g]").first()?.text()
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                let likeCount = Int(likeText) ?? 0

                results.append(PostComment(
                    id: "\(site.rawValue)-c-\(sn)",
                    author: author,
                    dateText: dateText,
                    content: content,
                    likeCount: likeCount,
                    isReply: false,
                    stickerURL: stickerURL
                ))
            }
            return results
        }
    }

    /// nariya 에디터는 textarea 원문에 첨부 이미지를 `[URL]` 브래킷 토큰으로,
    /// 이모티콘을 `{emo:파일명:폭}` 토큰으로 남긴다. sticker 로 승격한 이미지
    /// 토큰과 이모티콘 토큰을 걷어내지 않으면 캡션에 원문 그대로 노출된다.
    /// 토큰만 있던 줄은 통째로 비워 줄바꿈 잔해도 남기지 않는다. 두 번째
    /// 이후 이미지의 `[URL]` 토큰은 남긴다 — sticker 슬롯이 하나뿐이라
    /// 지우면 그 이미지의 존재 자체가 사라진다. 유닛 테스트용 internal.
    nonisolated static func strippingAttachmentTokens(_ text: String, stickerURL: URL?) -> String {
        var working = text
        if let sticker = stickerURL {
            working = working.replacingOccurrences(of: "[\(sticker.absoluteString)]", with: "")
        }
        working = working.replacingOccurrences(
            of: #"\{emo:[^}]*\}"#, with: "", options: .regularExpression
        )
        return working
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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
