import Foundation
import SwiftSoup

struct ClienParser: BoardParser {
    let site: Site = .clien

    func parseList(html: String, board: Board) throws -> [Post] {
        let doc = try SwiftSoup.parse(html)
        let rows = try doc.select("a.list_item.symph-row")

        return try rows.compactMap { row -> Post? in
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
            let postID = boardSN.isEmpty ? url.absoluteString : boardSN

            return Post(
                id: "\(site.rawValue)-\(postID)",
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
            return PostDetail(post: post, blocks: [], images: [], fullDateText: nil, viewCount: nil)
        }

        var blocks: [ContentBlock] = []
        var images: [URL] = []

        for child in article.children() {
            try appendBlocks(from: child, into: &blocks, images: &images)
        }

        let fullDateText = try doc.select("div.post_date").first()?.text()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let viewCountText = try doc.select("div.view_count").first()?.text() ?? ""
        let viewCount = Int(viewCountText.filter(\.isNumber))

        return PostDetail(
            post: post,
            blocks: blocks,
            images: images,
            fullDateText: fullDateText,
            viewCount: viewCount
        )
    }

    private func appendBlocks(from element: Element, into blocks: inout [ContentBlock], images: inout [URL]) throws {
        let tag = element.tagName().lowercased()

        if tag == "img" {
            if let url = try imageURL(from: element) {
                blocks.append(.image(url))
                images.append(url)
            }
            return
        }

        let innerImgs = try element.select("img")
        if !innerImgs.isEmpty() {
            for img in innerImgs {
                if let url = try imageURL(from: img) {
                    blocks.append(.image(url))
                    images.append(url)
                }
            }
            let strippedText = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !strippedText.isEmpty {
                blocks.append(.text(strippedText))
            }
            return
        }

        let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            blocks.append(.text(text))
        }
    }

    private func imageURL(from element: Element) throws -> URL? {
        let src = try element.attr("src")
        guard !src.isEmpty else { return nil }
        return URL(string: src, relativeTo: site.baseURL)?.absoluteURL
    }
}
