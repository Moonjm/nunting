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
            comments: Self.extractComments(from: html)
        )
    }

    /// Etoland's SSR is non-deterministic: sometimes the page ships
    /// comments inline in the `__next_f.push` blob, sometimes it emits a
    /// `BAILOUT_TO_CLIENT_SIDE_RENDERING` template and the comment data
    /// only lands after client-side hydration. parseDetail handles the
    /// inline case; this URL is the fallback the loader hits when the
    /// inline comments were absent.
    nonisolated func commentsURL(for post: Post) -> URL? {
        Self.commentsAPIURL(for: post.url)
    }

    /// Skip the network round-trip when `parseDetail` already extracted
    /// comments from the SSR blob — checking for the JS-escaped
    /// `"comments":[` marker is a 1-shot string scan, much cheaper than
    /// the API call. When the marker is absent, fall through to the
    /// public comments endpoint and JSON-decode the response.
    nonisolated func fetchAllComments(
        for post: Post,
        detailHTML: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [Comment] {
        if let html = detailHTML, html.contains(#"\"comments\":["#) {
            // Inline path won; whatever parseDetail surfaced is correct,
            // so don't replace it with a parallel network result.
            return []
        }
        guard let url = Self.commentsAPIURL(for: post.url) else { return [] }
        let body = try await fetcher(url)
        guard let data = body.data(using: .utf8),
              let response = try? JSONDecoder().decode(APIResponse.self, from: data),
              response.status == "ETOCD200000",
              let comments = response.data?.comments
        else { return [] }
        var out: [Comment] = []
        for r in comments { Self.flatten(r, into: &out, isReply: false) }
        return out
    }

    /// Reverse-engineered from the etoland Next.js client (chunk
    /// `0f7oc_gjz_r8m.js`): `apiClient.get(\`board/${boTable}/article/slug/${slug}/comments\`, { params })`
    /// resolves to this absolute URL on the same host. Slug is the URL's
    /// path tail past `/view/` (etoland leaves it URL-encoded; the API
    /// expects it that way too, so we don't decode here).
    nonisolated private static func commentsAPIURL(for postURL: URL) -> URL? {
        guard let host = postURL.host?.lowercased(),
              host.hasSuffix("etoland.co.kr")
        else { return nil }
        let parts = postURL.pathComponents.filter { $0 != "/" }
        // Expected shape: ["b", "<boTable>", "view", "<slug>"]
        guard parts.count >= 4,
              parts[0] == "b",
              parts[2] == "view"
        else { return nil }
        let boTable = parts[1]
        let slug = parts[3]
        guard !boTable.isEmpty, !slug.isEmpty else { return nil }
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "etoland.co.kr"
        comps.path = "/api/v1/board/\(boTable)/article/slug/\(slug)/comments"
        comps.queryItems = [
            URLQueryItem(name: "comment_page", value: "0"),
            URLQueryItem(name: "comm_page_size", value: "50"),
        ]
        return comps.url
    }

    nonisolated private struct APIResponse: Decodable {
        let status: String
        let data: APIData?

        struct APIData: Decodable {
            let comments: [RawComment]?
        }
    }

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

        // Etoland wraps `<video>` in a React-built custom player whose
        // sibling overlays (play button, scrubber, time readout `0:00/0:00`,
        // `1x` speed selector) are visible only via CSS positioning. The
        // browser hides them on idle/hover; SwiftSoup's `.text()` walker
        // treats them as plain prose and leaks the labels into the
        // rendered post body. Detect the wrapper by its `board-video-player`
        // class, extract just the inner `<video>` block, and skip every
        // overlay sibling. Falling back to the generic `<video>` branch
        // below covers the rare unwrapped case.
        if tag == "div", Self.isVideoPlayerWrapper(el) {
            if let video = try el.select("video").first(),
               let url = try videoURL(from: video) {
                flushInline(into: &blocks, inline: &inline)
                blocks.append(.video(url, posterURL: try videoPoster(from: video)))
            }
            return
        }

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

    /// Etoland's custom video-player wrapper carries `board-video-player`
    /// among its (long, Tailwind-generated) class list. Match on whitespace-
    /// separated tokens so the check stays correct if the surrounding
    /// utility classes are reordered or renamed.
    nonisolated private static func isVideoPlayerWrapper(_ el: Element) -> Bool {
        guard let raw = try? el.attr("class"), !raw.isEmpty else { return false }
        return raw.split(whereSeparator: { $0.isWhitespace })
            .contains("board-video-player")
    }

    // MARK: - Comments

    /// Etoland's Next.js page ships the full comment tree inline in a
    /// `__next_f.push([1, "<JS-string>"])` script tag — the same data the
    /// hydrated client would render. Pull the `"comments":[…]` array out
    /// of the JS string by bracket-walking the HTML bytes (tracking
    /// `\"` quote toggles and `\\` escapes), unescape JS string syntax
    /// to recover real JSON, then decode and flatten the nested
    /// `childrenComments` into a flat `[Comment]` with reply markers.
    nonisolated private static func extractComments(from html: String) -> [Comment] {
        guard let arrayJSON = extractCommentsArrayJS(from: html) else { return [] }
        let unescaped = unescapeJSString("[" + arrayJSON + "]")
        guard let data = unescaped.data(using: .utf8) else { return [] }
        guard let raw = try? JSONDecoder().decode([RawComment].self, from: data) else { return [] }
        var out: [Comment] = []
        for r in raw { flatten(r, into: &out, isReply: false) }
        return out
    }

    /// Return the contents of the first `\"comments\":[ … ]` array we find
    /// in the HTML, exclusive of the outer brackets, still in JS-escaped
    /// form. The walker keeps a depth counter for `[`/`{` and `]`/`}`,
    /// toggling string state on `\"` and consuming any `\X` escape pair
    /// in one step (so brackets that appear inside string content don't
    /// throw the depth count off).
    nonisolated private static func extractCommentsArrayJS(from html: String) -> String? {
        let marker = #"\"comments\":["#
        guard let r = html.range(of: marker) else { return nil }
        let chars = Array(html[r.upperBound...])
        var depth = 1
        var inString = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "\"" {
                    inString.toggle()
                }
                i += 2
                continue
            }
            if !inString {
                if c == "[" || c == "{" {
                    depth += 1
                } else if c == "]" || c == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(chars[0..<i])
                    }
                }
            }
            i += 1
        }
        return nil
    }

    /// Decode JS-string escapes (`\"`, `\\`, `\n`, `\t`, `\r`, `\/`,
    /// `\uXXXX`) into their literal characters so the result is valid
    /// JSON. Other backslash sequences pass the second char through
    /// unchanged — etoland doesn't ship anything weirder than the above.
    nonisolated private static func unescapeJSString(_ s: String) -> String {
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
                var hex = ""
                for _ in 0..<4 { if let h = iter.next() { hex.append(h) } }
                if let scalar = UInt32(hex, radix: 16).flatMap(UnicodeScalar.init) {
                    out.append(Character(scalar))
                }
            default:
                out.append(next)
            }
        }
        return out
    }

    nonisolated private static func flatten(_ raw: RawComment, into out: inout [Comment], isReply: Bool) {
        let author: String = {
            if let nick = raw.member?.nickname, !nick.isEmpty { return nick }
            if raw.isAnonymous == true { return "익명" }
            return ""
        }()
        let dateText = raw.writeDateTimestamp.map(formatDate) ?? ""
        let avatarURL: URL? = raw.member?.image.flatMap { URL(string: $0) }
        let trimmedContent = (raw.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Image / video attachments live under `file: {...}` on the comment
        // object — `bfType` discriminates, `bfFile` is a CDN-relative path
        // resolved against `btcdn.etoland.co.kr/static`. Videos prefer
        // `bfMp4File` (transcoded mp4) over `bfFile` (often the original
        // upload format) so the inline player sees a directly-playable URL.
        let attachedSticker: URL? = {
            guard raw.file?.bfType == "image", let path = raw.file?.bfFile else { return nil }
            return Self.cdnURL(path: path)
        }()
        let attachedVideo: URL? = {
            guard raw.file?.bfType == "video" else { return nil }
            if let mp4 = raw.file?.bfMp4File, !mp4.isEmpty,
               let url = Self.cdnURL(path: mp4) { return url }
            if let path = raw.file?.bfFile { return Self.cdnURL(path: path) }
            return nil
        }()

        // Etocon emoji stamps: `content` is empty and the visual lives at
        // `emojiItem.path`. Treat exactly like an image attachment so the
        // existing comment renderer's `stickerURL` path picks them up.
        let emojiSticker: URL? = {
            guard attachedSticker == nil,
                  let p = raw.emojiItem?.path,
                  !p.isEmpty
            else { return nil }
            return URL(string: p)
        }()

        // Comments whose entire body is a pasted image / video URL render as
        // a media bubble too — match the shape we already use for aagag /
        // humoruniv (`stripCommentHTML` + `extractCommentImageURL`). Only
        // promote when no `file` attachment already won, and only for the
        // exact extensions etoland's own renderer treats as inline media.
        let contentSticker: URL? = {
            guard attachedSticker == nil, attachedVideo == nil,
                  let url = URL(string: trimmedContent),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            let ext = url.pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "gif", "webp"].contains(ext) ? url : nil
        }()
        let contentVideo: URL? = {
            guard attachedSticker == nil, attachedVideo == nil, contentSticker == nil,
                  let url = URL(string: trimmedContent),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            let ext = url.pathExtension.lowercased()
            return ["mp4", "webm", "mov"].contains(ext) ? url : nil
        }()

        let stickerURL = attachedSticker ?? emojiSticker ?? contentSticker
        let videoURL = attachedVideo ?? contentVideo
        // When the content text was *the* URL we just promoted, drop it
        // so the bubble doesn't render the URL string under its image.
        let finalContent: String = {
            if contentSticker != nil || contentVideo != nil { return "" }
            return trimmedContent
        }()

        out.append(Comment(
            id: "etoland-c-\(raw.commentId)",
            author: author,
            dateText: dateText,
            content: finalContent,
            likeCount: raw.recommendCount ?? 0,
            isReply: isReply,
            stickerURL: stickerURL,
            videoURL: videoURL,
            authIconURL: avatarURL
        ))
        for child in raw.childrenComments ?? [] {
            flatten(child, into: &out, isReply: true)
        }
    }

    /// Etoland's `bfFile` / `bfMp4File` paths are CDN-relative; the static
    /// host is `btcdn.etoland.co.kr/static`. Verified against
    /// `/media/etohumor07/.../*.jpg` returning 200 from that base.
    nonisolated private static func cdnURL(path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        let normalized = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        return URL(string: "https://btcdn.etoland.co.kr/static" + normalized)
    }

    /// Etoland publishes timestamps as epoch milliseconds (UTC). Render
    /// the user's local time zone via the same `YYYY-MM-DD HH:MM` shape
    /// the rest of the app uses, so list-detail comment headers don't
    /// need site-specific formatting.
    nonisolated private static func formatDate(_ epochMillis: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.locale = Locale(identifier: "ko_KR")
        return fmt.string(from: date)
    }

    nonisolated private struct RawComment: Decodable {
        let commentId: Int
        let parentId: Int?
        let writeDateTimestamp: Int?
        let recommendCount: Int?
        let content: String?
        let isAnonymous: Bool?
        let member: RawMember?
        let childrenComments: [RawComment]?
        let file: RawFile?
        let emojiItem: RawEmoji?

        struct RawMember: Decodable {
            let nickname: String?
            let image: String?
        }
        struct RawFile: Decodable {
            let bfFile: String?
            let bfType: String?
            let bfMp4File: String?
        }
        /// Etoland's "etocon" emoji stamps. When the user picks one as
        /// their comment, `content` is empty and `path` holds the
        /// already-absolute CDN URL of the GIF.
        struct RawEmoji: Decodable {
            let path: String?
        }
    }
}
