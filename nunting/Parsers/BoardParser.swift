import Foundation
import SwiftSoup

protocol BoardParser: Sendable {
    nonisolated var site: Site { get }
    nonisolated func parseList(html: String, board: Board) throws -> [Post]
    nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail
    nonisolated func commentsURL(for post: Post) -> URL?
    nonisolated func parseComments(html: String) throws -> [Comment]
    /// `detailHTML` is the body of `post.url` that the caller already
    /// fetched for `parseDetail`. Ppomppu/SLR/Ddanzi use it to skip a
    /// second `post.url` fetch they'd otherwise do just to pull AJAX
    /// params / first-page comment DOM. Parsers that don't need it
    /// ignore the argument.
    nonisolated func fetchAllComments(
        for post: Post,
        detailHTML: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [Comment]
}

extension BoardParser {
    nonisolated func commentsURL(for post: Post) -> URL? { nil }
    nonisolated func parseComments(html: String) throws -> [Comment] { [] }

    nonisolated func fetchAllComments(
        for post: Post,
        detailHTML: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [Comment] {
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

    /// Depth-first descendant walk that short-circuits on the first tag-name
    /// match. Replaces the `try el.select("img").isEmpty()` pattern used by
    /// `collectBlocks` / `collectInlines` in the heavier parsers. `select`
    /// parses a CSS selector and always walks every descendant, so a block
    /// that re-checks 2–3 tags against every non-media child pays an
    /// O(descendants × tags) tax per call. The walker visits each node at
    /// most once and exits the moment any tag matches, which matters for
    /// deeply-nested legacy editor output (`<table><tr><td><p>...</p>`).
    nonisolated func hasAnyDescendant(of element: Element, taggedAnyOf tags: Set<String>) -> Bool {
        for node in element.getChildNodes() {
            guard let child = node as? Element else { continue }
            if tags.contains(child.tagName().lowercased()) { return true }
            if hasAnyDescendant(of: child, taggedAnyOf: tags) { return true }
        }
        return false
    }

    /// Replace every `<a href>` descendant with a plain TextNode holding the
    /// markdown form `[label](<url>)`. Comment bodies across every site are
    /// rendered by flattening a SwiftSoup subtree with `.text()` / a manual
    /// walker, which drops the anchor's `href` — users see the label as
    /// unlinked prose. Converting anchors to markdown first lets
    /// `PostDetailView.styledContent`'s `AttributedString(markdown:)` pass
    /// turn them back into tappable `.link` spans. The `<>` wrapping around
    /// the URL is the autolink form that survives query-string characters
    /// (`?`, `&`, `=`) without needing per-URL escaping. Mutates `element`
    /// in place — callers typically pass a `.copy()`.
    nonisolated func convertAnchorsToMarkdown(in element: Element) {
        guard let anchors = try? element.select("a[href]") else { return }
        for el in anchors where el.parent() != nil {
            // Anchors that wrap an `<img>` / `<video>` are a media link
            // wrapper — the media itself is extracted through the parser's
            // separate sticker / image path, so treating the anchor as a
            // markdown link here duplicates it as a plain URL under the
            // rendered image. Mirror the body parsers' rule: when media
            // is the payload, drop the anchor (leave the `<img>` child so
            // `.text()` contributes nothing and the sticker path still
            // picks the src up).
            if hasAnyDescendant(of: el, taggedAnyOf: ["img", "video"]) {
                _ = try? el.unwrap()
                continue
            }
            let href = (try? el.attr("href")) ?? ""
            let label = ((try? el.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty,
                  let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { continue }
            let displayLabel = label.isEmpty ? url.absoluteString : label
            let safe = displayLabel
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            let markdown = "[\(safe)](<\(url.absoluteString)>)"
            _ = try? el.replaceWith(TextNode(markdown, ""))
        }
    }

    /// Inline-style visibility check. Sites sometimes stash preload/tracking
    /// `<img>` or helper markup inside a `display: none` wrapper (e.g. inven's
    /// `INVEN.Media.Resizer.collect` injects five 1px copies of every image
    /// into a hidden div at the top of the body). Browsers drop those
    /// subtrees via CSS; a plain HTML walker promotes them to image blocks
    /// unless we explicitly filter hidden ancestors. Only inspects the inline
    /// `style` attribute — class-based CSS rules would require a full
    /// stylesheet resolver and aren't what the real-world preload tricks use.
    nonisolated func isHidden(_ element: Element) -> Bool {
        guard let style = try? element.attr("style"), !style.isEmpty else { return false }
        let lower = style.lowercased()
        // Fast path: most elements aren't hidden, so bail before paying for
        // the whitespace-strip pass when the style can't possibly contain
        // `display:none` / `visibility:hidden`.
        guard lower.contains("none") || lower.contains("hidden") else { return false }
        let compact = lower.filter { !$0.isWhitespace }
        return compact.contains("display:none") || compact.contains("visibility:hidden")
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
    /// collapses runs of 4+ newlines into 3 (= up to 2 blank lines).
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
            //
            // Caveat: this math depends on the source HTML being
            // pretty-printed (1 newline of inter-tag whitespace between
            // sibling `<p>` blocks). If a board ever switches to minified
            // HTML, `<p>A</p><p>B</p>` collapses to "A\nB" and loses the
            // single blank between paragraphs. None of the boards we
            // currently parse minify, but worth re-testing if a parser
            // starts emitting visually packed text.
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
