import Foundation
import SwiftSoup

/// Parses humoruniv (웃대) mobile detail pages. Reached exclusively via aagag
/// mirror redirects — humoruniv is not exposed as a directly-browsable site.
struct HumorParser: BoardParser {
    let site: Site = .humor

    nonisolated init() {}

    private static let mp4ExpandRegex = try! NSRegularExpression(
        pattern: #"comment_mp4_expand\s*\(\s*'[^']*'\s*,\s*'([^']+)'"#,
        options: []
    )
    private static let youtubeIDRegex = try! NSRegularExpression(
        pattern: #"youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})"#,
        options: []
    )
    /// Source markers that identify non-content chrome (loading bars, UI icons,
    /// reaction buttons). Any <img> whose src hits one of these is dropped.
    private static let skipImageMarkers: [String] = [
        "loading_bar2.gif",
        "/images/ic_",
        "/images/icon-",
        "/images/cmt_",
        "/images/play_trans",
        "/images/sendmemo",
    ]

    private static let blockTags: Set<String> = [
        "p", "div", "li", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "tr",
    ]
    private static let skipTags: Set<String> = ["script", "style", "noscript"]

    func parseList(html: String, board: Board) throws -> [Post] {
        // Humoruniv is aagag-dispatch-only; list parsing is never invoked.
        []
    }

