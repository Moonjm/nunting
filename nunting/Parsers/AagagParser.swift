import Foundation
import SwiftSoup
public struct AagagParser: BoardParser {
    public let site: Site = .aagag

    public nonisolated init() {}

    nonisolated private static let imageHost = "https://i.aagag.com"
    // YouTube IDs are exactly 11 chars from [A-Za-z0-9_-].
    nonisolated private static let youtubeIDRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]{11}$"#)
    // Instagram shortcodes are 5+ chars from [A-Za-z0-9_-].
    nonisolated private static let instaIDRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]+$"#)
    // Hoisted regexes — these run on every detail parse and per stripHTML
    // chunk respectively, so per-call NSRegularExpression construction
    // showed up as measurable overhead on image-heavy posts.
    nonisolated private static let contentScriptRegex = try! NSRegularExpression(
        pattern: #"AAGAG_AA\.content\s*=\s*"((?:[^"\\]|\\.)*)""#,
        options: [.dotMatchesLineSeparators]
    )
    nonisolated private static let numericEntityRegex = try! NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#)

    /// Heuristic: does this body look like Aagag's CAPTCHA / bot-check
    /// interstitial rather than a real list/detail page? Used by
    /// `BotCheckRegistry` → `Networking.fetchHTML` to trigger the
    /// `BotCheckCoordinator` flow, AND re-run on the post-recovery
    /// retry body to decide whether to surface `.captchaChallenge`.
    ///
    /// Requires BOTH signals simultaneously to flag (AND, not OR):
    ///   1. Body is much shorter than a real Aagag page (real list /
    ///      detail pages are consistently tens of KB; the challenge
    ///      page is a tiny stub).
    ///   2. Body contains one of the interstitial markers below. Real
    ///      challenge page (captured 2026-05-25) is bilingual — Korean
    ///      body + English "judged as a bot" line — and historical
    ///      Aagag captcha pages used a different keyword set. Match
    ///      either family; the size gate keeps generic forum quotes
    ///      from masquerading as a challenge.
    ///
    /// The AND-on-marker requirement is critical for the retry
    /// false-positive path: if `Networking.fetchHTML` re-fetches after
    /// the user solves the challenge and the retry response is short
    /// for ANY reason (transient 200 with empty body, server hiccup),
    /// an OR-on-size-alone detector would throw `.captchaChallenge`
    /// and break a fetch the user actually fixed. Requiring a marker
    /// substring means a generic short body can't trigger the failure
    /// throw.
    public nonisolated static func looksLikeBotCheck(html: String) -> Bool {
        guard html.count < 5_000 else { return false }
        // 2026-05-25 markers (current production interstitial)
        return html.contains("봇으로 판단")
            || html.contains("Captcha인증")
            || html.contains("judged as a bot")
            // Historical markers — kept in case the page reverts or
            // a regional variant uses the older copy.
            || html.contains("자동등록방지")
            || html.contains("문자를 입력")
            || html.contains("로봇이 아닙니다")
    }

    public nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        let doc = try SwiftSoup.parse(html)
        // Restrict to actual data tables (`table.aalist` minus the `.header` and minus
        // sidebar `div.aalist.layer` previews/sliders).
        let articles = try doc.select("table.aalist:not(.header) a.article")

        var seen = Set<String>()
        var results: [Post] = []
        for el in articles {
            let rawHref = try el.attr("href")
            guard !rawHref.isEmpty else { continue }
            // Mirror items ship relative hrefs like "re?ss=humor_N" that must
            // resolve under /mirror/. Resolving against site.baseURL alone
            // drops the /mirror/ segment and the server 404s. Issue items use
            // absolute /issue/?idx=… paths and don't need this fix.
            let href: String
            if rawHref.hasPrefix("./re?") {
                href = "/mirror/" + String(rawHref.dropFirst(2))
            } else if rawHref.hasPrefix("re?") {
                href = "/mirror/" + rawHref
            } else {
                href = rawHref
            }
            guard let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { continue }

            // De-dup: aagag often repeats hot items at the bottom of issue pages.
            let ss = try el.attr("ss")
            let dedupKey = ss.isEmpty ? url.absoluteString : ss
            if !seen.insert(dedupKey).inserted { continue }

            let titleEl = try el.select("span.title").first()
            let titleCopy = titleEl.flatMap { $0.copy() as? Element } ?? titleEl
            try titleCopy?.select("span.btmlayer, span.cmt").remove()
            let title = ParserText.cleanTitle(try titleCopy?.text() ?? "")
            guard !title.isEmpty else { continue }

            // Date: first <u> inside .date wrapper for mirror; .time for issue.
            let dateText = try (
                el.select("span.date u").first()?.text()
                    ?? el.select("span.time u").first()?.text()
                    ?? ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            let viewText = try el.select("span.hit u").first()?.text() ?? ""
            let viewCount = viewText.isEmpty ? nil : Int(viewText.filter(\.isNumber))

            let cmtText = try el.select("span.cmt").first()?.text() ?? ""
            let commentCount = Int(cmtText.filter(\.isNumber)) ?? 0

            let author = try el.select("span.nick u").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // Source-site label (mirror only): the rank span carries class like `bc_ppomppu`.
            let sourceLabel: String? = try {
                guard let rank = try el.select("span.rank, span.lo").first() else { return nil }
                let cls = try rank.attr("class")
                let token = cls.split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
                    .first(where: { $0.hasPrefix("bc_") })
                guard let token else { return nil }
                return String(token.dropFirst(3))
            }()

            let postID = ss.isEmpty ? UUID().uuidString : ss

            results.append(Post(
                id: "\(board.id)-\(postID)",
                site: site,
                boardID: board.id,
                title: title,
                author: author,
                date: nil,
                dateText: dateText,
                commentCount: commentCount,
                url: url,
                viewCount: viewCount,
                recommendCount: nil,
                levelText: sourceLabel,
                hasAuthIcon: false
            ))
        }
        return results
    }

    public nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)
        let titleEl = try doc.select("h1.title").first()
        let cleaned = ParserText.cleanTitle(try titleEl?.text() ?? "")
        let title = cleaned.isEmpty ? post.title : cleaned

        // Issue detail content lives in `AAGAG_AA.content = "..."` inside a script tag,
        // with payloads encoded as `[sTag]{json}[/sTag]`.
        var blocks: [ContentBlock] = []
        if let scriptText = try findContentScript(in: doc) {
            blocks = blocksFromContentString(scriptText)
        }

        let dateText = try doc.select("span.t.odate").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return PostDetail(
            post: Post(
                id: post.id,
                site: post.site,
                boardID: post.boardID,
                title: title,
                author: post.author,
                date: post.date,
                dateText: post.dateText,
                commentCount: post.commentCount,
                url: post.url,
                viewCount: post.viewCount,
                recommendCount: post.recommendCount,
                levelText: post.levelText,
                hasAuthIcon: post.hasAuthIcon
            ),
            blocks: blocks,
            fullDateText: dateText,
            viewCount: nil,
            source: nil,
            comments: []
        )
    }

    nonisolated private func findContentScript(in doc: Document) throws -> String? {
        // Capture the entire string literal body via NSRegularExpression's
        // capture group. The character class `[^"\\]|\\.` matches any non-quote/
        // non-backslash char OR a backslash-escape pair, so we don't trip over
        // `\"` inside the JSON. Using NSString.substring(with: nsRange) avoids
        // the Swift String.Index offset math that previously dropped a couple
        // of characters when the script had Korean text earlier in the body.
        for script in try doc.select("script") {
            let text = script.data()
            let ns = text as NSString
            guard let match = Self.contentScriptRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges >= 2,
                  match.range(at: 1).location != NSNotFound
            else { continue }
            let body = ns.substring(with: match.range(at: 1))
            return Self.unescapeJSString(body)
        }
        return nil
    }

    nonisolated private static func unescapeJSString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var iter = s.makeIterator()
        while let c = iter.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let next = iter.next() else { break }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"": out.append("\"")
            case "'": out.append("'")
            case "\\": out.append("\\")
            case "/": out.append("/")
            case "u":
                var hex = ""
                for _ in 0..<4 {
                    if let h = iter.next() { hex.append(h) }
                }
                if let scalar = UInt32(hex, radix: 16).flatMap(UnicodeScalar.init) {
                    out.append(Character(scalar))
                }
            default:
                out.append(next)
            }
        }
        return out
    }

    /// Parse the AAGAG_AA.content string: text + `[sTag]{json}[/sTag]` payloads.
    /// Uses split-based scanning instead of `String.range` index math, which
    /// avoided some subtle off-by issues we hit on real posts.
    nonisolated private func blocksFromContentString(_ content: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []

        func appendText(_ raw: String) {
            let stripped = stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return }
            blocks.append(.text(stripped))
        }

        let parts = content.components(separatedBy: "[sTag]")
        // Anything before the first `[sTag]` is plain prose / leading whitespace.
        if let prefix = parts.first { appendText(prefix) }

        for part in parts.dropFirst() {
            // Each part should look like `{json...}[/sTag]<trailing html>`.
            let halves = part.components(separatedBy: "[/sTag]")
            if halves.count >= 2 {
                if let block = stagBlock(from: halves[0]) {
                    blocks.append(block)
                }
                // Re-join in the unlikely case multiple `[/sTag]` slipped in;
                // that preserves any literal stray markers in the trailing text.
                let trailing = halves.dropFirst().joined(separator: "[/sTag]")
                appendText(trailing)
            } else {
                // No close tag — treat the whole chunk as text rather than
                // dropping it.
                appendText(part)
            }
        }
        return blocks
    }

    nonisolated private func stripHTML(_ s: String) -> String {
        // Pure-Swift strip: regex tag removal + small entity table. Avoids
        // SwiftSoup parseBodyFragment per chunk so image-heavy posts don't
        // pay an SwiftSoup parse cost N times on the main thread.
        var t = s.replacingOccurrences(
            of: #"<\s*br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        t = t.replacingOccurrences(
            of: #"</?(p|div|li|blockquote|tr)[^>]*>"#,
            with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        t = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        t = Self.decodeBasicEntities(t)
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return t
    }

    /// Decode the entity set we actually see in aagag content. Avoids pulling
    /// SwiftSoup just for `&amp;` / `&nbsp;` decoding.
    nonisolated private static func decodeBasicEntities(_ input: String) -> String {
        var out = input
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")  // last so `&amp;lt;` → `&lt;`
        // Numeric entities `&#NNNN;` and `&#xHHHH;`.
        let ns = out as NSString
        let matches = Self.numericEntityRegex.matches(in: out, range: NSRange(location: 0, length: ns.length))
        // Replace from the back so ranges stay valid.
        for m in matches.reversed() {
            let isHex = ns.substring(with: m.range(at: 1)) == "x"
            let digits = ns.substring(with: m.range(at: 2))
            guard let code = UInt32(digits, radix: isHex ? 16 : 10),
                  let scalar = UnicodeScalar(code)
            else { continue }
            out = (out as NSString).replacingCharacters(in: m.range, with: String(scalar))
        }
        return out
    }

    public nonisolated func commentsURL(for post: Post) -> URL? {
        guard issueIdx(from: post) != nil else { return nil }
        return URL(string: "https://aagag.com/api/cmt")
    }

    public nonisolated func fetchAllComments(
        for post: Post,
        detailHTML _: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [PostComment] {
        // Aagag POSTs to /api/cmt with an `idx` parameter pulled from
        // the post URL — the detail body isn't needed, so `detailHTML`
        // is ignored here.
        guard let idx = issueIdx(from: post),
              let apiURL = URL(string: "https://aagag.com/api/cmt")
        else { return [] }

        let data = try await Networking.postForm(
            url: apiURL,
            parameters: ["idx": idx],
            referer: post.url
        )
        let response = try JSONDecoder().decode(AagagCommentResponse.self, from: data)
        guard response.mode == "success" else { return [] }
        return response.comment.map { raw in
            PostComment(
                id: "\(site.rawValue)-c-\(raw.w_idx)",
                author: raw.w_nick,
                dateText: raw.stime,
                content: stripCommentHTML(raw.w_content),
                likeCount: raw.w_good,
                isReply: (raw.w_cmt_reply ?? "").isEmpty == false,
                stickerURL: extractCommentImageURL(from: raw.w_content),
                authIconURL: nil,
                levelIconURL: nil
            )
        }
    }

    /// Aagag comment HTML can include inline `<img>` attachments (e.g.
    /// 이슈모음 where the comment body is a meme/sticker image). The text
    /// path (`stripCommentHTML`) drops all tags for rendering, so the image
    /// needs a separate pass to surface as `Comment.stickerURL`.
    nonisolated private func extractCommentImageURL(from rawHTML: String) -> URL? {
        // Cheap prefilter: the vast majority of text-only comments never
        // even mention "<img", and spinning up SwiftSoup once per comment
        // dominates the parse budget on long threads otherwise.
        guard rawHTML.contains("<img") else { return nil }
        guard let doc = try? SwiftSoup.parseBodyFragment(rawHTML),
              let img = try? doc.select("img").first(),
              let src = try? img.attr("src"),
              !src.isEmpty,
              let url = URL(string: src, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    nonisolated private func stripCommentHTML(_ raw: String) -> String {
        guard let doc = try? SwiftSoup.parseBodyFragment(raw),
              let body = doc.body()
        else { return raw }

        // Convert anchors to markdown so PostDetailView's comment renderer can
        // make them tappable (shared BoardParser helper).
        convertAnchorsToMarkdown(in: body)
        stampBlockBreaks(in: body)
        return normalizeCommentWhitespace((try? body.text()) ?? raw)
    }

    nonisolated private func issueIdx(from post: Post) -> String? {
        URLComponents(url: post.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "idx" })?
            .value
    }

    nonisolated private struct AagagCommentResponse: Decodable {
        let mode: String
        let comment: [AagagComment]
    }

    nonisolated private struct AagagComment: Decodable {
        let w_idx: Int
        let w_nick: String
        let w_content: String
        let w_good: Int
        let stime: String
        let w_cmt_reply: String?
    }

    /// Decode a single sTag payload into a ContentBlock. Aagag's renderer treats
    /// any payload with `mp4_seq` (or related mp4_* fields) as a video, regardless
    /// of `m`. Image URL has `/o/` prefix, video URL does not.
    /// External embeds (`ytb`, `insta`) become tappable deal-link banners.
    nonisolated private func stagBlock(from payload: String) -> ContentBlock? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let q = json["q"] as? String, !q.isEmpty else { return nil }
        let m = (json["m"] as? String)?.lowercased() ?? ""

        // YouTube / Instagram embeds. Validate IDs to avoid building broken
        // URLs from corrupt payloads.
        if m == "ytb" {
            guard Self.youtubeIDRegex.firstMatch(in: q, range: NSRange(location: 0, length: (q as NSString).length)) != nil else {
                return nil
            }
            return .embed(.youtube, id: q)
        }
        if m == "insta" {
            guard Self.instaIDRegex.firstMatch(in: q, range: NSRange(location: 0, length: (q as NSString).length)) != nil else {
                return nil
            }
            return .embed(.instagram, id: q)
        }

        let isVideo = json["mp4_seq"] != nil
            || json["mp4_byte"] != nil
            || json["mp4_url"] != nil
            || m == "vid"
            || m == "gif"

        if isVideo {
            // Prefer aagag's own CDN mirror by default. `mp4_seq` is the
            // per-item sequence id aagag stamps once the file is ingested
            // to `i.aagag.com/{q}.mp4`; its absence on an `m == "vid"` /
            // `m == "gif"` payload means the post is an external embed
            // (twitter / discord direct link) that aagag never re-hosted,
            // so `mp4_url` is the only working URL.
            //
            // The "use mirror" branch also catches the malformed-sTag case
            // (no `mp4_seq` AND no `mp4_url`) — the q-based URL probably
            // 404s, but emitting the block is better than dropping it.
            //
            // Older posts ship `mp4_url` pointing at gfycat
            // (`giant.gfycat.com/*.mp4`, `thumbs.gfycat.com/*-mobile.mp4`)
            // which has been dead since Snap shut gfycat down in Sep 2023;
            // those payloads always carry `mp4_seq` and the mirror branch
            // recovers them.
            let videoURLString: String
            if json["mp4_seq"] == nil, let mp4 = json["mp4_url"] as? String {
                videoURLString = absolutize(mp4)
            } else {
                videoURLString = "https://i.aagag.com/\(q).mp4"
            }
            if let url = URL(string: videoURLString) {
                return .video(url)
            }
            return nil
        }

        let imageURLString: String = (json["url"] as? String).map { absolutize($0) }
            ?? "https://i.aagag.com/o/\(q).jpg"
        guard let url = URL(string: imageURLString) else { return nil }
        return .image(url)
    }

    nonisolated private func absolutize(_ s: String) -> String {
        if s.hasPrefix("//") { return "https:\(s)" }
        return s
    }
}
