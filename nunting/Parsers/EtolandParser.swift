import Foundation
import SwiftSoup
/// Parses etoland (이토랜드) detail pages. Reached exclusively via aagag mirror
/// redirects — etoland's mobile detail URL pattern is
/// `etoland.co.kr/b/{board}/view/{slug-or-id}-{post_id}`.
///
/// Etoland is a Next.js SSR app. Title, meta, body blocks, and (sometimes)
/// the full comment tree are rendered into the initial HTML inside a
/// `__next_f.push([1, "<JS-string>"])` payload. parseDetail extracts all of
/// those. Comments specifically are non-deterministic in SSR — the same
/// post can ship with `\"comments\":[…]` inline on one request and emit a
/// `BAILOUT_TO_CLIENT_SIDE_RENDERING` template on the next. When the
/// inline payload is missing, `fetchAllComments` falls back to the public
/// API at `/api/v1/board/{boTable}/article/slug/{slug}/comments`
/// (reverse-engineered from the etoland Next.js client chunks) and decodes
/// the same `RawComment` shape so attachments / etocon emoji / replies
/// surface either way.
public struct EtolandParser: BoardParser {
    public let site: Site = .etoland

    public nonisolated init() {}

    public nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        // Etoland is aagag-dispatch-only; list parsing is never invoked.
        []
    }

    public nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)

        // Etoland's deleted-post page replaces the article wrapper with a
        // notice block. The most reliable signal is the absence of the
        // post `<h1>` inside `<article>`; fall back to a notice in that
        // case so the user sees a clear message instead of an empty body.
        guard let article = try doc.select("article:has(h1)").first(where: { el in
            (try? el.select("div.view-content").first()) != nil
                || (try? el.select("h1").first()?.text())?.isEmpty == false
        }) else {
            // Deletion/relocation is a valid response — show a notice. Any
            // other reason the article wrapper is gone means the markup
            // changed; throw so the user sees the "구조가 바뀐 것 같아요" signal
            // instead of a silently blank post. The keyword set is unverified
            // against a real etoland deletion sample — throw is the safe
            // fallback (informative banner, not a blank). Broaden the keywords
            // here if a real deleted post ever shows "구조가 바뀜" by mistake.
            let body = try doc.text()
            guard body.contains("삭제") || body.contains("이동")
                || body.contains("존재하지") || body.contains("없는 게시물") else {
                throw ParserError.structureChanged("etoland article 없음")
            }
            return PostDetail(
                post: post,
                blocks: [.text("삭제되거나 이동된 게시물입니다.")],
                fullDateText: nil,
                viewCount: nil,
                source: nil,
                comments: []
            )
        }

        let title = ParserText.cleanTitle(try extractTitle(in: article, fallback: post.title))
        let meta = try extractMeta(in: article)
        let blocks = try extractBlocks(in: article)

        let updated = post.enrichedForDetail(
            title: title,
            author: meta.author.isEmpty ? post.author : meta.author,
            commentCount: meta.commentCount,
            viewCount: meta.viewCount,
            recommendCount: meta.recommendCount
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
    public nonisolated func commentsURL(for post: Post) -> URL? {
        Self.commentsAPIURL(for: post.url)
    }

    /// Skip the network round-trip when `parseDetail` already extracted
    /// comments from the SSR blob — checking for the JS-escaped envelope
    /// shape is a 1-shot string scan, much cheaper than the API call.
    /// When the marker is absent, fall through to the public comments
    /// endpoint and JSON-decode the response.
    public nonisolated func fetchAllComments(
        for post: Post,
        detailHTML: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [PostComment] {
        // Match the wire envelope `"data":{"comments":[…]}` rather than the
        // bare `"comments":[` substring — the latter false-positives on
        // any user comment whose body literally contains `"comments":[`
        // (programming/JSON discussion threads). Etoland always wraps the
        // array under `data` in the SSR push, so the longer marker has
        // effectively zero false-positive surface.
        if let html = detailHTML, html.contains(#"\"data\":{\"comments\":["#) {
            // Inline path won; whatever parseDetail surfaced is correct,
            // so don't replace it with a parallel network result.
            return []
        }
        guard let url = Self.commentsAPIURL(for: post.url) else { return [] }
        let body = try await fetcher(url)
        // 디코드/상태 실패는 throw 한다 — `try?` + `return []` 로 뭉개면 "댓글
        // 없는 글"과 구분 불가해, 호출부(PostDetailLoader)의 Result 분류가
        // 실패를 못 잡고 재시도 배너(`commentsFailed`)가 영영 안 뜬다.
        // 단, status 성공인데 comments 가 nil/빈 건 "진짜 댓글 없는 글"이라
        // throw 가 아니라 `[]`. (인라인 우선 경로는 위에서 이미 return.)
        guard let data = body.data(using: .utf8) else {
            throw ParserError.invalidHTML
        }
        let response: APIResponse
        do {
            response = try JSONDecoder().decode(APIResponse.self, from: data)
        } catch {
            throw ParserError.structureChanged("etoland 댓글 응답 디코드 실패")
        }
        guard response.status == "ETOCD200000" else {
            throw ParserError.structureChanged("etoland 댓글 status \(response.status)")
        }
        var out: [PostComment] = []
        for r in response.data?.comments ?? [] { Self.flatten(r, into: &out, isReply: false) }
        return out
    }

    /// Reverse-engineered from the etoland Next.js client (chunk
    /// `0f7oc_gjz_r8m.js`): `apiClient.get(\`board/${boTable}/article/slug/${slug}/comments\`, { params })`
    /// resolves to this absolute URL on the same host. Slug round-trip:
    /// `URL.pathComponents` decodes percent-escapes, then assigning to
    /// `URLComponents.path` re-encodes when serializing via `.url`, so the
    /// final URL has the same encoding as the originating post URL. The
    /// API accepts either encoding, so the round-trip is observationally
    /// transparent — the decode/re-encode is just an artifact of how the
    /// Foundation URL types work, not a deliberate choice.
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
                view = ParserText.integerFromDigits(in: text.dropFirst("조회".count))
            } else if text.hasPrefix("추천") {
                recommend = ParserText.integerFromDigits(in: text.dropFirst("추천".count))
            } else if text.hasPrefix("댓글") {
                comments = ParserText.integerFromDigits(in: text.dropFirst("댓글".count))
            }
        }
        let normalizedDate = dateText?.isEmpty == false ? dateText : nil
        return (author, normalizedDate, view, recommend, comments)
    }

    // MARK: - Body blocks

    nonisolated private func extractBlocks(in article: Element) throws -> [ContentBlock] {
        guard let wrap = try article.select("div.view-content").first() else { return [] }

        var rules = WalkerRules.standard(for: self)
        // data-src → src: Next.js `<Image>` ships the unoptimised original in
        // `data-src` and a CDN-transform URL (920-wide WebP) in `src`; prefer
        // the original so Retina renders don't pin to the downscaled WebP.
        rules.resolveImageURL = { imageURL(from: $0, attributes: ["data-src", "src"]) }
        rules.resolveVideoURL = videoURL(from:)       // data-src → src → all <source>, plus #t= strip
        rules.customElement = customElementHandler(_:)
        return try ParserBlockWalker(parser: self, rules: rules).walk(wrap)
    }

    /// `<div class="board-video-player">` React 커스텀 비디오 플레이어 처리.
    /// wrapper 안에 진짜 `<video>` 하나 + overlay (play button / scrubber
    /// `0:00/0:00` / `1x` 등)가 형제로 들어있어서, walker 가 그대로 walk 하면
    /// overlay 텍스트가 본문에 누수된다. 여기서 비디오 URL 만 뽑아 video 블록
    /// 으로 promote 하고 wrapper 자식 전체를 skip.
    nonisolated private func customElementHandler(_ el: Element) throws -> [ContentBlock]? {
        guard el.tagName().lowercased() == "div",
              Self.isVideoPlayerWrapper(el)
        else { return nil }
        guard let video = try el.select("video").first(),
              let url = try videoURL(from: video)
        else { return [] }
        return [.video(url, posterURL: try videoPoster(from: video))]
    }

    /// Etoland's React video player renders the `<video>` lazily: the real
    /// mp4 sits in `data-src=` and `src=` is left empty until the user taps
    /// play (mirroring how `<Image>` ships `src` + `data-src` for the same
    /// reason). Probe `data-src` first so the parser surfaces the URL even
    /// when the page hasn't hydrated, then fall back to `src` and any
    /// `<source>` children for older / non-lazy markup.
    nonisolated private func videoURL(from el: Element) throws -> URL? {
        for attr in ["data-src", "src"] {
            let raw = strippedMediaFragment(try el.attr(attr))
            if let url = resolveHTTPURL(raw) { return url }
        }
        for source in try el.select("source") {
            for attr in ["data-src", "src"] {
                let raw = strippedMediaFragment(try source.attr(attr))
                if let url = resolveHTTPURL(raw) { return url }
            }
        }
        return nil
    }

    nonisolated private func strippedMediaFragment(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = trimmed.firstIndex(of: "#") else { return trimmed }
        return String(trimmed[..<hash])
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
    /// `childrenComments` into a flat `[PostComment]` with reply markers.
    nonisolated private static func extractComments(from html: String) -> [PostComment] {
        guard let arrayJSON = extractCommentsArrayJS(from: html) else { return [] }
        let unescaped = ParserText.unescapeJSString("[" + arrayJSON + "]")
        guard let data = unescaped.data(using: .utf8) else { return [] }
        guard let raw = try? JSONDecoder().decode([RawComment].self, from: data) else { return [] }
        var out: [PostComment] = []
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

    nonisolated private static func flatten(_ raw: RawComment, into out: inout [PostComment], isReply: Bool, replyTarget: String? = nil) {
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

        out.append(PostComment(
            id: "etoland-c-\(raw.commentId)",
            author: author,
            dateText: dateText,
            content: finalContent,
            likeCount: raw.recommendCount ?? 0,
            isReply: isReply,
            replyTarget: replyTarget,
            stickerURL: stickerURL,
            videoURL: videoURL,
            authIconURL: avatarURL
        ))
        // 답글은 content/데이터에 대상 표기가 없고 중첩 구조로만 표현되므로,
        // 자식에게 현재(부모) 닉네임을 대상으로 넘겨 뷰가 파란 @대상 으로 렌더.
        for child in raw.childrenComments ?? [] {
            flatten(child, into: &out, isReply: true, replyTarget: author.isEmpty ? nil : author)
        }
    }

    /// Etoland's `bfFile` / `bfMp4File` paths are CDN-relative; the static
    /// host is `btcdn.etoland.co.kr/static`. Verified against
    /// `/media/etohumor07/.../*.jpg` returning 200 from that base.
    /// `appendingPathComponent` percent-encodes any non-ASCII / unsafe
    /// chars in the path, so an upload whose filename contains spaces
    /// or Korean characters still resolves correctly — string concat
    /// would have returned `nil` from `URL(string:)` for those.
    nonisolated private static func cdnURL(path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        let normalized = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        return cdnBaseURL?.appendingPathComponent(normalized)
    }

    /// Pre-built so `cdnURL` doesn't reparse the host string per call —
    /// shows up cheaply but `flatten` runs once per comment and the
    /// constant base is unchanging.
    nonisolated private static let cdnBaseURL: URL? = URL(string: "https://btcdn.etoland.co.kr/static/")

    /// Etoland publishes timestamps as epoch milliseconds (UTC). Render
    /// the user's local time zone via the same `YYYY-MM-DD HH:MM` shape
    /// the rest of the app uses, so list-detail comment headers don't
    /// need site-specific formatting.
    nonisolated private static func formatDate(_ epochMillis: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        return commentDateFormatter.string(from: date)
    }

    /// `DateFormatter` is expensive to construct (locale + format-string
    /// resolution); long comment threads called this once per row in the
    /// previous incarnation. Hoist a single shared formatter so each
    /// subsequent comment is a simple `string(from:)` call. Same pattern
    /// the other parsers use for hoisted regex compilations.
    nonisolated private static let commentDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.locale = Locale(identifier: "ko_KR")
        return fmt
    }()

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
