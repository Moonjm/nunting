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
                case "br":
                    textBuffer += "\n"
                case "script", "style", "iframe":
                    continue
                default:
                    let nestedImgs = try el.select("img")
                    if !nestedImgs.isEmpty() {
                        flushText()
                        try collectBlocks(from: el, into: &blocks)
                    } else {
                        textBuffer += try el.text()
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
}
