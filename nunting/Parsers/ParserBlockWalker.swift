import Foundation
import SwiftSoup

/// Site-specific knobs for `ParserBlockWalker`. Constructed with
/// `WalkerRules.standard` (sensible defaults that match most boards) and
/// then per-site overrides — see `PpomppuParser` / `BobaeParser` for
/// concrete examples.
public struct WalkerRules: Sendable {
    public var blockTags: Set<String>
    public var skipTags: Set<String>
    public var mediaTags: Set<String>

    /// Resolve an `<img>` element to its real source URL. Default tries
    /// `src` → `data-src` → `data-original` and rejects non-http(s).
    /// Only handles absolute http(s) URLs — sites whose `<img src>` is
    /// baseURL-relative (e.g. `/images/foo.png`) must override with a
    /// closure that calls `parser.resolveHTTPURL(...)`.
    public var resolveImageURL: @Sendable (Element) throws -> URL?

    /// Resolve a `<video>` element to its real source URL. Default tries
    /// `src` then the first `<source>` child; does not strip media
    /// fragments. Same absolute-only caveat as `resolveImageURL`.
    public var resolveVideoURL: @Sendable (Element) throws -> URL?

    /// How to materialise the resolved image URL into a `ContentBlock`.
    /// Default returns `.image(url)`. Ppomppu overrides to route `.mov`/
    /// `.mp4` URLs (mobile bug — video bytes shipped inside `<img>`) into
    /// a `.video` block.
    public var imageBlock: @Sendable (URL) -> ContentBlock

    /// Whether the walker should emit an inline link for an `<a>` whose
    /// resolved URL is `url`. Default true. Ppomppu overrides to drop the
    /// deal-link anchor that's already been promoted to a `.dealLink`
    /// block.
    public var shouldEmitAnchor: @Sendable (URL) -> Bool

    public init(
        blockTags: Set<String>,
        skipTags: Set<String>,
        mediaTags: Set<String>,
        resolveImageURL: @escaping @Sendable (Element) throws -> URL?,
        resolveVideoURL: @escaping @Sendable (Element) throws -> URL?,
        imageBlock: @escaping @Sendable (URL) -> ContentBlock,
        shouldEmitAnchor: @escaping @Sendable (URL) -> Bool
    ) {
        self.blockTags = blockTags
        self.skipTags = skipTags
        self.mediaTags = mediaTags
        self.resolveImageURL = resolveImageURL
        self.resolveVideoURL = resolveVideoURL
        self.imageBlock = imageBlock
        self.shouldEmitAnchor = shouldEmitAnchor
    }
}

extension WalkerRules {
    /// Defaults that match the historical block walker across every site.
    /// Per-site overrides patch individual closures in-place.
    public static let standard = WalkerRules(
        blockTags: [
            "p", "div", "li", "blockquote",
            "h1", "h2", "h3", "h4", "h5", "h6",
            "section", "article", "tr",
        ],
        skipTags: ["script", "style", "noscript"],
        mediaTags: ["img", "video", "iframe"],
        resolveImageURL: { el in
            for attr in ["src", "data-src", "data-original"] {
                let raw = try el.attr(attr).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                let normalized = raw.hasPrefix("//") ? "https:" + raw : raw
                guard let url = URL(string: normalized)?.absoluteURL,
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else { continue }
                return url
            }
            return nil
        },
        resolveVideoURL: { el in
            var raw = try el.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty, let source = try el.select("source").first() {
                raw = try source.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !raw.isEmpty,
                  let url = URL(string: raw)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            return url
        },
        imageBlock: { url in .image(url) },
        shouldEmitAnchor: { _ in true }
    )
}

/// Walks a SwiftSoup `Element` subtree once, emitting a `[ContentBlock]`
/// that pairs flushed `InlineAccumulator` runs with promoted media /
/// embed blocks. Delegates baseURL-aware helpers (`anchor`, `isHidden`,
/// `youtubeEmbedID`, `videoPoster`) to the host `BoardParser`.
public struct ParserBlockWalker: Sendable {
    public let parser: any BoardParser
    public let rules: WalkerRules

    public init(parser: any BoardParser, rules: WalkerRules) {
        self.parser = parser
        self.rules = rules
    }

    public func walk(_ root: Element) throws -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var inline = InlineAccumulator()
        try walkNode(root, blocks: &blocks, inline: &inline)
        flushInline(into: &blocks, inline: &inline)
        return blocks
    }

    private func flushInline(into blocks: inout [ContentBlock], inline: inout InlineAccumulator) {
        let segs = inline.drain()
        if !segs.isEmpty { blocks.append(.richText(segs)) }
    }

    private func walkNode(_ element: Element, blocks: inout [ContentBlock], inline: inout InlineAccumulator) throws {
        // Body of the walker is filled in by later tasks; for scaffolding
        // we accept any input and emit nothing — the file just needs to
        // build cleanly so later tasks can iterate test-first.
        _ = element
        _ = blocks
        _ = inline
    }
}
