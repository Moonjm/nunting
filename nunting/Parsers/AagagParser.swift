import Foundation
import SwiftSoup

struct AagagParser: BoardParser {
    let site: Site = .aagag

    private static let imageHost = "https://i.aagag.com"
    // YouTube IDs are exactly 11 chars from [A-Za-z0-9_-].
    private static let youtubeIDRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]{11}$"#)
    // Instagram shortcodes are 5+ chars from [A-Za-z0-9_-].
    private static let instaIDRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_-]+$"#)

    func parseList(html: String, board: Board) throws -> [Post] {
        let doc = try SwiftSoup.parse(html)
        // Restrict to actual data tables (`table.aalist` minus the `.header` and minus
        // sidebar `div.aalist.layer` previews/sliders).
        let articles = try doc.select("table.aalist:not(.header) a.article")

        var seen = Set<String>()
        var results: [Post] = []
        for el in articles {
            let href = try el.attr("href")
            guard !href.isEmpty,
                  let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL,
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
            let title = try titleCopy?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)
        let titleEl = try doc.select("h1.title").first()
        let title = try titleEl?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? post.title

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

    private func findContentScript(in doc: Document) throws -> String? {
        // Anchor on `AAGAG_AA.content =` (with the equals sign and optional whitespace)
        // so we don't false-match other property reads like `AAGAG_AA.contentLength`.
        let anchorRegex = try NSRegularExpression(pattern: #"AAGAG_AA\.content\s*=\s*""#)
        for script in try doc.select("script") {
            let text = script.data()
            let nsText = text as NSString
            let match = anchorRegex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length))
            guard let match else { continue }
            let bodyStart = text.index(text.startIndex, offsetBy: match.range.location + match.range.length)
            let body = text[bodyStart...]

            // Walk character-by-character, locating the unescaped closing quote.
            // A quote is a real terminator iff the run of immediately preceding
            // backslashes has even length (each `\\` is itself an escape pair).
            var idx = body.startIndex
            while idx < body.endIndex {
                if body[idx] == "\"" {
                    var backslashes = 0
                    var look = idx
                    while look > body.startIndex {
                        look = body.index(before: look)
                        if body[look] == "\\" { backslashes += 1 } else { break }
                    }
                    if backslashes % 2 == 0 {
                        return Self.unescapeJSString(String(body[..<idx]))
                    }
                }
                idx = body.index(after: idx)
            }
        }
        return nil
    }

    private static func unescapeJSString(_ s: String) -> String {
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
    private func blocksFromContentString(_ content: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        let openTag = "[sTag]"
        let closeTag = "[/sTag]"
        var cursor = content.startIndex

        // Strip surrounding HTML using SwiftSoup as a quick text extractor for non-sTag chunks.
        func appendText(_ raw: String) {
            let stripped = stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return }
            blocks.append(.text(stripped))
        }

        while let openRange = content.range(of: openTag, range: cursor..<content.endIndex) {
            if openRange.lowerBound > cursor {
                appendText(String(content[cursor..<openRange.lowerBound]))
            }
            guard let closeRange = content.range(of: closeTag, range: openRange.upperBound..<content.endIndex) else {
                break
            }
            let payload = String(content[openRange.upperBound..<closeRange.lowerBound])
            if let block = stagBlock(from: payload) {
                blocks.append(block)
            }
            cursor = closeRange.upperBound
        }
        if cursor < content.endIndex {
            appendText(String(content[cursor...]))
        }
        return blocks
    }

    private func stripHTML(_ s: String) -> String {
        guard let doc = try? SwiftSoup.parseBodyFragment(s) else { return s }
        return (try? doc.body()?.text()) ?? s
    }

    func commentsURL(for post: Post) -> URL? {
        guard issueIdx(from: post) != nil else { return nil }
        return URL(string: "https://aagag.com/api/cmt")
    }

    func fetchAllComments(for post: Post, fetcher: @escaping @Sendable (URL) async throws -> String) async throws -> [Comment] {
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
            Comment(
                id: "\(site.rawValue)-c-\(raw.w_idx)",
                author: raw.w_nick,
                dateText: raw.stime,
                content: stripCommentHTML(raw.w_content),
                likeCount: raw.w_good,
                isReply: (raw.w_cmt_reply ?? "").isEmpty == false,
                stickerURL: nil,
                authIconURL: nil,
                levelIconURL: nil
            )
        }
    }

    private func stripCommentHTML(_ raw: String) -> String {
        guard let doc = try? SwiftSoup.parseBodyFragment(raw),
              let body = doc.body()
        else { return raw }

        // Replace <br> with literal newlines via SwiftSoup's text()-collapse-resistant marker.
        let blockMarker = "\u{0001}NL\u{0001}"
        if let blocks = try? body.select("br, p, div, li, blockquote") {
            for el in blocks where el.parent() != nil {
                try? el.before(blockMarker)
            }
        }
        let text = (try? body.text()) ?? raw
        var result = text.replacingOccurrences(of: blockMarker, with: "\n")
        result = result.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func issueIdx(from post: Post) -> String? {
        URLComponents(url: post.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "idx" })?
            .value
    }

    private struct AagagCommentResponse: Decodable {
        let mode: String
        let comment: [AagagComment]
    }

    private struct AagagComment: Decodable {
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
    private func stagBlock(from payload: String) -> ContentBlock? {
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
            let videoURLString: String = (json["mp4_url"] as? String).map { absolutize($0) }
                ?? "https://i.aagag.com/\(q).mp4"
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

    private func absolutize(_ s: String) -> String {
        if s.hasPrefix("//") { return "https:\(s)" }
        return s
    }
}
