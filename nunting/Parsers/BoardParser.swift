import Foundation
import SwiftSoup

// MARK: - Closure isolation contract
//
// `fetchAllComments`의 `fetcher` 파라미터는 `@escaping @Sendable (URL) async throws -> String`
// 클로저다. Swift closure isolation default 가 컴파일 컨텍스트마다 달라서 protocol
// witness binding 이 silently 깨질 수 있는 트랩이 있다 — default 가 다르면 conforming
// 타입의 `fetchAllComments` override 가 witness signature 와 매치 안 돼서 **빌드는
// 통과하지만** default extension impl 이 dispatch 된다(=concrete override 가 죽음).
//
// 현재는 iOS 앱 타겟 하나만 conform 하고, `SWIFT_APPROACHABLE_CONCURRENCY=YES` 가
// default 를 `nonisolated(nonsending)` 으로 맞춰 두므로 트랩이 활성화될 조건은 없다.
// 이 contract 는 향후 별도 모듈/패키지에서 `BoardParser` 에 conform 할 일이 다시
// 생길 때(예: 서버 타겟이 Swift 로 회귀 etc.) 같은 closure-default 정렬을 강제하기
// 위한 문서다.
//
// regression net: `nuntingTests/ParserDispatchTests.swift` 가 `any BoardParser`
// existential 로 fetchAllComments 를 호출해 witness binding 이 살아있는지 검증.

public protocol BoardParser: Sendable {
    nonisolated var site: Site { get }
    nonisolated func parseList(html: String, board: Board) throws -> [Post]
    nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail
    nonisolated func commentsURL(for post: Post) -> URL?
    nonisolated func parseComments(html: String) throws -> [PostComment]
    /// `detailHTML` is the body of `post.url` that the caller already
    /// fetched for `parseDetail`. Ppomppu/SLR/Ddanzi use it to skip a
    /// second `post.url` fetch they'd otherwise do just to pull AJAX
    /// params / first-page comment DOM. Parsers that don't need it
    /// ignore the argument.
    nonisolated func fetchAllComments(
        for post: Post,
        detailHTML: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [PostComment]
}

extension BoardParser {
    /// Private-use sentinel that survives SwiftSoup's `.text()` whitespace
    /// collapse — stamp it where a real `\n` should appear, then swap back
    /// via `normalizeCommentWhitespace`. Value is a U+0001 control char on
    /// both sides of the literal "NL", which `.text()` treats as opaque
    /// payload rather than collapsible whitespace.
    public nonisolated static var blockMarker: String { "\u{0001}NL\u{0001}" }

    public nonisolated func commentsURL(for post: Post) -> URL? { nil }
    public nonisolated func parseComments(html: String) throws -> [PostComment] { [] }

