import Foundation
import SwiftSoup

/// Parses etoland (이토랜드) detail pages. Reached exclusively via aagag mirror
/// redirects — etoland's mobile detail URL pattern is
/// `etoland.co.kr/b/{board}/view/{slug-or-id}-{post_id}`.
///
/// Etoland is a Next.js SSR app, so the post body, title, and meta line are
/// rendered into the initial HTML. Comments load via a client-side fetch
/// after page hydration and aren't in the SSR response — `parseComments` /
/// `fetchAllComments` return `[]` for now (the API surface they call is
/// authenticated and not publicly documented). The body parser is the
/// minimum useful surface to get etoland posts off the "외부 사이트로 이동"
/// banner.
struct EtolandParser: BoardParser {
    let site: Site = .etoland

    nonisolated init() {}

    /// Block-level tags whose closing forces a soft newline in the inline
    /// accumulator so paragraphs stay separated when SwiftSoup's text walk
    /// flattens the subtree. Same set the other detail parsers use.
    nonisolated private static let blockTags: Set<String> = [
        "p", "div", "li", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "tr",
    ]
    nonisolated private static let skipTags: Set<String> = ["script", "style", "noscript"]

    nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        // Etoland is aagag-dispatch-only; list parsing is never invoked.
        []
    }

    nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)

        // Etoland's deleted-post page replaces the article wrapper with a
        // notice block. The most reliable signal is the absence of the
        // post `<h1>` inside `<article>`; fall back to a notice in that
        // case so the user sees a clear message instead of an empty body.
        guard let article = try doc.select("article:has(h1)").first(where: { el in
            (try? el.select("div.view-content").first()) != nil
                || (try? el.select("h1").first()?.text())?.isEmpty == false
        }) else {
            return PostDetail(
                post: post,
                blocks: [.text("게시물을 불러올 수 없습니다.")],
                fullDateText: nil,
                viewCount: nil,
                source: nil,
                comments: []
            )
        }

        let title = ParserText.cleanTitle(try extractTitle(in: article, fallback: post.title))
        let meta = try extractMeta(in: article)
        let blocks = try extractBlocks(in: article)

        let updated = Post(
            id: post.id,
            site: post.site,
            boardID: post.boardID,
            title: title,
            author: meta.author.isEmpty ? post.author : meta.author,
            date: post.date,
            dateText: post.dateText,
            commentCount: meta.commentCount ?? post.commentCount,
            url: post.url,
            viewCount: meta.viewCount ?? post.viewCount,
            recommendCount: meta.recommendCount ?? post.recommendCount,
            levelText: post.levelText,
            hasAuthIcon: post.hasAuthIcon
        )

        return PostDetail(
            post: updated,
            blocks: blocks,
            fullDateText: meta.dateText,
            viewCount: meta.viewCount,
            source: nil,
            comments: []
        )
    }

    // Comments load via client-side fetch after hydration; the SSR HTML only
    // contains a skeleton loader, not the comment data. Surfacing none until
    // the client API can be reverse-engineered.
    nonisolated func commentsURL(for post: Post) -> URL? { nil }

    // MARK: - Field extraction

    /// `<article><h1 class="body-m ...">[icon]<span class="truncate">TITLE</span></h1>`.
    /// The `<span class="truncate">` is the actual title text; the leading
    /// `<img>` is the per-post badge (`hit.svg`, `notice.svg`, etc.) and
    /// must not contribute to the read.
    nonisolated private func extractTitle(in article: Element, fallback: String) throws -> String {
        if let span = try article.select("h1 span.truncate").first() {
            let text = try span.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        // Fallback: the `<h1>` text minus any image alt text the badge `<img>`
        // would otherwise contribute (`alt="인기"`, `alt="공지"`, etc.).
        if let h1 = try article.select("h1").first() {
            let copy = (h1.copy() as? Element) ?? h1
            try copy.select("img").remove()
            let text = try copy.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return fallback
    }

    /// Meta line lives in a single `.caption-s` div under the `<h1>`:
    /// `<a><nickname></a><time>YYYY-MM-DD HH:MM:SS</time><span>조회 N</span><span>추천 N</span><span>댓글 N</span>`.
    /// Etoland keeps the labels in plain Korean prose, so a keyword scan over
    /// the spans is more durable than positional indexing — a future tweak
    /// that inserts a badge `<span>` between author and time wouldn't shift
    /// the parse off-by-one.
    nonisolated private func extractMeta(in article: Element) throws -> (
        author: String,
        dateText: String?,
        viewCount: Int?,
        recommendCount: Int?,
        commentCount: Int?
    ) {
        let author = try article.select(".nickname").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dateText = try article.select("time").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var view: Int?
        var recommend: Int?
        var comments: Int?
        for span in try article.select("h1 ~ div .caption-s span, h1 ~ div div span") {
            let text = try span.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("조회") {
                view = Int(text.dropFirst("조회".count).filter(\.isNumber))
            } else if text.hasPrefix("추천") {
                recommend = Int(text.dropFirst("추천".count).filter(\.isNumber))
            } else if text.hasPrefix("댓글") {
                comments = Int(text.dropFirst("댓글".count).filter(\.isNumber))
            }
        }
        let normalizedDate = dateText?.isEmpty == false ? dateText : nil
        return (author, normalizedDate, view, recommend, comments)
    }

    // MARK: - Body blocks

    nonisolated private func extractBlocks(in article: Element) throws -> [ContentBlock] {
        guard let wrap = try article.select("div.view-content").first() else { return [] }
        var blocks: [ContentBlock] = []
        var inline = InlineAccumulator()
        try collectBlocks(from: wrap, into: &blocks, inline: &inline)
        flushInline(into: &blocks, inline: &inline)
        return blocks
    }

    nonisolated private func flushInline(into blocks: inout [ContentBlock], inline: inout InlineAccumulator) {
        let segments = inline.drain()
        if !segments.isEmpty {
            blocks.append(.richText(segments))
        }
    }

    nonisolated private func collectBlocks(
        from element: Element,
        into blocks: inout [ContentBlock],
        inline: inout InlineAccumulator
    ) throws {
        for node in element.getChildNodes() {
            if let child = node as? Element {
                try handleElement(child, blocks: &blocks, inline: &inline)
            } else if let text = node as? TextNode {
                let raw = text.text()
                if !raw.isEmpty { inline.appendText(raw) }
            }
        }
    }

    nonisolated private func handleElement(
        _ el: Element,
        blocks: inout [ContentBlock],
        inline: inout InlineAccumulator
    ) throws {
        let tag = el.tagName().lowercased()

        if Self.skipTags.contains(tag) { return }
        if isHidden(el) { return }

        switch tag {
        case "img":
            if let url = try realImageURL(from: el) {
                flushInline(into: &blocks, inline: &inline)
                blocks.append(.image(url))
            }
            return
        case "video":
            if let url = try videoURL(from: el) {
                flushInline(into: &blocks, inline: &inline)
                blocks.append(.video(url, posterURL: try videoPoster(from: el)))
            }
            return
        case "iframe":
            let src = try el.attr("src")
            if let id = youtubeEmbedID(from: src) {
                flushInline(into: &blocks, inline: &inline)
                blocks.append(.embed(.youtube, id: id))
            }
            return
        case "a":
            // Anchors wrapping `<img>` (etoland inline images sometimes ship
            // inside a clickable wrapper that links to a lightbox URL) would
            // otherwise be consumed as a bare link label, hiding the media.
            // Recurse into children when there's media inside; only emit a
            // pure inline link when the anchor has no nested media.
            if try el.select("img, video").first() != nil {
                try collectBlocks(from: el, into: &blocks, inline: &inline)
                return
            }
            if let resolved = try anchor(from: el) {
                inline.appendLink(url: resolved.url, label: resolved.label)
            } else {
                inline.appendText(try el.text())
            }
            return
        case "br":
            inline.appendText("\n")
            return
        default:
            break
        }

        try collectBlocks(from: el, into: &blocks, inline: &inline)
        if Self.blockTags.contains(tag) {
            inline.appendText("\n")
        }
    }

    /// Etoland inlines images via Next.js `<Image>` output: a `src=` pointing
    /// at the CDN's transform endpoint
    /// (`https://btcdn.etoland.co.kr/optimize/w_920,format_webp,q_90,position_entropy/<original>`)
    /// alongside a `data-src=` carrying the unoptimised original. Prefer the
    /// raw original so we don't pin the renderer to a 920-wide WebP that
    /// loses fidelity on Retina displays. Fall back to `src` when `data-src`
    /// is missing (older posts or non-image-content figures).
    nonisolated private func realImageURL(from el: Element) throws -> URL? {
        for attr in ["data-src", "src"] {
            let raw = try el.attr(attr).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            if let url = resolveHTTPURL(raw) { return url }
        }
        return nil
    }

    nonisolated private func videoURL(from el: Element) throws -> URL? {
        let src = try el.attr("src")
        if let url = resolveHTTPURL(src) { return url }
        for source in try el.select("source") {
            let s = try source.attr("src")
            if let url = resolveHTTPURL(s) { return url }
        }
        return nil
    }
}
