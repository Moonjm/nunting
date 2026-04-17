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
        let contentEl = try doc.select("div.post_article").first()
            ?? doc.select("div.post_content").first()
        let contentHTML = try contentEl?.html() ?? ""

        let imageElements = try doc.select("div.post_article img, div.post_content img")
        let images: [URL] = imageElements.compactMap { img in
            guard let src = try? img.attr("src"), !src.isEmpty else { return nil }
            return URL(string: src, relativeTo: site.baseURL)?.absoluteURL
        }

        return PostDetail(post: post, contentHTML: contentHTML, images: images)
    }
}
