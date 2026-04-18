import Foundation
import SwiftSoup

protocol BoardParser {
    var site: Site { get }
    func parseList(html: String, board: Board) throws -> [Post]
    func parseDetail(html: String, post: Post) throws -> PostDetail
    func commentsURL(for post: Post) -> URL?
    func parseComments(html: String) throws -> [Comment]
    func fetchAllComments(for post: Post, fetcher: @escaping @Sendable (URL) async throws -> String) async throws -> [Comment]
}

extension BoardParser {
    func commentsURL(for post: Post) -> URL? { nil }
    func parseComments(html: String) throws -> [Comment] { [] }

    func fetchAllComments(for post: Post, fetcher: @escaping @Sendable (URL) async throws -> String) async throws -> [Comment] {
        guard let url = commentsURL(for: post) else { return [] }
        let html = try await fetcher(url)
        return try parseComments(html: html)
    }

    /// Convert an `<a href>` element into a markdown link (`[label](<url>)`) usable by
    /// `AttributedString(markdown:)`. Returns nil when the href is missing or non-http(s).
    func anchorMarkdown(from element: Element) throws -> String? {
        let href = try element.attr("href")
        guard !href.isEmpty,
              let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        let label = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLabel = label.isEmpty ? url.absoluteString : label
        let safeLabel = displayLabel
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(safeLabel)](<\(url.absoluteString)>)"
    }
}

enum ParserError: Error, LocalizedError {
    case missingField(String)
    case invalidHTML
    case structureChanged(String)
    case unsupportedSite(Site)

    var errorDescription: String? {
        switch self {
        case .missingField(let field): "파싱 실패: \(field) 누락"
        case .invalidHTML: "HTML 파싱 실패"
        case .structureChanged(let detail): "사이트 구조가 바뀐 것 같아요 (\(detail))"
        case .unsupportedSite(let site): "\(site.displayName)은 아직 지원하지 않습니다"
        }
    }
}
