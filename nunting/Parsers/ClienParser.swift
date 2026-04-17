import Foundation
import SwiftSoup

struct ClienParser: BoardParser {
    let site: Site = .clien

    func parseList(html: String, board: Board) throws -> [Post] {
        let doc = try SwiftSoup.parse(html)
        let rows = try doc.select("div.list_item.symph_row")

        return try rows.compactMap { row -> Post? in
            guard let titleEl = try row.select("a.list_subject").first() else { return nil }
            let title = try titleEl.select("span.subject_fixed").first()?.text()
                ?? titleEl.text()
            let href = try titleEl.attr("href")
            guard !href.isEmpty,
                  let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL
            else { return nil }

            let author = try row.select("span.nickname").first()?.text() ?? ""
            let dateText = try row.select("span.timestamp").first()?.text()
                ?? row.select("span.time").first()?.text()
                ?? ""
            let commentText = try row.select("a.list_reply span.rSymph05").first()?.text() ?? "0"
            let commentCount = Int(commentText.trimmingCharacters(in: .whitespaces)) ?? 0

            let postID = url.lastPathComponent.isEmpty ? href : url.lastPathComponent

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
