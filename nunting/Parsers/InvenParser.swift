import Foundation
import SwiftSoup

struct InvenParser: BoardParser {
    let site: Site = .inven

    func parseList(html: String, board: Board) throws -> [Post] {
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

    func parseDetail(html: String, post: Post) throws -> PostDetail {
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

    private func collectBlocks(from element: Element, into blocks: inout [ContentBlock]) throws {
        var textBuffer = ""

        func flushText() {
            let trimmed = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if tag == "script" || tag == "style" || tag == "iframe" {
            return
        }

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
                case "script", "style", "iframe":
                    continue
                case "a":
                    if let markdown = try anchorMarkdown(from: el) {
                        textBuffer += markdown
                    } else {
                        textBuffer += try el.text()
                    }
                default:
                    let isBlock = ["p", "div", "li", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article"].contains(childTag)
                    let nestedImgs = try el.select("img")
                    let nestedVideos = try el.select("video")
                    let nestedAnchors = try el.select("a")
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

    private func imageURL(from element: Element) throws -> URL? {
        let src = try element.attr("src")
        guard !src.isEmpty,
              let url = URL(string: src, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
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

    func commentsURL(for post: Post) -> URL? {
        URL(string: "https://www.inven.co.kr/common/board/comment.json.php")
    }

    func fetchAllComments(for post: Post, fetcher: @escaping @Sendable (URL) async throws -> String) async throws -> [Comment] {
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
        let authIconURLString: String?
        if collapsed.isEmpty {
            blocks = firstResponse.commentlist
            authIconURLString = firstResponse.authicon
        } else {
            var paramsWithTitles = baseParams
            paramsWithTitles["titles"] = collapsed.map(String.init).joined(separator: "|")
            let extraData = try await Networking.postForm(url: apiURL, parameters: paramsWithTitles, referer: post.url)
            let extraResponse = try JSONDecoder().decode(InvenCommentResponse.self, from: extraData)
            blocks = extraResponse.commentlist
            authIconURLString = extraResponse.authicon ?? firstResponse.authicon
        }

        let authIconURL = authIconURLString.flatMap { URL(string: $0) }
        return convertToComments(blocks: blocks, authIconURL: authIconURL)
    }

    private func convertToComments(blocks: [InvenCommentBlock], authIconURL: URL?) -> [Comment] {
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
                let perCommentAuthIcon: URL? = (raw.authicon == true) ? authIconURL : nil
                let levelIconURL = Self.levelIconURL(level: raw.level)
                results.append(Comment(
                    id: "\(site.rawValue)-c-\(raw.attr.cmtidx)",
                    author: raw.name,
                    dateText: raw.date,
                    content: content,
                    likeCount: raw.recommend,
                    isReply: isReply,
                    stickerURL: stickerURL,
                    authIconURL: perCommentAuthIcon,
                    levelIconURL: levelIconURL
                ))
            }
        }
        return results
    }

    private func extractStickerURL(from rawHTML: String) -> URL? {
        // SwiftSoup decodes entities while parsing, so the raw entity-encoded payload
        // works directly without a manual decode pass.
        guard let doc = try? SwiftSoup.parseBodyFragment(rawHTML),
              let img = try? doc.select("img").first(),
              let src = try? img.attr("src"),
              !src.isEmpty,
              let url = URL(string: src),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private func cleanCommentText(_ raw: String) -> String {
        // SwiftSoup decodes both named and numeric entities while building the DOM,
        // and walking the DOM lets us drop tags without inventing rules for &amp; / &lt; / etc.
        guard let doc = try? SwiftSoup.parseBodyFragment(raw),
              let body = doc.body()
        else { return raw }

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
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct InvenCommentResponse: Decodable {
        let authicon: String?
        let commentlist: [InvenCommentBlock]
    }

    private struct InvenCommentBlock: Decodable {
        let attr: InvenBlockAttr
        let list: [InvenComment]

        enum CodingKeys: String, CodingKey {
            case attr = "__attr__"
            case list
        }
    }

    private struct InvenBlockAttr: Decodable {
        let titlenum: Int
    }

    private struct InvenComment: Decodable {
        let attr: InvenCommentAttr
        let date: String
        let name: String
        let comment: String
        let recommend: Int
        let authicon: Bool?
        let level: String?

        enum CodingKeys: String, CodingKey {
            case attr = "__attr__"
            case date = "o_date"
            case name = "o_name"
            case comment = "o_comment"
            case recommend = "o_recommend"
            case authicon
            case level = "o_level"
        }
    }

    private static func levelIconURL(level: String?) -> URL? {
        guard let level, !level.isEmpty else { return nil }
        return URL(string: "https://static.inven.co.kr/image_2011/member/level/1202/\(level).gif")
    }

    private struct InvenCommentAttr: Decodable {
        let cmtidx: Int
        let cmtpidx: Int
    }
}
