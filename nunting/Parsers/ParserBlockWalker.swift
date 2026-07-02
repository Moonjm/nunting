import Foundation
import SwiftSoup

/// Site-specific knobs for `ParserBlockWalker`. Constructed with
/// `WalkerRules.standard(for:)` (sensible defaults that match most boards) and
/// then per-site overrides — see `PpomppuParser` / `BobaeParser` for
/// concrete examples.
nonisolated public struct WalkerRules: Sendable {
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
    /// `aspect` is the `<img>`'s declared width/height ratio (nil when the
    /// markup carried none). Default returns `.image(url, aspectRatio: aspect)`.
    /// Ppomppu overrides to route `.mov`/`.mp4` URLs (mobile bug — video bytes
    /// shipped inside `<img>`) into a `.video` block.
    public var imageBlock: @Sendable (URL, CGFloat?) -> ContentBlock

    /// Whether the walker should emit an inline link for an `<a>` whose
    /// resolved URL is `url`. Default true. Ppomppu overrides to drop the
    /// deal-link anchor that's already been promoted to a `.dealLink`
    /// block.
    public var shouldEmitAnchor: @Sendable (URL) -> Bool

    /// First-crack handler that lets per-site logic claim arbitrary
    /// elements (e.g. a custom React media-player wrapper whose sibling
    /// overlay divs would otherwise leak text into the body). Returning
    /// a non-nil array — even an empty one — tells the walker:
    /// "I consumed this element; skip recursion into the element's children."
    /// Non-empty arrays also flush pending inline before appending the handed
    /// blocks. Returning `nil` lets the walker fall through to its
    /// standard tag dispatch (`img`/`video`/`iframe`/`a`/`br`/blockTags).
    /// `WalkerRules.standard(for:)` defaults this to `{ _ in nil }`.
    public var customElement: @Sendable (Element) throws -> [ContentBlock]?

    public nonisolated init(
        blockTags: Set<String>,
        skipTags: Set<String>,
        mediaTags: Set<String>,
        resolveImageURL: @escaping @Sendable (Element) throws -> URL?,
        resolveVideoURL: @escaping @Sendable (Element) throws -> URL?,
        imageBlock: @escaping @Sendable (URL, CGFloat?) -> ContentBlock,
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
    public nonisolated static func standard(for parser: any BoardParser) -> WalkerRules {
        WalkerRules(
            blockTags: [
                "p", "div", "li", "blockquote",
                "h1", "h2", "h3", "h4", "h5", "h6",
                "section", "article", "tr",
            ],
            skipTags: ["script", "style", "noscript"],
            mediaTags: ["img", "video", "iframe"],
            resolveImageURL: { parser.imageURL(from: $0, attributes: ["src", "data-src", "data-original"]) },
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
            imageBlock: { url, aspect in .image(url, aspectRatio: aspect) },
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

    public nonisolated init(parser: any BoardParser, rules: WalkerRules) {
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
        // decision: emit whatever blocks it returns and skip recursion.
        // Empty array still claims the element — useful for "drop this
        // entire subtree" without splitting surrounding inline text.
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
                // 디코드 없이 마크업의 선언 치수로 aspect 를 뽑아 image 블록에
                // 싣는다 — placeholder 높이 핀(동시 디코드 throttle) + off-screen
                // release 가드 통과. el 은 이미 파싱된 노드라 새 parse 없음.
                let aspect = Self.declaredAspectRatio(
                    style: (try? el.attr("style")) ?? "",
                    width: (try? el.attr("width")) ?? "",
                    height: (try? el.attr("height")) ?? ""
                )
                blocks.append(rules.imageBlock(url, aspect))
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

    /// Parse an `<img>`'s *declared* aspect ratio (width / height) from its
    /// markup, without decoding the image. Priority:
    ///   1. CSS `aspect-ratio: W / H` (what Inven emits)
    ///   2. `width` / `height` attributes (older markup)
    ///   3. CSS `width: Wpx; height: Hpx`
    /// Returns nil when no usable positive dimensions are declared — the
    /// caller then leaves `aspectRatio` nil and `NetworkImage` applies its
    /// fallback. Pure string parsing (no SwiftSoup, no per-call regex alloc)
    /// so it adds zero parse/leak surface to the existing detail walk.
    nonisolated static func declaredAspectRatio(style: String, width: String, height: String) -> CGFloat? {
        let lowered = style.lowercased()

        // 1. CSS `aspect-ratio: W / H` — 인벤 본문 이미지가 주는 형식.
        if let raw = cssDeclaration("aspect-ratio", in: lowered) {
            let parts = raw.split(separator: "/")
            if parts.count == 2,
               let w = Double(parts[0].trimmingCharacters(in: .whitespaces)),
               let h = Double(parts[1].trimmingCharacters(in: .whitespaces)),
               w > 0, h > 0 {
                return CGFloat(w / h)
            }
        }

        // 2. `width` / `height` 속성 (예전 마크업).
        if let w = Double(width), let h = Double(height), w > 0, h > 0 {
            return CGFloat(w / h)
        }

        // 3. CSS `width: Wpx; height: Hpx`.
        if let w = cssPixels("width", in: lowered), let h = cssPixels("height", in: lowered), w > 0, h > 0 {
            return CGFloat(w / h)
        }

        return nil
    }

    /// `style` 문자열에서 정확히 `name` 인 선언의 값을 반환(`;` 로 split 후
    /// 첫 `:` 기준 prop/value 분리). `;`-분리라 `max-width` 가 `width` 로
    /// 오인되지 않는다. 입력은 호출부에서 lowercased 된 상태.
    private nonisolated static func cssDeclaration(_ name: String, in lowered: String) -> String? {
        for decl in lowered.split(separator: ";") {
            guard let colon = decl.firstIndex(of: ":") else { continue }
            let prop = decl[..<colon].trimmingCharacters(in: .whitespaces)
            if prop == name {
                return decl[decl.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// CSS px 치수(`800px` → 800). `px` 는 접미사일 때만 제거하므로 `100%`·
    /// `calc(...)` 등 px 아닌 값은 nil(중간에 px 가 박힌 병리적 값도 오인 안 함).
    private nonisolated static func cssPixels(_ name: String, in lowered: String) -> Double? {
        guard let raw = cssDeclaration(name, in: lowered) else { return nil }
        var v = raw.trimmingCharacters(in: .whitespaces)
        if v.hasSuffix("px") { v = String(v.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        return Double(v)
    }
}
