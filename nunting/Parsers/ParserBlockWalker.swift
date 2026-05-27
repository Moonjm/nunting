import Foundation
import SwiftSoup

/// Site-specific knobs for `ParserBlockWalker`. Constructed with
/// `WalkerRules.standard(for:)` (sensible defaults that match most boards) and
/// then per-site overrides — see `PpomppuParser` / `BobaeParser` for
/// concrete examples.
public struct WalkerRules: Sendable {
    public var blockTags: Set<String>
    public var skipTags: Set<String>
    public var mediaTags: Set<String>

    /// Resolve an `<img>` element to its real source URL. `WalkerRules.standard(for:)`
    /// tries `src` → `data-src` → `data-original`, delegating each candidate to
    /// `parser.resolveHTTPURL` for baseURL resolution and scheme validation.
    public var resolveImageURL: @Sendable (Element) throws -> URL?

    /// Resolve a `<video>` element to its real source URL. `WalkerRules.standard(for:)`
    /// tries `data-src` then `src` on the `<video>` element and its first
    /// `<source>` child, delegating each candidate to `parser.resolveHTTPURL`.
    /// Also strips `#t=…` media fragments — AVPlayer treats them as seek
    /// targets and breaks the initial-frame render.
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

    /// First-crack handler that lets per-site logic claim arbitrary
    /// elements (e.g. a custom React media-player wrapper whose sibling
    /// overlay divs would otherwise leak text into the body). Returning
    /// a non-nil array — even an empty one — tells the walker:
    /// "I consumed this element; flush pending inline, append the blocks
    /// I'm handing you (if any), and skip recursion into the element's
    /// children." Returning `nil` lets the walker fall through to its
    /// standard tag dispatch (`img`/`video`/`iframe`/`a`/`br`/blockTags).
    /// `WalkerRules.standard(for:)` defaults this to `{ _ in nil }`.
    public var customElement: @Sendable (Element) throws -> [ContentBlock]?

    public init(
        blockTags: Set<String>,
        skipTags: Set<String>,
        mediaTags: Set<String>,
        resolveImageURL: @escaping @Sendable (Element) throws -> URL?,
        resolveVideoURL: @escaping @Sendable (Element) throws -> URL?,
        imageBlock: @escaping @Sendable (URL) -> ContentBlock,
        shouldEmitAnchor: @escaping @Sendable (URL) -> Bool,
        customElement: @escaping @Sendable (Element) throws -> [ContentBlock]?
    ) {
        self.blockTags = blockTags
        self.skipTags = skipTags
        self.mediaTags = mediaTags
        self.resolveImageURL = resolveImageURL
        self.resolveVideoURL = resolveVideoURL
        self.imageBlock = imageBlock
        self.shouldEmitAnchor = shouldEmitAnchor
        self.customElement = customElement
    }
}

extension WalkerRules {
    /// Build a `WalkerRules` whose URL-resolution defaults delegate to
    /// `parser.resolveHTTPURL(...)` — so baseURL-relative `<img src>` /
    /// `<video src>` values are promoted to absolute http(s) URLs against
    /// the site's `baseURL`. Per-site overrides patch individual closures
    /// in-place after construction.
    public static func standard(for parser: any BoardParser) -> WalkerRules {
        WalkerRules(
            blockTags: [
                "p", "div", "li", "blockquote",
                "h1", "h2", "h3", "h4", "h5", "h6",
                "section", "article", "tr",
            ],
            skipTags: ["script", "style", "noscript"],
            mediaTags: ["img", "video", "iframe"],
            resolveImageURL: { el in
                for attr in ["src", "data-src", "data-original"] {
                    let raw = try el.attr(attr)
                    if let url = parser.resolveHTTPURL(raw) { return url }
                }
                return nil
            },
            resolveVideoURL: { el in
                // 사이트별로 lazy-load 를 위해 data-src 를 우선 채우는 케이스가
                // 흔해서 data-src → src 순으로 시도. `<source>` 자식도 동일.
                var raw = try el.attr("data-src")
                if raw.isEmpty { raw = try el.attr("src") }
                if raw.isEmpty, let source = try el.select("source").first() {
                    let sData = try source.attr("data-src")
                    raw = !sData.isEmpty ? sData : (try source.attr("src"))
                }
                // `#t=0.05` 같은 media fragment 는 AVPlayer 가 seek target 으로
                // 해석해 첫 프레임 렌더를 깨므로 플랫폼 공통으로 strip.
                if let hash = raw.firstIndex(of: "#") {
                    raw = String(raw[..<hash])
                }
                return parser.resolveHTTPURL(raw)
            },
            imageBlock: { url in .image(url) },
            shouldEmitAnchor: { _ in true },
            customElement: { _ in nil }
        )
    }
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

