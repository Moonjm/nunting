import Foundation
import SwiftSoup

/// Parses 82cook (82쿡) desktop detail pages. Reached exclusively via aagag
/// mirror redirects — 82cook is not exposed as a directly-browsable site.
///
/// 82cook serves a single server-rendered page that inlines both the article
/// body and the whole comment list (unlike SLR/Ddanzi which need a follow-up
/// AJAX roundtrip). Comments are a flat list — the site has no reply-to-
/// comment threading — so `isReply` is always `false`.
struct Cook82Parser: BoardParser {
    let site: Site = .cook82

    nonisolated init() {}

    private static let blockTags: Set<String> = [
        "p", "div", "li", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "tr",
    ]
    private static let skipTags: Set<String> = ["script", "style", "noscript"]

    private static let youtubeIDRegex = try! NSRegularExpression(
        pattern: #"youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})"#,
        options: []
    )
    /// Matches 82cook's comment timestamp shape (`'26.4.19 3:12 PM` or a bare
    /// `HH:MM` in very recent posts). Used to pick the correct `<em>` inside
    /// `.repleFunc` so a future admin/level badge `<em>` inserted before the
    /// date doesn't silently become the displayed timestamp.
    private static let commentTimeRegex = try! NSRegularExpression(
        pattern: #"\d{1,2}:\d{2}|\d{1,2}\.\d{1,2}\.\d{1,2}"#,
        options: []
    )

    func parseList(html: String, board: Board) throws -> [Post] {
        // 82cook is aagag-dispatch-only; list parsing is never invoked.
        []
    }

