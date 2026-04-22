import Foundation
import SwiftSoup

protocol BoardParser: Sendable {
    nonisolated var site: Site { get }
    nonisolated func parseList(html: String, board: Board) throws -> [Post]
    nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail
    nonisolated func commentsURL(for post: Post) -> URL?
    nonisolated func parseComments(html: String) throws -> [Comment]
    nonisolated func fetchAllComments(for post: Post, fetcher: @escaping @Sendable (URL) async throws -> String) async throws -> [Comment]
}

extension BoardParser {
    nonisolated func commentsURL(for post: Post) -> URL? { nil }
    nonisolated func parseComments(html: String) throws -> [Comment] { [] }

    nonisolated func fetchAllComments(for post: Post, fetcher: @escaping @Sendable (URL) async throws -> String) async throws -> [Comment] {
        guard let url = commentsURL(for: post) else { return [] }
        let html = try await fetcher(url)
        return try parseComments(html: html)
    }

    /// Resolve an `<a href>` element to a `(url, label)` pair, or nil if the link is
    /// non-http(s). Whitespace-only labels fall back to the URL string.
    nonisolated func anchor(from element: Element) throws -> (url: URL, label: String)? {
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
struct InlineAccumulator: Sendable {
    private var segments: [InlineSegment] = []
    private var textBuffer: String = ""

    nonisolated init() {}

    nonisolated mutating func appendText(_ s: String) {
        textBuffer.append(s)
    }

    nonisolated mutating func appendLink(url: URL, label: String) {
        flushText()
        segments.append(.link(url: url, label: label))
    }

    nonisolated mutating func flushText() {
        if !textBuffer.isEmpty {
            segments.append(.text(textBuffer))
            textBuffer = ""
        }
    }

    nonisolated var isEmpty: Bool {
        segments.isEmpty && textBuffer.isEmpty
    }

    /// Drain into a trimmed segment list ready for `ContentBlock.richText`.
    /// Trims leading/trailing whitespace from the first and last text segments,
    /// collapses runs of 3+ newlines into 2.
    nonisolated mutating func drain() -> [InlineSegment] {
        flushText()
        let result = segments
        segments = []
        return InlineAccumulator.trimmed(result)
    }

    nonisolated private static func trimmed(_ input: [InlineSegment]) -> [InlineSegment] {
        var out = input

        func collapse(_ s: String) -> String {
            // Strip spaces/tabs immediately surrounding a newline first:
            // HTML pretty-print indentation leaks in via text nodes as
            // `"\n    "`, and block-boundary / <br> handlers emit explicit
            // `\n`, so the combination produces visible per-line indentation
            // when rendered. Browser HTML collapses that whitespace; we
            // match that by dropping it before normalising blank-line runs.
            var s = s.replacingOccurrences(
                of: #"[ \t]*\n[ \t]*"#,
                with: "\n",
                options: .regularExpression
            )
            // Cap at 3 consecutive `\n` (= up to 2 blank lines) so an
            // explicit user-typed blank paragraph (`<p><br></p>` between
            // two `<p>` blocks → ≥5 newlines) survives as 2 blank lines
            // instead of being squashed down to 1. Plain paragraph breaks
            // (2 newlines) still render as 1 blank line — the gap between
            // a regular `<p>A</p><p>B</p>` and an `<p>A</p><p><br></p><p>B</p>`
            // is preserved, matching the visual difference the editor
            // intends. 4+ blank lines (very rare) get capped to 2.
            s = s.replacingOccurrences(of: "\n{4,}", with: "\n\n\n", options: .regularExpression)
            return s
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