    public nonisolated func fetchAllComments(
        for post: Post,
        detailHTML: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [PostComment] {
        guard let url = commentsURL(for: post) else { return [] }
        let html = try await fetcher(url)
        return try parseComments(html: html)
    }

    /// Resolve an `<a href>` element to a `(url, label)` pair, or nil if the link is
    /// non-http(s). Whitespace-only labels fall back to the URL string.
    public nonisolated func anchor(from element: Element) throws -> (url: URL, label: String)? {
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
    public nonisolated func hasAnyDescendant(of element: Element, taggedAnyOf tags: Set<String>) -> Bool {
        for node in element.getChildNodes() {
            guard let child = node as? Element else { continue }
            if tags.contains(child.tagName().lowercased()) { return true }
            if hasAnyDescendant(of: child, taggedAnyOf: tags) { return true }
        }
        return false
    }

    /// Replace every `<a href>` descendant with a plain TextNode holding the
    /// markdown form `[label](<url>)`. PostComment bodies across every site are
    /// rendered by flattening a SwiftSoup subtree with `.text()` / a manual
    /// walker, which drops the anchor's `href` — users see the label as
    /// unlinked prose. Converting anchors to markdown first lets
    /// `PostDetailCommentRow.styledContent`'s `AttributedString(markdown:)` pass
    /// turn them back into tappable `.link` spans. The `<>` wrapping around
    /// the URL is the autolink form that survives query-string characters
    /// (`?`, `&`, `=`) without needing per-URL escaping. Mutates `element`
    /// in place — callers typically pass a `.copy()`.
    public nonisolated func convertAnchorsToMarkdown(in element: Element) {
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
    public nonisolated func isHidden(_ element: Element) -> Bool {
        guard let style = try? element.attr("style"), !style.isEmpty else { return false }
        let lower = style.lowercased()
        // Fast path: most elements aren't hidden, so bail before paying for
        // the whitespace-strip pass when the style can't possibly contain
        // `display:none` / `visibility:hidden`.
        guard lower.contains("none") || lower.contains("hidden") else { return false }
        let compact = lower.filter { !$0.isWhitespace }
        return compact.contains("display:none") || compact.contains("visibility:hidden")
    }

    /// Stamp the block-marker sentinel immediately before every HTML block
    /// tag in the subtree so the subsequent `.text()` flatten preserves
    /// the user-visible line breaks. Paired with `normalizeCommentWhitespace`
    /// — stamp first, read `.text()`, then call normalize on the result.
    /// Tag list matches the editor-block repertoire every board uses:
    /// `<br>`, `<p>`, `<div>`, `<li>`, `<blockquote>`, `<tr>`.
    public nonisolated func stampBlockBreaks(in element: Element) {
        guard let blocks = try? element.select("br, p, div, li, blockquote, tr") else { return }
        for el in blocks where el.parent() != nil {
            _ = try? el.before(Self.blockMarker)
        }
    }

    /// Post-process the `.text()` result of a stamped subtree: swap every
    /// block-marker sentinel back to a real `\n`, strip the ASCII
    /// whitespace SwiftSoup leaves flanking each marker (otherwise lines
    /// render with a visible leading indent), and cap runs at 2 blank
    /// lines. Final trim drops leading/trailing blanks. Mirrors the logic
    /// previously duplicated across Aagag / Inven / Ppomppu comment
    /// cleaners.
    public nonisolated func normalizeCommentWhitespace(_ text: String) -> String {
        var s = text.replacingOccurrences(of: Self.blockMarker, with: "\n")
        s = s.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve a raw URL string (attribute value, style `url(...)` payload,
    /// etc.) to an absolute `http(s)` `URL` via the parser's `site.baseURL`.
    /// Trims whitespace, promotes protocol-relative `//foo.com/...` to
    /// HTTPS (every board we scrape runs on HTTPS today), then validates
    /// the final scheme so non-http(s) outputs (mailto:, data:, javascript:)
    /// never reach the image loader or video player.
    public nonisolated func resolveHTTPURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        guard let url = URL(string: normalized, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// First usable http(s) image URL among `element`'s candidate
    /// `attributes`, tried in priority order. Skips empty values and any
    /// whose value contains a `skipMarkers` substring (loading bars, icon
    /// chrome, proxy decoys), then resolves the survivor through
    /// `resolveHTTPURL` (trim, `//`→https promotion, baseURL resolution,
    /// scheme validation). Consolidates the attribute-fallback loop the
    /// per-site `<img>` resolvers (`realImageURL`, the walker's default
    /// `resolveImageURL`, the comment-sticker pickers) each hand-rolled.
    public nonisolated func imageURL(
        from element: Element,
        attributes: [String],
        skipMarkers: [String] = []
    ) -> URL? {
        for attr in attributes {
            guard let raw = try? element.attr(attr) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if skipMarkers.contains(where: trimmed.contains) { continue }
            if let url = resolveHTTPURL(trimmed) { return url }
        }
        return nil
    }

    /// First usable image URL among the `<img>` descendants matched by
    /// `selector` (default: every `<img>`), applying
    /// `imageURL(from:attributes:skipMarkers:)` to each in document order so a
    /// progress-bar / chrome `<img>` doesn't shadow a real attachment behind
    /// it. Consolidates the `extractCommentSticker` loops the Bobae / Ddanzi /
    /// Humor comment parsers each kept.
    public nonisolated func firstImageURL(
        in element: Element,
        selector: String = "img",
        attributes: [String],
        skipMarkers: [String] = []
    ) -> URL? {
        guard let imgs = try? element.select(selector) else { return nil }
        for img in imgs {
            if let url = imageURL(from: img, attributes: attributes, skipMarkers: skipMarkers) {
                return url
            }
        }
        return nil
    }

    /// HTML5 `<video poster="...">` — when present, parsers forward it so
    /// the inline tap-to-play frame shows the site's intended thumbnail
    /// rather than a plain black box. Identical enough across every
    /// video-supporting parser to live here.
    public nonisolated func videoPoster(from element: Element) throws -> URL? {
        resolveHTTPURL(try element.attr("poster"))
    }

    /// Extract a YouTube (or youtube-nocookie) video ID from a raw string
    /// — typically an `<iframe src>` value. Matches the canonical
    /// `/embed/{11-char-id}` shape used by every iframe embed code the
    /// boards generate; returns nil for non-YouTube iframes so callers
    /// can fall through to the generic skip / recurse path.
    public nonisolated func youtubeEmbedID(from src: String) -> String? {
        let ns = src as NSString
        guard let match = Self.youtubeEmbedIDRegex.firstMatch(
            in: src,
            range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// Pre-compiled once, shared across every parser instance. Hoisted
    /// because `try! NSRegularExpression(...)` at call time showed up on
    /// long comment / body traversals otherwise.
    public nonisolated static var youtubeEmbedIDRegex: NSRegularExpression {
        BoardParserRegex.youtubeEmbedID
    }
}

/// Private namespace for pre-compiled regexes the protocol extension
/// references. `BoardParserRegex` is declared with a `@unchecked Sendable`
/// conformance so its static `let` can be accessed from `nonisolated`
/// parser code under Swift 6 strict concurrency. Storing the regex in
/// a dedicated type (rather than the protocol extension, which can't
/// hold stored properties, or a top-level `let`, which inherits main-
/// actor isolation) keeps one pre-compilation shared across every
/// parser instance.
private enum BoardParserRegex {
    nonisolated static let youtubeEmbedID: NSRegularExpression = try! NSRegularExpression(
        pattern: #"youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})"#,
        options: [.caseInsensitive]
    )
    nonisolated static let brokenTrailingEntity: NSRegularExpression = try! NSRegularExpression(
        // `&#?` covers both named (`&quot`) and numeric (`&#39`, `&#x27`)
        // entities. `[A-Za-z0-9]` (not just letters) lets us catch named
        // entities that legitimately contain digits like `&sup2;`,
        // `&frac34;` if their tail is sliced.
        pattern: #"&#?[A-Za-z0-9]{1,10}(?:\.{2,}|…)\s*$"#,
        options: []
    )
}

/// Shared text-cleanup helpers reused across every parser. Pulled out of
/// the `BoardParser` protocol extension so call sites can read as a
/// neutral utility (e.g. `ParserText.cleanTitle(...)`) instead of
/// dispatching through whichever concrete parser type happens to be in
/// scope. `nonisolated` + `enum` (no instances) keeps the surface
/// callable from any `nonisolated` parser code under Swift 6 strict
/// concurrency.
public enum ParserText {
    /// Some boards (notably 82cook's enti.php list, and any aagag mirror
    /// downstream of it) truncate titles by encoded byte length, slicing in
    /// the middle of an HTML entity reference and producing trailing
    /// fragments like `&quo..` that SwiftSoup's `.text()` cannot decode.
    /// The visible result is literal `&quot;` text in the title bar. Strip
    /// the broken fragment plus its truncation marker (`..`, `...`, `…`)
    /// and replace with a clean ellipsis. Anchored by the truncation marker
    /// to avoid eating valid endings like `Q&A` or `Tom&Jerry` that don't
    /// come from a server truncation. The 1-letter prefix is intentional
    /// — byte-truncation can land anywhere inside the entity, so `&q..`
    /// is just as valid a fragment as `&quo..`. Numeric entities
    /// (`&#39;`, `&#x27;`) and digit-bearing named entities (`&sup2;`,
    /// `&frac34;`) are covered too — they show up rarely but `&#39;` for
    /// apostrophe is common in Korean board titles.
    public nonisolated static func cleanTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("&") else { return trimmed }
        let ns = trimmed as NSString
        let regex = BoardParserRegex.brokenTrailingEntity
        let range = NSRange(location: 0, length: ns.length)
        guard regex.firstMatch(in: trimmed, range: range) != nil else { return trimmed }
        return regex.stringByReplacingMatches(
            in: trimmed, range: range, withTemplate: "…"
        )
    }

    /// First contiguous run of digits in `text` as an `Int`, transparently
    /// stepping over thousands separators (`,`) inside the run and stopping at
    /// the first other non-digit. Returns nil when there's no digit at all.
    /// e.g. `"조회 1,234"` → `1234`. Shared by the Clien / Coolenjoy meta
    /// parsers, which read counts out of label-prefixed prose.
    public nonisolated static func firstInteger(in text: String) -> Int? {
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

    /// Decode JS-string escapes (`\"`, `\\`, `\/`, `\n`, `\t`, `\r`,
    /// `\uXXXX`) into their literal characters so a JS-string payload becomes
    /// valid JSON / plain text. Other backslash sequences pass the second
    /// char through unchanged.
    ///
    /// `JSON.stringify` encodes supplementary-plane characters (emoji like
    /// 🐶 = U+1F436) as a UTF-16 surrogate pair — `🐶`.
    /// `UnicodeScalar(_ v: UInt32)` returns nil for any surrogate code point
    /// (U+D800–U+DFFF) by spec, so a naive per-`\u` loop silently drops both
    /// halves and the emoji disappears. When we see a high surrogate, peek the
    /// next `\uXXXX` for a low surrogate and combine via the standard
    /// `0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)` formula. Stray
    /// (unpaired) surrogates fall through unchanged rather than emitting a
    /// replacement char — they only show up in malformed upstream payloads and
    /// we'd rather pass them along than lie. Shared by the Aagag (`AAGAG_AA.content`)
    /// and Etoland (`__next_f.push`) script-payload extractors.
    public nonisolated static func unescapeJSString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var iter = s.makeIterator()
        while let c = iter.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let next = iter.next() else { break }
            switch next {
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "/": out.append("/")
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "u":
                guard let code = readHex4(&iter) else { continue }
                if (0xD800...0xDBFF).contains(code) {
                    // High surrogate — peek `\uXXXX` low surrogate.
                    guard let backslash = iter.next(), backslash == "\\",
                          let u = iter.next(), u == "u",
                          let low = readHex4(&iter),
                          (0xDC00...0xDFFF).contains(low)
                    else {
                        // Unpaired high surrogate; emit nothing (Swift
                        // can't make a Character from it anyway).
                        continue
                    }
                    let combined = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                    if let scalar = UnicodeScalar(combined) {
                        out.append(Character(scalar))
                    }
                } else if let scalar = UnicodeScalar(code) {
                    out.append(Character(scalar))
                }
            default:
                out.append(next)
            }
        }
        return out
    }

    nonisolated private static func readHex4(_ iter: inout String.Iterator) -> UInt32? {
        var hex = ""
        for _ in 0..<4 {
            guard let h = iter.next() else { return nil }
            hex.append(h)
        }
        return UInt32(hex, radix: 16)
    }
}

/// Accumulates an `[InlineSegment]` for a single text block while a parser walks
/// HTML nodes. Coalesces adjacent text characters into one `.text` segment.
public struct InlineAccumulator: Sendable {
    private var segments: [InlineSegment] = []
    private var textBuffer: String = ""

    public nonisolated init() {}

    public nonisolated mutating func appendText(_ s: String) {
        textBuffer.append(s)
    }

    public nonisolated mutating func appendLink(url: URL, label: String) {
        flushText()
        segments.append(.link(url: url, label: label))
    }

    public nonisolated mutating func flushText() {
        if !textBuffer.isEmpty {
            segments.append(.text(textBuffer))
            textBuffer = ""
        }
    }

    public nonisolated var isEmpty: Bool {
        segments.isEmpty && textBuffer.isEmpty
    }

    /// Drain into a trimmed segment list ready for `ContentBlock.richText`.
    /// Trims leading/trailing whitespace from the first and last text segments,
    /// collapses runs of 4+ newlines into 3 (= up to 2 blank lines).
    public nonisolated mutating func drain() -> [InlineSegment] {
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

public enum ParserError: Error, LocalizedError {
    case missingField(String)
    case invalidHTML
    case structureChanged(String)
    case unsupportedSite(Site)

    public var errorDescription: String? {
        switch self {
        case .missingField(let field): "파싱 실패: \(field) 누락"
        case .invalidHTML: "HTML 파싱 실패"
        case .structureChanged(let detail): "사이트 구조가 바뀐 것 같아요 (\(detail))"
        case .unsupportedSite(let site): "\(site.displayName)은 아직 지원하지 않습니다"
        }
    }
}