    func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)

        // Deleted / moved posts replace the body wrapper with an error panel.
        if try doc.select("#articleBody").isEmpty() {
            let body = try doc.text()
            let notice: String
            if body.contains("삭제") || body.contains("이동") || body.contains("존재하지") {
                notice = "삭제되거나 이동된 게시물입니다."
            } else {
                notice = "게시물을 불러올 수 없습니다."
            }
            return PostDetail(
                post: post,
                blocks: [.text(notice)],
                fullDateText: nil,
                viewCount: nil,
                source: nil,
                comments: []
            )
        }

        let title = try extractTitle(in: doc, fallback: post.title)
        let (author, viewCount) = try extractReadLeft(in: doc)
        let fullDateText = try extractDate(in: doc)
        let blocks = try extractBlocks(in: doc)
        let comments = try extractComments(in: doc)

        let updated = Post(
            id: post.id,
            site: post.site,
            boardID: post.boardID,
            title: title,
            author: author.isEmpty ? post.author : author,
            date: post.date,
            dateText: post.dateText,
            commentCount: post.commentCount,
            url: post.url,
            viewCount: viewCount ?? post.viewCount,
            recommendCount: post.recommendCount,
            levelText: post.levelText,
            hasAuthIcon: post.hasAuthIcon
        )

        return PostDetail(
            post: updated,
            blocks: blocks,
            fullDateText: fullDateText,
            viewCount: viewCount,
            source: nil,
            comments: comments
        )
    }

    // Comments live inline — no separate fetch needed.
    func commentsURL(for post: Post) -> URL? { nil }

    // MARK: - Field extraction

    private func extractTitle(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select("h4.bbstitle span").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    /// `#readHead .readLeft` packs author + view count into one block:
    /// `<strong><a>이름</a></strong>  조회수 : 4,868`. Pull the `<strong>`
    /// text for the name, then regex the rest for the "조회수" number so a
    /// future CSS tweak to the trailing whitespace doesn't break parsing.
    private func extractReadLeft(in doc: Document) throws -> (author: String, view: Int?) {
        guard let left = try doc.select("#readHead .readLeft").first() else {
            return ("", nil)
        }
        let author = try left.select("strong").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fullText = try left.text()
        var view: Int?
        if let range = fullText.range(of: "조회수") {
            let tail = fullText[range.upperBound...]
            let digits = tail.filter(\.isNumber)
            if !digits.isEmpty { view = Int(digits) }
        }
        return (author, view)
    }

    private func extractDate(in doc: Document) throws -> String? {
        guard let right = try doc.select("#readHead .readRight").first() else { return nil }
        let raw = try right.text().trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop the leading "작성일 :" label if present.
        if let range = raw.range(of: "작성일") {
            let tail = raw[range.upperBound...]
            let cleaned = tail.drop(while: { $0 == ":" || $0.isWhitespace })
            return cleaned.isEmpty ? nil : String(cleaned)
        }
        return raw.isEmpty ? nil : raw
    }

    // MARK: - Body blocks

    private func extractBlocks(in doc: Document) throws -> [ContentBlock] {
        guard let wrap = try doc.select("#articleBody").first() else { return [] }
        var blocks: [ContentBlock] = []
        var inline = InlineAccumulator()
        try collectBlocks(from: wrap, into: &blocks, inline: &inline)
        flushInline(into: &blocks, inline: &inline)
        return blocks
    }

    private func flushInline(into blocks: inout [ContentBlock], inline: inout InlineAccumulator) {
        let segments = inline.drain()
        if !segments.isEmpty {
            blocks.append(.richText(segments))
        }
    }

    private func collectBlocks(from element: Element, into blocks: inout [ContentBlock], inline: inout InlineAccumulator) throws {
        for node in element.getChildNodes() {
            if let child = node as? Element {
                try handleElement(child, blocks: &blocks, inline: &inline)
            } else if let text = node as? TextNode {
                let raw = text.text()
                if !raw.isEmpty { inline.appendText(raw) }
            }
        }
    }

    private func handleElement(_ el: Element, blocks: inout [ContentBlock], inline: inout InlineAccumulator) throws {
        let tag = el.tagName().lowercased()
        if Self.skipTags.contains(tag) { return }

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
                blocks.append(.video(url))
            }
            return
        case "iframe":
            let src = try el.attr("src")
            if let id = youtubeID(from: src) {
                flushInline(into: &blocks, inline: &inline)
                blocks.append(.embed(.youtube, id: id))
            }
            return
        case "a":
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

    private func realImageURL(from el: Element) throws -> URL? {
        var src = try el.attr("src")
        if src.isEmpty { src = try el.attr("data-src") }
        if src.isEmpty { src = try el.attr("data-original") }
        guard !src.isEmpty else { return nil }
        let normalized = src.hasPrefix("//") ? "https:" + src : src
        guard let url = URL(string: normalized, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private func videoURL(from el: Element) throws -> URL? {
        var raw = try el.attr("src")
        if raw.isEmpty, let source = try el.select("source").first() {
            raw = try source.attr("src")
        }
        guard !raw.isEmpty else { return nil }
        if let hash = raw.firstIndex(of: "#") {
            raw = String(raw[..<hash])
        }
        let normalized = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let url = URL(string: normalized, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private func youtubeID(from src: String) -> String? {
        let ns = src as NSString
        guard let match = Self.youtubeIDRegex.firstMatch(in: src, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - Comments

    /// 82cook comment shape:
    /// ```
    /// <ul class="reples">
    ///   <li data-rn="40335017" class="rp">
    ///     <h5><i></i><span>1.</span> <strong>nickname</strong></h5>
    ///     <div class="repleFunc">
    ///       <em>'26.4.19 3:12 PM</em>
    ///       <em class="ip"> (112.156.xxx.57)</em>
    ///     </div>
    ///     <p>내용<br>…</p>
    ///   </li>
    ///   <li data-rn="…" class="rp delReple"> … </li>   (soft-deleted)
    /// </ul>
    /// ```
    /// The comment list is flat — 82cook doesn't thread replies. `<h5>` may
    /// carry class `me` to mark the post author, which we surface as a
    /// distinct author string only when parsing a reply; here it's just
    /// metadata we don't need.
    private func extractComments(in doc: Document) throws -> [Comment] {
        let nodes = try doc.select("ul.reples > li.rp")
        var results: [Comment] = []
        for (idx, li) in nodes.enumerated() {
            let rn = (try? li.attr("data-rn")) ?? ""
            let cmtID = rn.isEmpty ? "idx\(idx)" : rn

            // Soft-deleted comments (`rp delReple`) often drop their <p>
            // body and sometimes the <h5> author too. Emit an explicit
            // placeholder so users see the gap instead of a row that
            // accidentally looks empty or misattributed.
            if li.hasClass("delReple") {
                results.append(Comment(
                    id: "\(site.rawValue)-c-\(cmtID)",
                    author: "",
                    dateText: "",
                    content: "삭제된 댓글입니다.",
                    likeCount: 0,
                    isReply: false
                ))
                continue
            }

            // Drop the leading sequence number (`<span>1.</span>`) so the
            // author text comes back as just the nickname.
            let author = try li.select("h5 strong").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let dateText = try extractCommentDate(li: li)
            let content = try renderCommentContent(li: li)

            if author.isEmpty, content.isEmpty { continue }

            results.append(Comment(
                id: "\(site.rawValue)-c-\(cmtID)",
                author: author,
                dateText: dateText,
                content: content,
                likeCount: 0,
                isReply: false
            ))
        }
        return results
    }

    /// `.repleFunc` packs the date and the writer's IP inside sibling `<em>`
    /// tags. Picking positionally is brittle — future template tweaks (admin
    /// badges, level chips) can slot extra `<em>`s in. Validate each candidate
    /// against a time-shaped regex so only the real timestamp wins.
    private func extractCommentDate(li: Element) throws -> String {
        for em in try li.select(".repleFunc em") {
            let cls = (try? em.attr("class")) ?? ""
            if cls.contains("ip") { continue }
            let text = try em.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let ns = text as NSString
            if Self.commentTimeRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
                return text
            }
        }
        return ""
    }

    /// SwiftSoup's `.text()` collapses `<br>` runs to spaces, losing the
    /// visible line breaks 82cook's comments rely on. Walk the `<p>` manually
    /// to preserve newlines exactly as rendered.
    private func renderCommentContent(li: Element) throws -> String {
        // Scope to a direct `<p>` child of the `<li>` so a future wrapper
        // (quote panel, announcement badge…) that itself contains a `<p>`
        // doesn't hijack the comment body.
        guard let p = try li.select("> p").first() else { return "" }
        var output = ""
        try walk(p, into: &output)
        return output
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func walk(_ element: Element, into output: inout String) throws {
        for node in element.getChildNodes() {
            if let text = node as? TextNode {
                output += text.text()
            } else if let el = node as? Element {
                let tag = el.tagName().lowercased()
                switch tag {
                case "br":
                    output += "\n"
                case "img", "script", "style":
                    continue
                default:
                    try walk(el, into: &output)
                }
            }
        }
    }
}