    func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)

        let title = try extractTitle(in: doc, fallback: post.title)
        let author = try extractAuthor(in: doc, fallback: post.author)
        let fullDateText = try extractFullDate(in: doc)
        let recommend = try extractRecommend(in: doc)
        let viewCount = try extractViewCount(in: doc)
        let source = try extractSource(in: doc)
        let blocks = try extractBlocks(in: doc)
        let comments = try extractComments(in: doc)

        let updated = Post(
            id: post.id,
            site: post.site,
            boardID: post.boardID,
            title: title,
            author: author,
            date: post.date,
            dateText: post.dateText,
            commentCount: post.commentCount,
            url: post.url,
            viewCount: viewCount ?? post.viewCount,
            recommendCount: recommend ?? post.recommendCount,
            levelText: post.levelText,
            hasAuthIcon: post.hasAuthIcon
        )

        return PostDetail(
            post: updated,
            blocks: blocks,
            fullDateText: fullDateText,
            viewCount: viewCount,
            source: source,
            comments: comments
        )
    }

    // Comments live in the same detail page — no separate fetch needed.
    func commentsURL(for post: Post) -> URL? { nil }

    // MARK: - Field extraction

    private func extractTitle(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select("#read_subject_div h2 a").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    private func extractAuthor(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select("#read_profile_td .nick .hu_nick_txt").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    private func extractFullDate(in doc: Document) throws -> String? {
        guard let el = try doc.select("#read_profile_desc span.etc").first() else { return nil }
        let text = try el.text().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("작성") {
            return String(text.dropFirst("작성".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    private func extractRecommend(in doc: Document) throws -> Int? {
        guard let el = try doc.select("#ok_div").first() else { return nil }
        let raw = try el.text().filter(\.isNumber)
        return raw.isEmpty ? nil : Int(raw)
    }

    private func extractViewCount(in doc: Document) throws -> Int? {
        // The profile desc has "<img src=...ic_view.png> 12,121" — the parent
        // span of that img carries the count as its text.
        guard let img = try doc.select("#read_profile_desc img[src*=ic_view]").first(),
              let parent = img.parent()
        else { return nil }
        let raw = try parent.text().filter(\.isNumber)
        return raw.isEmpty ? nil : Int(raw)
    }

    private func extractSource(in doc: Document) throws -> PostSource? {
        guard let anchor = try doc.select(".ct_info_sale a[href]").first() else { return nil }
        let href = try anchor.attr("href")
        guard !href.isEmpty,
              let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host
        else { return nil }
        let label = try anchor.text().trimmingCharacters(in: .whitespacesAndNewlines)
        return PostSource(name: label.isEmpty ? host : host, url: url)
    }

    // MARK: - Body blocks

    private func extractBlocks(in doc: Document) throws -> [ContentBlock] {
        // The article body is nested under <wrap_copy id="wrap_copy"> whose
        // closing tag in the source is a typo (</warp_copy>). SwiftSoup can't
        // match the close, so the custom element may end up empty or swallow
        // the rest of the page. Prefer standard wrappers when they're
        // present and fall back to the id-based selector.
        let candidates: [Element?] = [
            try doc.select("div.daum-wm-content").first(),
            try doc.select("#wrap_copy").first(),
            try doc.select("div.wrap_body").first(),
        ]
        guard let wrap = candidates.compactMap({ $0 }).first else { return [] }
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

        // Videos come from OnClick handlers on wrapper divs (humor doesn't
        // ship raw <video> tags on the mobile detail page). Extract the mp4
        // URL from the handler and skip descending into the thumbnail.
        let onclick = try el.attr("onclick")
        if !onclick.isEmpty, let videoURL = try parseMp4Click(onclick) {
            flushInline(into: &blocks, inline: &inline)
            blocks.append(.video(videoURL))
            return
        }

        switch tag {
        case "img":
            if let url = try realImageURL(from: el) {
                flushInline(into: &blocks, inline: &inline)
                blocks.append(.image(url))
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
            // Separate sibling blocks with a newline so paragraphs don't
            // fuse into a single run of prose.
            inline.appendText("\n")
        }
    }

    private func realImageURL(from el: Element) throws -> URL? {
        var src = try el.attr("src")
        if src.isEmpty {
            src = try el.attr("data-src")
        }
        guard !src.isEmpty else { return nil }
        if Self.skipImageMarkers.contains(where: src.contains) { return nil }
        guard let url = URL(string: src, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private func parseMp4Click(_ onclick: String) throws -> URL? {
        let ns = onclick as NSString
        guard let match = Self.mp4ExpandRegex.firstMatch(in: onclick, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2
        else { return nil }
        var raw = ns.substring(with: match.range(at: 1))
        if raw.hasPrefix("//") { raw = "https:" + raw }
        guard let url = URL(string: raw, relativeTo: site.baseURL)?.absoluteURL,
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

    private func extractComments(in doc: Document) throws -> [Comment] {
        let nodes = try doc.select("#comment li[id^=comment_li_]")
        var results: [Comment] = []
        for li in nodes {
            let idAttr = try li.attr("id")
            let cmtID = idAttr.hasPrefix("comment_li_")
                ? String(idAttr.dropFirst("comment_li_".count))
                : "idx\(results.count)"

            let classAttr = (try? li.attr("class")) ?? ""
            let nameAttr = (try? li.attr("name")) ?? ""
            let isReply = nameAttr == "sub_comm_block" || classAttr.contains("sub_comm")

            let author = try li.select(".nick .hu_nick_txt").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let rawDate = try li.select(".etc").first()?.text() ?? ""
            // humor embeds an <bSun, 19 Apr 2026 11:08:53 +0900> pseudo-tag
            // that SwiftSoup strips, leaving a double-space where it was.
            let dateText = rawDate
                .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let likeText = try li.select("[id^=comm_ok_div_]").first()?.text() ?? "0"
            let likeCount = Int(likeText.filter(\.isNumber)) ?? 0

            // Top-level comments put content inside .comment_text, but
            // sub_comm_block replies put it in a plain <span style="">
            // inside .comment_body. Selecting .comment_body and stripping
            // the vote/reply UI works for both shapes.
            let content: String = try {
                guard let bodyEl = try li.select(".comment_body").first(),
                      let copy = bodyEl.copy() as? Element
                else { return "" }
                try copy.select(".recomm_btn, [id^=comm_ok_ment_], [id^=poncomm]").remove()
                return try copy.text().trimmingCharacters(in: .whitespacesAndNewlines)
            }()

            let authIconURL = try extractAuthIcon(in: li)

            guard !author.isEmpty || !content.isEmpty else { continue }

            results.append(Comment(
                id: "\(site.rawValue)-c-\(cmtID)",
                author: author,
                dateText: dateText,
                content: content,
                likeCount: likeCount,
                isReply: isReply,
                stickerURL: nil,
                authIconURL: authIconURL,
                levelIconURL: nil
            ))
        }
        return results
    }

    private func extractAuthIcon(in li: Element) throws -> URL? {
        // Profile image is the first .hu_icon img inside the info header's <a>.
        // Top-level comments wrap it in .info, replies wrap it in
        // .sub_comm_info — fall back across both shapes. Skip humor's
        // default anonymous/site icons since they add noise.
        guard let img = try li.select(".info a img.hu_icon, .sub_comm_info a img.hu_icon").first()
        else { return nil }
        let src = try img.attr("src")
        guard !src.isEmpty,
              !src.contains("icon-humoruniv"),
              !src.contains("/images/icon-")
        else { return nil }
        guard let url = URL(string: src, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}
