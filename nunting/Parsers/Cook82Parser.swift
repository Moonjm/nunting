import Foundation
import SwiftSoup
/// Parses 82cook (82쿡) desktop detail pages. Reached exclusively via aagag
/// mirror redirects — 82cook is not exposed as a directly-browsable site.
///
/// 82cook serves a single server-rendered page that inlines both the article
/// body and the whole comment list (unlike SLR/Ddanzi which need a follow-up
/// AJAX roundtrip). Comments are a flat list — the site has no reply-to-
/// comment threading — so `isReply` is always `false`.
public struct Cook82Parser: BoardParser {
    public let site: Site = .cook82

    public nonisolated init() {}

    /// Matches 82cook's comment timestamp shape (`'26.4.19 3:12 PM` or a bare
    /// `HH:MM` in very recent posts). Used to pick the correct `<em>` inside
    /// `.repleFunc` so a future admin/level badge `<em>` inserted before the
    /// date doesn't silently become the displayed timestamp.
    nonisolated private static let commentTimeRegex = try! NSRegularExpression(
        pattern: #"\d{1,2}:\d{2}|\d{1,2}\.\d{1,2}\.\d{1,2}"#,
        options: []
    )

    public nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        // 82cook is aagag-dispatch-only; list parsing is never invoked.
        []
    }

    public nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
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

        let updated = post.enrichedForDetail(
            title: title,
            author: author.isEmpty ? post.author : author,
            viewCount: viewCount
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
    public nonisolated func commentsURL(for post: Post) -> URL? { nil }

    // MARK: - Field extraction

    nonisolated private func extractTitle(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select("h4.bbstitle span").first()?.text() ?? ""
        let cleaned = ParserText.cleanTitle(text)
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// `#readHead .readLeft` packs author + view count into one block:
    /// `<strong><a>이름</a></strong>  조회수 : 4,868`. Pull the `<strong>`
    /// text for the name, then regex the rest for the "조회수" number so a
    /// future CSS tweak to the trailing whitespace doesn't break parsing.
    nonisolated private func extractReadLeft(in doc: Document) throws -> (author: String, view: Int?) {
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

    nonisolated private func extractDate(in doc: Document) throws -> String? {
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

    nonisolated private func extractBlocks(in doc: Document) throws -> [ContentBlock] {
        guard let wrap = try doc.select("#articleBody").first() else { return [] }
        // 옛 Cook82 `<a>` 처리는 `el.select("img, video")` 만 검사해 iframe
        // wrap 케이스를 drop 했지만, walker standard 는 iframe 포함이라
        // `<a><iframe src=youtube/embed/…></a>` 이 YouTube embed 블록으로
        // 새로 surface 됨. 다른 6개 마이그된 파서(Bobae/Ppomppu/Etoland/
        // Clien/Inven/Humor) 와 동일한 동작 — 의도된 개선.
        let rules = WalkerRules.standard(for: self)
        return try ParserBlockWalker(parser: self, rules: rules).walk(wrap)
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
    nonisolated private func extractComments(in doc: Document) throws -> [PostComment] {
        let nodes = try doc.select("ul.reples > li.rp")
        var results: [PostComment] = []
        for (idx, li) in nodes.enumerated() {
            let rn = (try? li.attr("data-rn")) ?? ""
            let cmtID = rn.isEmpty ? "idx\(idx)" : rn

            // Soft-deleted comments (`rp delReple`) often drop their <p>
            // body and sometimes the <h5> author too. Emit an explicit
            // placeholder so users see the gap instead of a row that
            // accidentally looks empty or misattributed.
            if li.hasClass("delReple") {
                results.append(PostComment(
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

            results.append(PostComment(
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
    nonisolated private func extractCommentDate(li: Element) throws -> String {
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
    nonisolated private func renderCommentContent(li: Element) throws -> String {
        // Scope to a direct `<p>` child of the `<li>` so a future wrapper
        // (quote panel, announcement badge…) that itself contains a `<p>`
        // doesn't hijack the comment body.
        guard let p = try li.select("> p").first() else { return "" }
        // Work on a copy so the anchor→markdown rewrite doesn't mutate the
        // original DOM other callers may still hold.
        guard let copy = p.copy() as? Element else { return "" }
        // Preserve anchors as tappable markdown links — `walk()` below
        // recurses through anchors as plain elements and drops their hrefs.
        convertAnchorsToMarkdown(in: copy)
        var output = ""
        try walk(copy, into: &output)
        return output
            // Raw text-node content carries 82cook's pretty-print indentation
            // (`"\n    "` between block children). Strip spaces/tabs around
            // every newline so it doesn't show as per-line indentation.
            .replacingOccurrences(
                of: #"[ \t]*\n[ \t]*"#,
                with: "\n",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private func walk(_ element: Element, into output: inout String) throws {
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
