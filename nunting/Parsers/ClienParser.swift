import Foundation
import SwiftSoup

struct ClienParser: BoardParser {
    let site: Site = .clien

    func parseList(html: String, board: Board) throws -> [Post] {
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

    func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)
        guard let article = try doc.select("div.post_article").first() else {
            throw ParserError.structureChanged("post_article 없음")
        }

        let (source, skipFirstParagraph) = try extractSource(from: article)

        var blocks: [ContentBlock] = []
        let children = article.children()
        for (index, child) in children.enumerated() {
            if skipFirstParagraph && index == 0 { continue }
            try collectBlocks(from: child, into: &blocks)
        }

        let fullDateText = try doc.select("div.post_date").first()?.text()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func extractSource(from article: Element) throws -> (source: PostSource?, skipFirstParagraph: Bool) {
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
            if let resolved = try anchor(from: element) {
                inline.appendLink(url: resolved.url, label: resolved.label)
                flush()
            }
            return
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
                    if let resolved = try anchor(from: el) {
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

    private func parseComments(doc: Document) throws -> [Comment] {
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
}
