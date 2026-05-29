import Foundation
import SwiftSoup
public struct ClienParser: BoardParser {
    public let site: Site = .clien

    /// `YYYY-MM-DD HH:MM(:SS)` — the timestamp Clien renders inside
    /// `div.post_date`. Used to slice out the modified timestamp when an
    /// edited post advertises both 등록일 and 수정일 in the same block.
    nonisolated private static let postDatePattern = #"\d{4}-\d{2}-\d{2}[\sT]\d{2}:\d{2}(?::\d{2})?"#

    public nonisolated init() {}

    public nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        let doc = try SwiftSoup.parse(html)
        let rows = try doc.select("a.list_item.symph-row")

        return try rows.compactMap { row -> Post? in
            // Skip pinned notice rows (jirum's "알리정보" sponsored items
            // appear with class "list_item notice symph-row" containing a
            // `<div class="ad">알리정보</div>` badge — not real posts).
            let classAttr = (try? row.attr("class")) ?? ""
            let classTokens = classAttr.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if classTokens.contains("notice") { return nil }
            if try !row.select("div.ad").isEmpty() { return nil }

            let href = try row.attr("href")
            guard !href.isEmpty,
                  let url = URL(string: href, relativeTo: site.baseURL)?.absoluteURL
            else { return nil }

            let rawTitle = try row.select("span[data-role=list-title-text]").first()?.text()
                ?? row.select("div.list_subject").first()?.text()
                ?? ""
            let title = ParserText.cleanTitle(rawTitle)

            let author = try row.select("div.list_author span.nickname").first()?.text()
                ?? row.attr("data-author-id")

            let dateText = try row.select("div.list_time span").first()?.text() ?? ""

            let commentCount = Int(try row.attr("data-comment-count")) ?? 0
            let boardSN = try row.attr("data-board-sn")
            let postID: String = if !boardSN.isEmpty {
                boardSN
            } else {
                url.pathComponents.last ?? url.path
            }

            return Post(
                id: "\(board.id)-\(postID)",
                site: site,
                boardID: board.id,
                title: title,
                author: author,
                date: nil,
                dateText: dateText,
                commentCount: commentCount,
                url: url
            )
        }
    }

    public nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)
        guard let article = try doc.select("div.post_article").first() else {
            throw ParserError.structureChanged("post_article 없음")
        }

        let (source, skipFirstParagraph) = try extractSource(from: article)

        // Mutates the SwiftSoup document in-place; safe because `doc` is
        // local to this parse and never escapes.
        if skipFirstParagraph, let firstP = article.children().first() {
            try firstP.remove()
        }

        var rules = WalkerRules.standard(for: self)
        // Clien Froala GIF wrapper 끝의 `<button class="search_link">…GIF</button>`
        // 다운로드 chrome 차단 (default skipTags 는 script/style/noscript 만 차단).
        rules.skipTags.insert("button")
        // <img> 는 customElement 로 claim — Clien `image(from:)` 가 srcset
        // 폴백 (Froala 가 src 를 HTML 페이지 URL 로 잘못 채우는 케이스 처리)
        // 과 data-img-width/height aspect ratio 추출을 한다. standard
        // resolveImageURL/imageBlock 으로는 둘 다 표현 불가.
        rules.customElement = { [self] el in
            guard el.tagName().lowercased() == "img" else { return nil }
            guard let info = try image(from: el) else { return [] }
            return [.image(info.url, aspectRatio: info.aspectRatio)]
        }
        let blocks = try ParserBlockWalker(parser: self, rules: rules).walk(article)

        let rawDate = try doc.select("div.post_date").first()?.text() ?? ""
        let fullDateText = collapsePostDate(rawDate)
        let viewCountText = try doc.select("div.view_count").first()?.text() ?? ""
        let viewCount = ParserText.firstInteger(in: viewCountText)

        let comments = try parseComments(doc: doc)

        return PostDetail(
            post: post,
            blocks: blocks,
            fullDateText: fullDateText,
            viewCount: viewCount,
            source: source,
            comments: comments
        )
    }

    /// Clien stuffs the registered date and modified date into the same
    /// `div.post_date` block when an article has been edited (both stamps
    /// appear, separated by a "수정" label). Surface only the modified
    /// stamp in that case so the header reads cleanly; pass through any
    /// other shape (single date, no edit) unchanged after light whitespace
    /// normalization.
    nonisolated private func collapsePostDate(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let keyword = normalized.range(of: "수정"),
           let date = normalized.range(
               of: Self.postDatePattern,
               options: .regularExpression,
               range: keyword.upperBound..<normalized.endIndex
           ) {
            return String(normalized[date])
        }
        return normalized
    }

    nonisolated private func extractSource(from article: Element) throws -> (source: PostSource?, skipFirstParagraph: Bool) {
        guard let firstP = article.children().first(),
              firstP.tagName().lowercased() == "p"
        else { return (nil, false) }

        let paragraphText = try firstP.text()
        guard let pipeRange = paragraphText.range(of: "|", options: .backwards) else {
            return (nil, false)
        }
        let afterPipe = paragraphText[pipeRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !afterPipe.isEmpty else { return (nil, false) }

        guard let anchor = try firstP.select("a").first() else {
            return (nil, false)
        }
        let anchorText = try anchor.text()
        guard let anchorPos = paragraphText.range(of: anchorText),
              anchorPos.lowerBound < pipeRange.lowerBound
        else { return (nil, false) }

        let href = try anchor.attr("href")
        guard let url = resolveHTTPURL(href),
              let host = url.host?.lowercased(),
              !host.hasSuffix(".clien.net"),
              host != "clien.net"
        else { return (nil, false) }

        return (PostSource(name: afterPipe, url: url), true)
    }

    nonisolated private func image(from element: Element) throws -> (url: URL, aspectRatio: CGFloat?)? {
        let rawSrc = try element.attr("src")
        let srcset = try element.attr("srcset")

        // Some Clien posts paste WordPress/Froala markup where the editor
        // rewrote `src` to the *article's* HTML page URL (e.g.
        // `https://www.carscoops.com/2026/04/foo-bar/`) while the real image
        // URLs survived in `srcset`. Loading the HTML page as an image fails
        // decode and the slot stays on the broken placeholder. When `src`
        // doesn't look like an image URL, fall back to the best `srcset`
        // entry so the post actually renders.
        let chosenString: String
        if !rawSrc.isEmpty,
           let rawURL = URL(string: rawSrc, relativeTo: site.baseURL)?.absoluteURL,
           looksLikeImageURL(rawURL) {
            chosenString = rawSrc
        } else if let best = bestSrcsetURL(srcset) {
            chosenString = best
        } else {
            chosenString = rawSrc
        }

        guard !chosenString.isEmpty,
              let url = URL(string: chosenString, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        let width = CGFloat(Double(try element.attr("data-img-width")) ?? 0)
        let height = CGFloat(Double(try element.attr("data-img-height")) ?? 0)
        let aspectRatio = width > 0 && height > 0 ? width / height : nil
        return (url, aspectRatio)
    }

    nonisolated private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "heic", "heif", "avif",
    ]

    nonisolated private func looksLikeImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && Self.imageExtensions.contains(ext)
    }

    /// Parse an HTML `srcset` attribute and pick a URL appropriate for a
    /// phone column. Prefers the smallest entry ≥ 1024w (the WordPress
    /// mobile-friendly size), falling back to the largest entry when every
    /// candidate is below that threshold.
    nonisolated private func bestSrcsetURL(_ srcset: String) -> String? {
        guard !srcset.isEmpty else { return nil }
        var candidates: [(url: String, width: Int)] = []
        for raw in srcset.split(separator: ",") {
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = entry.split(whereSeparator: { $0.isWhitespace })
            guard let first = parts.first else { continue }
            let urlText = String(first)
            if urlText.isEmpty { continue }
            var width = 0
            if parts.count >= 2, parts[1].hasSuffix("w") {
                width = Int(parts[1].dropLast()) ?? 0
            }
            candidates.append((urlText, width))
        }
        guard !candidates.isEmpty else { return nil }
        let sorted = candidates.sorted { $0.width < $1.width }
        if let pick = sorted.first(where: { $0.width >= 1024 }) {
            return pick.url
        }
        return sorted.last?.url
    }

    nonisolated private func parseComments(doc: Document) throws -> [PostComment] {
        let rows = try doc.select("div.comment_row[data-role=comment-row]")
        var results: [PostComment] = []

        for row in rows {
            let sn = try row.attr("data-comment-sn").trimmingCharacters(in: .whitespaces)
            let authorID = try row.attr("data-author-id")

            let nicknameText = try row.select("span.nickname").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let nickImgAlt = try row.select("span.nickimg img").first()?.attr("alt")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let author = !nicknameText.isEmpty ? nicknameText
                : !nickImgAlt.isEmpty ? nickImgAlt
                : authorID

            let dateText = try row.select("span.timestamp").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard let viewEl = try row.select("div.comment_view").first(),
                  let copy = viewEl.copy() as? Element
            else { continue }
            try copy.select("input").remove()
            // Preserve anchors as tappable markdown links before `.text()`
            // flattens the subtree and drops their hrefs. Done on a copy
            // so later reads of the original `doc` aren't corrupted —
            // matches the pattern every other parser in this patch uses.
            convertAnchorsToMarkdown(in: copy)
            let content = try copy.text().trimmingCharacters(in: .whitespacesAndNewlines)

            // Comment-level image attachments live in a sibling
            // `div.comment-img` *outside* `comment_view`, so the text
            // walk above misses them entirely. Pull the first
            // attach-image directly off the row — that's the same
            // marker Clien's own renderer uses to distinguish a real
            // upload from inline emoji or quoted-post thumbnails.
            // Without this, image-only comments were silently dropped
            // by the `content.isEmpty` guard below and text-with-image
            // comments rendered the caption alone.
            //
            // Routed through `resolveHTTPURL` so the same trim +
            // scheme allow-list (`http(s)` only) the body image and
            // video paths use applies here too — keeps a future
            // Clien markup change that inlined a `data:` or
            // whitespace-padded src from leaking past the parser.
            let attachedImage: URL? = {
                guard let img = try? row.select("img[data-role=attach-image]").first(),
                      let src = try? img.attr("src")
                else { return nil }
                return resolveHTTPURL(src)
            }()

            // Allow image-only comments through. The guard now drops
            // the row only when there's neither a caption nor an
            // attachment, which is the genuine empty case (deleted
            // content placeholder) we still want to skip.
            guard !content.isEmpty || attachedImage != nil else { continue }

            let likeText = try row.select("strong[id^=setLikeCount_]").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            let likeCount = Int(likeText) ?? 0

            let isReply = try row.classNames().contains { $0.lowercased().contains("re") && $0.lowercased() != "comment_row" }

            let commentID: String = sn.isEmpty
                ? "\(site.rawValue)-c-\(results.count)"
                : "\(site.rawValue)-c-\(sn)"

            results.append(PostComment(
                id: commentID,
                author: author,
                dateText: dateText,
                content: content,
                likeCount: likeCount,
                isReply: isReply,
                stickerURL: attachedImage
            ))
        }
        return results
    }
}
