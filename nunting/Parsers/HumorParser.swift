import Foundation
import SwiftSoup

/// Parses humoruniv (웃대) mobile detail pages. Reached exclusively via aagag
/// mirror redirects — humoruniv is not exposed as a directly-browsable site.
struct HumorParser: BoardParser {
    let site: Site = .humor

    nonisolated init() {}

    nonisolated private static let mp4ExpandRegex = try! NSRegularExpression(
        pattern: #"comment_mp4_expand\s*\(\s*'[^']*'\s*,\s*'([^']+)'"#,
        options: []
    )
    nonisolated private static let youtubeIDRegex = try! NSRegularExpression(
        pattern: #"youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})"#,
        options: []
    )
    /// Source markers that identify non-content chrome (loading bars, UI icons,
    /// reaction buttons, AI 너굴맨 / "안심맨" decoy that humoruniv injects
    /// before every uploaded body image to thwart hot-linking — surfacing it
    /// in the app doubles the visible image count). Any <img> whose src hits
    /// one of these is dropped.
    nonisolated private static let skipImageMarkers: [String] = [
        "loading_bar2.gif",
        "/images/ic_",
        "/images/icon-",
        "/images/cmt_",
        "/images/play_trans",
        "/images/sendmemo",
        "/images/ai/ansim_man",
    ]

    nonisolated private static let blockTags: Set<String> = [
        "p", "div", "li", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "tr",
    ]
    nonisolated private static let skipTags: Set<String> = ["script", "style", "noscript"]

    nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        // Humoruniv is aagag-dispatch-only; list parsing is never invoked.
        []
    }

    nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)

        // Humoruniv redirects deleted/moved posts to /board/msg.html which
        // has none of the usual detail markup. Returning an empty PostDetail
        // looks like the app hung — emit an inline notice instead.
        if try doc.select("#read_subject_div").isEmpty() {
            let body = try doc.text()
            let notice: String
            if body.contains("삭제/이동된") || body.contains("삭제된 게시물") {
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
    nonisolated func commentsURL(for post: Post) -> URL? { nil }

    // MARK: - Field extraction

    nonisolated private func extractTitle(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select("#read_subject_div h2 a").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    nonisolated private func extractAuthor(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select("#read_profile_td .nick .hu_nick_txt").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    nonisolated private func extractFullDate(in doc: Document) throws -> String? {
        guard let el = try doc.select("#read_profile_desc span.etc").first() else { return nil }
        let text = try el.text().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("작성") {
            return String(text.dropFirst("작성".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    nonisolated private func extractRecommend(in doc: Document) throws -> Int? {
        guard let el = try doc.select("#ok_div").first() else { return nil }
        let raw = try el.text().filter(\.isNumber)
        return raw.isEmpty ? nil : Int(raw)
    }

    nonisolated private func extractViewCount(in doc: Document) throws -> Int? {
        // The profile desc has "<img src=...ic_view.png> 12,121" — the parent
        // span of that img carries the count as its text.
        guard let img = try doc.select("#read_profile_desc img[src*=ic_view]").first(),
              let parent = img.parent()
        else { return nil }
        let raw = try parent.text().filter(\.isNumber)
        return raw.isEmpty ? nil : Int(raw)
    }

    nonisolated private func extractSource(in doc: Document) throws -> PostSource? {
        guard let anchor = try doc.select(".ct_info_sale a[href]").first() else { return nil }
        let href = try anchor.attr("href")
        guard !href.isEmpty,
              let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host
        else { return nil }
        let label = try anchor.text().trimmingCharacters(in: .whitespacesAndNewlines)
        return PostSource(name: label.isEmpty ? host : label, url: url)
    }

    // MARK: - Body blocks

    nonisolated private func extractBlocks(in doc: Document) throws -> [ContentBlock] {
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
        // 너굴맨 (안심맨) 디코이 영역 통째로 제거.
        //
        //   <div class="simple_attach_img_div">
        //     <div id="racy_show_X">          ← 너굴맨 이미지 + "히든처리" 안내문
        //       ...                            + "이미지 보기"/"너굴맨 설정"/
        //     </div>                           "본문 너굴맨 한꺼번에 제거" 버튼들
        //     <div id="racy_hidden_X"         ← 실제 본문 이미지
        //          style="display:none">       (display:none 이지만 우리는
        //       <table>... real <img> ...      computed style 이 아니라 태그로
        //       </table>                       추출하므로 그대로 살아남음)
        //     </div>
        //   </div>
        //
        // racy_show_* 안엔 앱에 띄울 콘텐츠가 하나도 없고, 진짜 이미지는
        // 형제 racy_hidden_* 에 들어있어서 selector 한 줄로 정리.
        try wrap.select("[id^=racy_show_]").remove()
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

    nonisolated private func collectBlocks(from element: Element, into blocks: inout [ContentBlock], inline: inout InlineAccumulator) throws {
        for node in element.getChildNodes() {
            if let child = node as? Element {
                try handleElement(child, blocks: &blocks, inline: &inline)
            } else if let text = node as? TextNode {
                let raw = text.text()
                if !raw.isEmpty { inline.appendText(raw) }
            }
        }
    }

    nonisolated private func handleElement(_ el: Element, blocks: inout [ContentBlock], inline: inout InlineAccumulator) throws {
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
            // Anchors wrapping `<img>` / `<video>` (forums often wrap inline
            // GIFs in a clickable link) would otherwise be consumed here as
            // a bare link label, hiding the media. Recurse into the children
            // first so the nested image becomes a proper block; only treat
            // the anchor as a link/text segment when there's no media inside.
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
            // Separate sibling blocks with a newline so paragraphs don't
            // fuse into a single run of prose.
            inline.appendText("\n")
        }
    }

    nonisolated private func realImageURL(from el: Element) throws -> URL? {
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

    nonisolated private func parseMp4Click(_ onclick: String) throws -> URL? {
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

    nonisolated private func youtubeID(from src: String) -> String? {
        let ns = src as NSString
        guard let match = Self.youtubeIDRegex.firstMatch(in: src, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - Comments

    nonisolated private func extractComments(in doc: Document) throws -> [Comment] {
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
            // the vote/reply UI works for both shapes. Also drop the
            // comment-file block so its "원본" button label / thumbnail
            // don't leak into the content text.
            let content: String = try {
                guard let bodyEl = try li.select(".comment_body").first(),
                      let copy = bodyEl.copy() as? Element
                else { return "" }
                try copy.select(
                    ".recomm_btn, [id^=comm_ok_ment_], [id^=poncomm], .comment_file, img, script, style"
                ).remove()
                return try copy.text().trimmingCharacters(in: .whitespacesAndNewlines)
            }()

            let videoURL = try extractCommentVideo(in: li)
            // When a comment carries a playable mp4 attachment we render the
            // video directly and skip the static thumbnail — otherwise the
            // thumbnail would flash behind the player while it loads.
            let stickerURL = videoURL == nil ? try extractCommentSticker(in: li) : nil
            let authIconURL = try extractAuthIcon(in: li)

            guard !author.isEmpty || !content.isEmpty || stickerURL != nil || videoURL != nil
            else { continue }

            results.append(Comment(
                id: "\(site.rawValue)-c-\(cmtID)",
                author: author,
                dateText: dateText,
                content: content,
                likeCount: likeCount,
                isReply: isReply,
                stickerURL: stickerURL,
                videoURL: videoURL,
                authIconURL: authIconURL,
                levelIconURL: nil
            ))
        }
        return results
    }

    nonisolated private func extractCommentVideo(in li: Element) throws -> URL? {
        // Inline mp4/gif attachments live on an outer wrapper that carries
        // the same OnClick="comment_mp4_expand('id', 'URL', 'THUMB', ...)"
        // handler the body uses. Walk every element under the comment_file
        // block because the OnClick can be on the outer div or on a nested
        // anchor.
        for el in try li.select(".comment_file [onclick]") {
            let onclick = try el.attr("onclick")
            if let url = try parseMp4Click(onclick) { return url }
        }
        return nil
    }

    nonisolated private func extractCommentSticker(in li: Element) throws -> URL? {
        // Humor renders attached comment images via:
        //   <div class="comment_file">
        //     <img src='/images/loading_bar2.gif' ...>          (progress bar)
        //     <img class="img_compress"
        //          src="//timg.humoruniv.com/thumb.php?url=..." (proxy thumb)
        //          img_file_url="//down.humoruniv.com/.../r_r...jpg" (original)>
        // We iterate every <img> in the comment_file wrapper so the progress
        // bar doesn't shadow the real attachment, and we prefer img_file_url
        // (untransformed original) over the thumb proxy for zoom quality.
        for img in try li.select(".comment_file img") {
            let candidates = [
                try img.attr("img_file_url"),
                try img.attr("data-original"),
                try img.attr("src"),
            ]
            for raw in candidates {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.contains("loading_bar")
                else { continue }
                // Scheme-relative URLs ("//down.humoruniv.com/...") get a
                // fixed https scheme so the image loader can resolve them
                // without a relative base that might pick http.
                let normalized = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
                guard let url = URL(string: normalized, relativeTo: site.baseURL)?.absoluteURL,
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https"
                else { continue }
                return url
            }
        }
        return nil
    }

    nonisolated private func extractAuthIcon(in li: Element) throws -> URL? {
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
