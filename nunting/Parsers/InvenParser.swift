import Foundation
import SwiftSoup
public struct InvenParser: BoardParser {
    public let site: Site = .inven

    public nonisolated init() {}

    /// Matches decimal (`&#1234;`) and hexadecimal (`&#xAF;`) HTML numeric
    /// character references. Hoisted because `cleanCommentText` runs once per
    /// Inven comment; per-call `NSRegularExpression` construction showed up on
    /// long threads.
    nonisolated private static let numericEntityRegex = try! NSRegularExpression(
        pattern: #"&#(x?)([0-9a-fA-F]+);"#,
        options: [.caseInsensitive]
    )

    public nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        let doc = try SwiftSoup.parse(html)
        let rows = try doc.select("section.mo-board-list li.list")

        return try rows.compactMap { row -> Post? in
            guard let titleLink = try row.select("a.contentLink").first() else { return nil }
            let href = try titleLink.attr("href")
            guard let url = resolveHTTPURL(href) else { return nil }

            let title = ParserText.cleanTitle(
                try titleLink.select("span.subject").first()?.text() ?? ""
            )
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
            let viewCount = ParserText.integerFromDigits(in: viewText)
            let recoText = try row.select("span.reco").first()?.text() ?? ""
            let recommendCount = ParserText.integerFromDigits(in: recoText)
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

    public nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)
        guard let section = try doc.select("section.mo-board-view").first() else {
            // Deleted/nonexistent posts don't 404 or redirect — inven
            // answers 200 with the board's shell page (no `mo-board-view`)
            // and a visible "요청하신 페이지를 찾을 수 없습니다." notice
            // (verified against the live site, 2026-07-10). That's a valid
            // response, not a markup change, so surface a notice instead
            // of the structureChanged banner + telemetry.
            if try doc.text().contains("페이지를 찾을 수 없습니다") {
                return PostDetail(
                    post: post,
                    blocks: [.text("삭제되거나 없는 게시물입니다.")],
                    fullDateText: nil,
                    viewCount: nil,
                    source: nil,
                    comments: []
                )
            }
            throw ParserError.structureChanged("mo-board-view 없음")
        }

        guard let body = try section.select("div.bbs-con").first() else {
            throw ParserError.structureChanged("bbs-con 없음")
        }

        let imageHolder = try body.select("div#imageCollectDiv").first() ?? body
        let rules = WalkerRules.standard(for: self)
        let blocks = try ParserBlockWalker(parser: self, rules: rules).walk(imageHolder)

        let fullDateText = try section.select("div.date").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let viewText = try section.select("div.hit span").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let viewCount = ParserText.integerFromDigits(in: viewText)

