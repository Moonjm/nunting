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

    /// Resolve an `<a href>` element to a `(url, label)` pair, or nil if the link is
    /// non-http(s). Whitespace-only labels fall back to the URL string.
    func anchor(from element: Element) throws -> (url: URL, label: String)? {
        let href = try element.attr("href")
        guard !href.isEmpty,
              let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        let raw = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
        return (url, raw.isEmpty ? url.absoluteString : raw)
    }
}

/// Accumulates an `[InlineSegment]` for a single text block while a parser walks
/// HTML nodes. Coalesces adjacent text characters into one `.text` segment.
struct InlineAccumulator {
    private var segments: [InlineSegment] = []
    private var textBuffer: String = ""

    mutating func appendText(_ s: String) {
        textBuffer.append(s)
    }

    mutating func appendLink(url: URL, label: String) {
        flushText()
        segments.append(.link(url: url, label: label))
    }

    mutating func flushText() {
        if !textBuffer.isEmpty {
            segments.append(.text(textBuffer))
            textBuffer = ""
        }
    }

    var isEmpty: Bool {
        segments.isEmpty && textBuffer.isEmpty
    }

    /// Drain into a trimmed segment list ready for `ContentBlock.richText`.
    /// Trims leading/trailing whitespace from the first and last text segments,
    /// collapses runs of 3+ newlines into 2.
    mutating func drain() -> [InlineSegment] {
        flushText()
        let result = segments
        segments = []
        return InlineAccumulator.trimmed(result)
    }

    private static func trimmed(_ input: [InlineSegment]) -> [InlineSegment] {
        var out = input

        func collapse(_ s: String) -> String {
            s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        }

        if let first = out.first, case .text(let s) = first {
            let trimmed = collapse(s).drop(while: { $0.isWhitespace })
            if trimmed.isEmpty { out.removeFirst() } else { out[0] = .text(String(trimmed)) }
        }
        if let last = out.last, case .text(let s) = last {
            let collapsed = collapse(s)
            var end = collapsed.endIndex
            while end > collapsed.startIndex {
                let prev = collapsed.index(before: end)
                if collapsed[prev].isWhitespace { end = prev } else { break }
            }
            if end == collapsed.startIndex { out.removeLast() } else { out[out.count - 1] = .text(String(collapsed[..<end])) }
        }
        // Collapse any internal text segments' triple-newlines.
        out = out.map { seg in
            if case .text(let s) = seg { return .text(collapse(s)) }
            return seg
        }
        return out
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
