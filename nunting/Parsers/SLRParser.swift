import Foundation
import SwiftSoup

/// Parses SLR Club (SLR클럽) mobile detail pages. Reached exclusively via
/// aagag mirror redirects — SLR is not exposed as a directly-browsable site.
///
/// SLR renders article body inline but loads the comment list via a separate
/// JSON AJAX endpoint (`/bbs/comment_db/load.php`, POST). Because that
/// endpoint needs the `data-tos` token that only lives on the detail HTML,
/// `fetchAllComments` re-requests the detail page via the injected fetcher
/// (the URL cache usually serves it) to pull out the params, then POSTs.
struct SLRParser: BoardParser {
    let site: Site = .slr

    nonisolated init() {}

    nonisolated private static let blockTags: Set<String> = [
        "p", "div", "li", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "tr",
    ]
    nonisolated private static let skipTags: Set<String> = ["script", "style", "noscript"]

    /// Inline `<img>`/`<video>` inside a comment memo. Same shape as the body
    /// extractor but scoped to a single comment's HTML fragment.
    nonisolated private static let youtubeIDRegex = try! NSRegularExpression(
        pattern: #"youtube(?:-nocookie)?\.com/embed/([A-Za-z0-9_-]{11})"#,
        options: []
    )

    nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        // SLR is aagag-dispatch-only; list parsing is never invoked.
        []
    }

    nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)

        // SLR replies "이동되었거나 삭제된 게시물입니다" on deleted posts —
        // without the usual `.subject` heading. Fall back to a notice.
        if try doc.select(".subject").isEmpty() {
            let body = try doc.text()
            let notice: String
            if body.contains("삭제") || body.contains("이동") {
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
        let (author, fullDate, view, recommend) = try extractMeta(in: doc)
        let blocks = try extractBlocks(in: doc)

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
            viewCount: view ?? post.viewCount,
            recommendCount: recommend ?? post.recommendCount,
            levelText: post.levelText,
            hasAuthIcon: post.hasAuthIcon
        )

        return PostDetail(
            post: updated,
            blocks: blocks,
            fullDateText: fullDate,
            viewCount: view,
            source: nil,
            comments: [] // filled in via fetchAllComments
        )
    }

    /// Return the detail URL as a sentinel so `PostDetailView` invokes
    /// `fetchAllComments`. The injected fetcher hits the same URL that was
    /// just fetched for `parseDetail`, so URLCache typically serves it —
    /// avoids duplicating the ParserFactory plumbing for a POST-only
    /// endpoint.
    nonisolated func commentsURL(for post: Post) -> URL? { post.url }

    nonisolated func fetchAllComments(
        for post: Post,
        detailHTML: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [Comment] {
        // 1) Pull the detail HTML so we can extract the AJAX params.
        //    The caller already fetched it for `parseDetail` — reuse
        //    that copy when it's threaded through so we don't
        //    duplicate the fetch + SwiftSoup parse of the same body.
        let html: String
        if let detailHTML {
            html = detailHTML
        } else {
            html = try await fetcher(post.url)
        }
        guard let params = try Self.extractCommentParams(html: html) else {
            return []
        }

        // 2) POST to the JSON endpoint the mobile site uses. SLR rejects GET
        //    on this route with `{"error":"정상적이지 않은 접근입니다"}`.
        let endpoint = URL(string: "https://m.slrclub.com/bbs/comment_db/load.php")!
        let data = try await Networking.postForm(
            url: endpoint,
            parameters: [
                "id": params.bbsid,
                "tos": params.tos,
                "no": params.cmrno,
                "sno": "1",
                "spl": params.splno,
                "mno": params.cmx,
                "gp": "mobile",
                "ksearch": "",
            ],
            referer: post.url
        )

        return decodeComments(data: data)
    }

    // MARK: - Field extraction

    nonisolated private func extractTitle(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select(".subject").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? fallback : text
    }

    /// Mobile SLR crams author / time / view / recommend into a single
    /// `.info-wrap` block separated by `|`. Split and filter on the leading
    /// Korean keyword so future layout tweaks (extra badges, dropped fields)
    /// don't desynchronise the positional parse.
    nonisolated private func extractMeta(in doc: Document) throws -> (author: String, date: String?, view: Int?, recommend: Int?) {
        guard let wrap = try doc.select(".info-wrap").first() else {
            return ("", nil, nil, nil)
        }
        let author = try wrap.select(".lop").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Drop child elements (the author span and the comment-anchor link)
        // so the remaining text is just the `| 14:18 | 조회 5,027 | 추천 2` tail.
        guard let copy = wrap.copy() as? Element else {
            return (author, nil, nil, nil)
        }
        try copy.select(".lop, .comment-anchor, a").remove()
        let tail = try copy.text().trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = tail.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var date: String?
        var view: Int?
        var recommend: Int?
        for part in parts {
            if part.hasPrefix("조회") {
                view = Int(part.dropFirst("조회".count).filter(\.isNumber))
            } else if part.hasPrefix("추천") {
                recommend = Int(part.dropFirst("추천".count).filter(\.isNumber))
            } else if !part.isEmpty, date == nil {
                // First unlabelled segment is the posting time (`14:18` for
                // same-day, `YYYY.MM.DD` for older posts).
                date = part
            }
        }

        return (author, date, view, recommend)
    }

    // MARK: - Body blocks

    nonisolated private func extractBlocks(in doc: Document) throws -> [ContentBlock] {
        guard let wrap = try doc.select("#userct").first() else { return [] }
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
            inline.appendText("\n")
        }
    }

    nonisolated private func realImageURL(from el: Element) throws -> URL? {
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

    /// Preserve HTML5 `<video poster="...">` so the inline tap-to-play frame
    /// shows the site thumbnail rather than a plain black rectangle.
    nonisolated private func videoPoster(from el: Element) throws -> URL? {
        let raw = try el.attr("poster").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let normalized = raw.hasPrefix("//") ? "https:" + raw : raw
        guard let url = URL(string: normalized, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    nonisolated private func videoURL(from el: Element) throws -> URL? {
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

    nonisolated private func youtubeID(from src: String) -> String? {
        let ns = src as NSString
        guard let match = Self.youtubeIDRegex.firstMatch(in: src, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - Comment AJAX params

    nonisolated private struct CommentParams {
        let bbsid: String
        let tos: String
        let cmrno: String
        let cmx: String
        let splno: String
    }

    nonisolated private static func extractCommentParams(html: String) throws -> CommentParams? {
        let doc = try SwiftSoup.parse(html)
        guard let box = try doc.select("#comment_box").first() else { return nil }
        let bbsid = try box.attr("data-bbsid")
        let tos = try box.attr("data-tos")
        let cmrno = try box.attr("data-cmrno")
        let cmx = try box.attr("data-cmx")
        let splno = try box.attr("data-splno")
        guard !bbsid.isEmpty, !tos.isEmpty, !cmrno.isEmpty else { return nil }
        return CommentParams(
            bbsid: bbsid,
            tos: tos,
            cmrno: cmrno,
            cmx: cmx.isEmpty ? "50" : cmx,
            splno: splno.isEmpty ? "50" : splno
        )
    }

    // MARK: - Comment JSON decoding

    /// SLR's JSON shape (relevant fields only):
    /// ```
    /// { "cmx": "42",
    ///   "c": [
    ///     { "pk": "bmgohn", "name": "BruceWillis", "memo": " 귀요미",
    ///       "vt": 3, "dt": "14:19", "th": null, "tn": null, "del": 0 },
    ///     { "pk": "bmgoie", "name": "봄날~*", "memo": " 저도 평냉…",
    ///       "vt": 0, "dt": "14:22", "th": 392716855, "tn": "BruceWillis",
    ///       "del": 0 }, …
    ///   ] }
    /// ```
    /// - `th != null` signals a reply (the thread id of its parent).
    /// - `vt` is the net vote score SLR renders next to the like button.
    /// - `del == 1` is a soft-deleted row we drop outright.
    nonisolated private struct SLRJSON: Decodable {
        let c: [SLRComment]?
    }

    nonisolated private struct SLRComment: Decodable {
        let pk: String?
        let name: String?
        let memo: String?
        let vt: Int?
        let dt: String?
        let th: Int?
        let tn: String?
        let del: Int?
    }

    nonisolated private func decodeComments(data: Data) -> [Comment] {
        guard let payload = try? JSONDecoder().decode(SLRJSON.self, from: data),
              let entries = payload.c
        else { return [] }

        var results: [Comment] = []
        for (idx, entry) in entries.enumerated() {
            if (entry.del ?? 0) != 0 { continue }
            let author = (entry.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rendered = renderMemo(entry.memo ?? "")
            if author.isEmpty, rendered.text.isEmpty, rendered.sticker == nil { continue }

            let id = "slr-c-\(entry.pk ?? "idx\(idx)")"
            results.append(Comment(
                id: id,
                author: author,
                dateText: entry.dt ?? "",
                content: rendered.text,
                likeCount: entry.vt ?? 0,
                isReply: entry.th != nil,
                stickerURL: rendered.sticker,
                videoURL: rendered.video
            ))
        }
        return results
    }

    /// SLR serialises comment bodies as HTML fragments inside the JSON `memo`
    /// field (e.g. `저도 ... <br />\n전기차로 <br />\n<img src="//media...jpg">`).
    /// Parse the fragment so:
    ///   - `<br>` becomes a real newline
    ///   - `<img>` gets hoisted out as an inline sticker URL (first match)
    ///   - all other tags get stripped so users don't see raw `<br />` in text
    /// Private-use sentinel: SwiftSoup's `.text()` normalises whitespace (any
    /// run of tabs/newlines/spaces collapses to a single space), so swapping
    /// `<br>` for a TextNode `"\n"` actually produces a space in the output.
    /// A private-use codepoint survives `.text()` untouched, so we sub it in
    /// for the `<br>` runs before parsing and restore real newlines after.
    nonisolated private static let brSentinel = "\u{E000}"

    nonisolated private func renderMemo(_ memo: String) -> (text: String, sticker: URL?, video: URL?) {
        let raw = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return ("", nil, nil) }
        // Fast path: no tags at all → original trimmed text.
        if !raw.contains("<") { return (raw, nil, nil) }

        // Swap <br[/]>  → sentinel so the collapsed `.text()` pass preserves
        // the line break. Regex covers `<br>`, `<br/>`, `<br />`, mixed case.
        let prepped = raw.replacingOccurrences(
            of: #"<\s*[Bb][Rr]\s*/?\s*>"#,
            with: Self.brSentinel,
            options: .regularExpression
        )

        do {
            let doc = try SwiftSoup.parseBodyFragment(prepped)
            let body = doc.body() ?? doc

            var sticker: URL?
            if sticker == nil, let img = try body.select("img").first() {
                var src = try img.attr("src")
                if src.isEmpty { src = try img.attr("data-src") }
                if !src.isEmpty {
                    let normalized = src.hasPrefix("//") ? "https:" + src : src
                    if let url = URL(string: normalized, relativeTo: Site.slr.baseURL)?.absoluteURL,
                       let scheme = url.scheme?.lowercased(),
                       scheme == "http" || scheme == "https" {
                        sticker = url
                    }
                }
            }

            // SLR ships GIF-heavy comments as inline `<video>` (often with an
            // mp4 `<source>` child) so the detail view can replay them via
            // `InlineVideoPlayer`. Mirror the body-level videoURL extraction
            // shape here; without it, the video is invisible and its HTML
            // fallback message ("Your browser does not support...") leaks
            // into the comment text below.
            var video: URL?
            if let vid = try body.select("video").first() {
                var vidSrc = try vid.attr("src")
                if vidSrc.isEmpty, let source = try vid.select("source").first() {
                    vidSrc = try source.attr("src")
                }
                if let hash = vidSrc.firstIndex(of: "#") {
                    vidSrc = String(vidSrc[..<hash])
                }
                if !vidSrc.isEmpty {
                    let normalized = vidSrc.hasPrefix("//") ? "https:" + vidSrc : vidSrc
                    if let url = URL(string: normalized, relativeTo: Site.slr.baseURL)?.absoluteURL,
                       let scheme = url.scheme?.lowercased(),
                       scheme == "http" || scheme == "https" {
                        video = url
                    }
                }
            }

            // Drop img/video/script/style — they're rendered separately
            // (sticker/video URLs above) or irrelevant. Dropping <video> also
            // prevents the browser-fallback text ("Your browser does not
            // support the video tag.") from leaking into the comment body.
            try body.select("img, video, source, script, style").remove()
            // Preserve anchors as tappable markdown links — `.text()` below
            // would otherwise drop the href.
            convertAnchorsToMarkdown(in: body)
            let collapsed = try body.text()
            // After sentinel→newline, strip whitespace that SwiftSoup's
            // `.text()` left on either side of the sentinel (it collapses
            // `\n` / adjacent spaces to single spaces but keeps them). Without
            // this, `좋아했는데<br />\n전기차로` becomes `좋아했는데\n 전기차로`
            // — i.e. a visible leading space / indent on the new line.
            let text = collapsed
                .replacingOccurrences(
                    of: "[ \t]*\(Self.brSentinel)[ \t]*",
                    with: "\n",
                    options: .regularExpression
                )
                .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text, sticker, video)
        } catch {
            // Bad markup → strip obvious `<br>` tokens directly so the user
            // at least sees readable text instead of raw HTML.
            let stripped = raw
                .replacingOccurrences(
                    of: #"<\s*[Bb][Rr]\s*/?\s*>"#,
                    with: "\n",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (stripped, nil, nil)
        }
    }
}