    /// Walks the subtree rooted at `root`, emitting blocks in source order.
    ///
    /// **Inline accumulator semantics:** a single `InlineAccumulator` is
    /// threaded through the entire walk and only flushed when media /
    /// embed blocks are encountered (or at the very end). This intentionally
    /// merges consecutive `<div>` / `<p>` blocks into a single `.richText`
    /// run instead of producing one block per source-level container — the
    /// downstream renderer treats consecutive richText blocks the same way,
    /// so the merge is semantically equivalent but produces fewer (and
    /// therefore cheaper) blocks. Sites that need per-container blocks
    /// would have to add their own block-splitting hook; the pilot
    /// parsers do not.
    public nonisolated func walk(_ root: Element) throws -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        var inline = InlineAccumulator()
        try walkNode(root, blocks: &blocks, inline: &inline)
        flushInline(into: &blocks, inline: &inline)
        return blocks
    }

    private nonisolated func flushInline(into blocks: inout [ContentBlock], inline: inout InlineAccumulator) {
        let segs = inline.drain()
        if !segs.isEmpty { blocks.append(.richText(segs)) }
    }

    private nonisolated func walkNode(_ element: Element, blocks: inout [ContentBlock], inline: inout InlineAccumulator) throws {
        if parser.isHidden(element) { return }
        let tag = element.tagName().lowercased()
        if rules.skipTags.contains(tag) { return }

        for node in element.getChildNodes() {
            if let child = node as? Element {
                try walkChild(child, blocks: &blocks, inline: &inline)
            } else if let textNode = node as? TextNode {
                let raw = textNode.text()
                if !raw.isEmpty { inline.appendText(raw) }
            }
        }
    }

    private nonisolated func walkChild(_ el: Element, blocks: inout [ContentBlock], inline: inout InlineAccumulator) throws {
        if parser.isHidden(el) { return }
        let tag = el.tagName().lowercased()
        if rules.skipTags.contains(tag) { return }

        // First-crack handler. If site-specific code claims this element
        // (e.g. an Etoland custom video-player wrapper), respect its
        // decision: flush pending inline, emit whatever blocks it returns,
        // and skip recursion. Empty array still claims the element —
        // useful for "drop this entire subtree" without emitting anything.
        if let customBlocks = try rules.customElement(el) {
            if !customBlocks.isEmpty {
                flushInline(into: &blocks, inline: &inline)
                blocks.append(contentsOf: customBlocks)
            }
            return
        }

        switch tag {
        case "br":
            inline.appendText("\n")
            return
        case "img":
            if let url = try rules.resolveImageURL(el) {
                flushInline(into: &blocks, inline: &inline)
                blocks.append(rules.imageBlock(url))
            }
            return
        case "video":
            if let url = try rules.resolveVideoURL(el) {
                flushInline(into: &blocks, inline: &inline)
                blocks.append(.video(url, posterURL: try parser.videoPoster(from: el)))
            }
            return
        case "iframe":
            // SwiftSoup `attr(_:)` 는 missing 시 throw 가 아니라 ""를 반환.
            // `walkChild` 자체가 throws 이므로 `try?` 로 감쌀 필요 없음.
            let src = try el.attr("src")
            if let id = parser.youtubeEmbedID(from: src) {
                flushInline(into: &blocks, inline: &inline)
                blocks.append(.embed(.youtube, id: id))
            }
            return
        case "a":
            // Anchors wrapping `<img>` / `<video>` / `<iframe>` are media link
            // wrappers — recurse so the nested media becomes a real block, and
            // skip the anchor's own label (the media is the payload).
            if parser.hasAnyDescendant(of: el, taggedAnyOf: rules.mediaTags) {
                flushInline(into: &blocks, inline: &inline)
                try walkNode(el, blocks: &blocks, inline: &inline)
                return
            }
            if let resolved = try parser.anchor(from: el) {
                if rules.shouldEmitAnchor(resolved.url) {
                    inline.appendLink(url: resolved.url, label: resolved.label)
                }
            } else {
                // Intentional: when `anchor(from:)` returns nil (non-http(s)
                // scheme — mailto:, javascript:void(0), empty href, bare
                // `#anchor`), preserve the visible label as plain text so
                // user-typed prose around a broken / decorative link
                // doesn't silently vanish. Matches pre-refactor Bobae /
                // Ppomppu convention. SwiftSoup's `.text()` flattens nested
                // structure, which is acceptable here because the only
                // payload a non-link anchor carries is its label.
                inline.appendText(try el.text())
            }
            return
        default:
            break
        }

        // Default: recurse and (if the child is a block-level tag) stamp a
        // newline at the end so subsequent siblings sit on a new line.
        try walkNode(el, blocks: &blocks, inline: &inline)
        if rules.blockTags.contains(tag) {
            inline.appendText("\n")
        }
    }
}