        return PostDetail(
            post: post,
            blocks: blocks,
            fullDateText: fullDateText,
            viewCount: viewCount,
            source: nil,
            comments: []
        )
    }

    public nonisolated func commentsURL(for post: Post) -> URL? {
        URL(string: "https://www.inven.co.kr/common/board/comment.json.php")
    }

    public nonisolated func fetchAllComments(
        for post: Post,
        detailHTML _: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [PostComment] {
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
        let firstResponse = try Self.decodeResponse(firstData)

        let collapsed = firstResponse.commentlist
            .filter { $0.attr.titlenum > 0 && $0.list.isEmpty }
            .map { $0.attr.titlenum }

        guard !collapsed.isEmpty else {
            return convertToComments(blocks: firstResponse.commentlist)
        }

        var paramsWithTitles = baseParams
        paramsWithTitles["titles"] = collapsed.map(String.init).joined(separator: "|")
        let extraData = try await Networking.postForm(url: apiURL, parameters: paramsWithTitles, referer: post.url)
        return try comments(fromResponseData: extraData)
    }

    /// Decode one `comment.json.php` envelope and flatten it to comments.
    /// Internal so the empty-thread contract is unit-testable without a live
    /// POST: a 0-comment post returns an envelope with NO `commentlist` key
    /// (`{"message":1,"cmtcount":0,…}`), and decoding it must yield [] rather
    /// than throw — a throw here surfaces in the UI as a false
    /// "댓글 로드 실패 · 다시 시도" banner on a perfectly-loaded empty thread.
    nonisolated func comments(fromResponseData data: Data) throws -> [PostComment] {
        convertToComments(blocks: try Self.decodeResponse(data).commentlist)
    }

    nonisolated private static func decodeResponse(_ data: Data) throws -> InvenCommentResponse {
        try JSONDecoder().decode(InvenCommentResponse.self, from: data)
    }

    nonisolated private func convertToComments(blocks: [InvenCommentBlock]) -> [PostComment] {
        // titlenum 0 = latest block; positive titlenums are older slices ordered ascending.
        let sortedBlocks = blocks.sorted { lhs, rhs in
            let l = lhs.attr.titlenum == 0 ? Int.max : lhs.attr.titlenum
            let r = rhs.attr.titlenum == 0 ? Int.max : rhs.attr.titlenum
            return l < r
        }

        var results: [PostComment] = []
        for block in sortedBlocks {
            for raw in block.list {
                let stickerURL = extractStickerURL(from: raw.comment)
                let content = cleanCommentText(raw.comment)
                // Keep author-only comments — drop only the genuinely empty
                // row (no content, no sticker, no nickname).
                guard !content.isEmpty || stickerURL != nil || !raw.name.isEmpty else { continue }
                let isReply = raw.attr.cmtidx != raw.attr.cmtpidx
                results.append(PostComment(
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
        let working = Self.fullyDecodeHTMLEntities(rawHTML)

        return (try? parsedBodyFragment(working) { doc -> URL? in
            guard let img = try? doc.select("img").first(),
                  let src = try? img.attr("src"),
                  !src.isEmpty,
                  let url = URL(string: src),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            return Self.strippingResizeParam(url)
        }) ?? nil
    }

    /// Inven serves uploaded comment photos through a `?MW=360` (max-width)
    /// server resize — the markup never carries the original URL separately.
    /// Dropping the param returns the untouched upload (measured: 360×687 →
    /// 1080×2061), so the fullscreen viewer gets full resolution instead of
    /// a blurry 360px thumbnail. Stickers ship without a query and pass
    /// through unchanged. Internal for the unit test.
    nonisolated static func strippingResizeParam(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems,
              items.contains(where: { $0.name == "MW" })
        else { return url }
        let remaining = items.filter { $0.name != "MW" }
        comps.queryItems = remaining.isEmpty ? nil : remaining
        return comps.url ?? url
    }

    nonisolated private func cleanCommentText(_ raw: String) -> String {
        // Inven sometimes ships HTML that's been entity-encoded one or more
        // times (e.g. sticker comments come back as `&lt;div class=...&gt;`).
        // Peel every layer with a cheap string-level entity decoder so we
        // avoid running a full SwiftSoup parse per layer (each pass used to
        // dominate long-thread CPU profiles).
        let working = Self.fullyDecodeHTMLEntities(raw)

        // Final pass: parse as HTML so block tags get the newline marker
        // treatment (shared BoardParser comment-flatten pipeline).
        return renderCommentText(fromHTML: working)
    }

    /// Peel HTML character-reference layers until the string stops changing.
    /// `decodeHTMLEntities` is strictly reductive — it shortens or leaves the
    /// string unchanged each pass (and `&amp;` is decoded last so multiply
    /// encoded refs unwrap one layer at a time) — so the fixpoint loop always
    /// terminates without an arbitrary iteration cap. Internal (not private)
    /// so the convergence behaviour can be unit-tested directly.
    nonisolated static func fullyDecodeHTMLEntities(_ raw: String) -> String {
        var working = raw
        while working.contains("&") {
            let decoded = decodeHTMLEntities(working)
            if decoded == working { break }
            working = decoded
        }
        return working
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

        // Inven omits `commentlist` entirely on a 0-comment post
        // (`{"message":1,"cmtcount":0,…}`), so the synthesized decoder would
        // throw keyNotFound and PostDetailLoader would render a false
        // "댓글 로드 실패 · 다시 시도" banner. Default the missing key to [].
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            commentlist = try container.decodeIfPresent([InvenCommentBlock].self, forKey: .commentlist) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case commentlist
        }
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
