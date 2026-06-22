import Foundation
import SwiftSoup

public struct PpomppuParser: BoardParser {
    public let site: Site = .ppomppu

    public nonisolated init() {}

    public nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        let doc = try SwiftSoup.parse(html)
        let boardID = ppomppuBoardID(from: board)

        var rows = try doc.select("ul.bbsList_new > li").array()
        if rows.isEmpty {
            rows = try doc.select("ul.bbsList > li").array()
        }

        return try rows.compactMap { row -> Post? in
            // Skip pinned-by-popularity rows that break chronological order.
            let rowClasses = (try? row.attr("class")) ?? ""
            let rowTokens = rowClasses.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if rowTokens.contains("hotpop_bg_color") { return nil }

            guard let link = try row.select("a[href*=bbs_view.php]").first() else { return nil }
            let href = try link.attr("href")
            guard let url = resolveHTTPURL(href) else { return nil }

            // Skip sponsored / cross-board entries (e.g. id=sponsor at top of freeboard).
            if let postBoardID = queryValue(in: url, name: "id"), postBoardID != boardID {
                return nil
            }

            let titleEl = try row.select("li.title span.cont").first()
                ?? row.select("strong").first()
            guard let titleEl else { return nil }

            let titleCopy = titleEl.copy() as? Element ?? titleEl
            try titleCopy.select("img, span.rp, sup, .baseList-img").remove()
            let title = ParserText.cleanTitle(try titleCopy.text())
            guard !title.isEmpty else { return nil }

            let commentText = try row.select("span.rp").first()?.text() ?? ""
            let commentCount = ParserText.integerFromDigits(in: commentText) ?? 0

            let dateText = try row.select("time").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let viewText = try row.select(".view, span.view").first()?.text() ?? ""
            let viewCount = ParserText.integerFromDigits(in: viewText)

            let recoEl = try row.select("span.recs.blue, span.rec.blue").first()
            let recoText = try recoEl?.text() ?? ""
            let recommendCount = ParserText.integerFromDigits(in: recoText)

            let namesText = try row.select("li.names, span.names").first()?.text() ?? ""
            let (category, author) = splitCategoryAuthor(namesText)

            let postNo = queryValue(in: url, name: "no")
                ?? url.pathComponents.last
                ?? url.absoluteString
            let cleanURL = strippingPageQuery(url)

            return Post(
                id: "\(board.id)-\(postNo)",
                site: site,
                boardID: board.id,
                title: title,
                author: author,
                date: nil,
                dateText: dateText,
                commentCount: commentCount,
                url: cleanURL,
                viewCount: viewCount,
                recommendCount: recommendCount,
                levelText: category,
                hasAuthIcon: false
            )
        }
    }

    public nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)
        guard let view = try doc.select("div.bbs.view, div.bbs_view, div.view").first() else {
            throw ParserError.structureChanged("bbs.view 없음")
        }

        guard let content = try view.select("div.cont#KH_Content, div#KH_Content, div.cont").first() else {
            throw ParserError.structureChanged("KH_Content 없음")
        }

        let dealAnchor = try dealAnchor(from: view)
        var blocks: [ContentBlock] = []
        if let dealAnchor {
            blocks.append(.dealLink(dealAnchor.url, label: dealAnchor.label))
        }
        let skipURL = dealAnchor?.url
        var rules = WalkerRules.standard(for: self)
        rules.resolveImageURL  = imageURL(from:)
        rules.imageBlock       = imageOrVideoBlock(for:aspect:)
        rules.shouldEmitAnchor = { url in url != skipURL }
        let body = try ParserBlockWalker(parser: self, rules: rules).walk(content)
        blocks.append(contentsOf: body)

        let header = try view.select("h4").first()
        let fullDateText = try header?.select("span.hi").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let viewCount: Int? = try {
            guard let header else { return nil }
            let headerText = try header.text()
            // Header text contains "조회 : 15016" followed by other h4 text
            // (date span), so stop at the first run — not all digits.
            guard let range = headerText.range(of: "조회") else { return nil }
            return ParserText.firstInteger(in: String(headerText[range.upperBound...]))
        }()

        // Comments are deferred to fetchAllComments so multi-page (`c_page`) threads work.
        return PostDetail(
            post: post,
            blocks: blocks,
            fullDateText: fullDateText,
            viewCount: viewCount,
            source: nil,
            comments: []
        )
    }

    public nonisolated func commentsURL(for post: Post) -> URL? {
        // Comments are embedded in the detail page; pagination uses ?c_page=N on the same URL.
        post.url
    }

    public nonisolated func fetchAllComments(
        for post: Post,
        detailHTML: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [PostComment] {
        // Reuse the detail HTML the caller already fetched for
        // `parseDetail` — Ppomppu's first-page comments live inside the
        // detail DOM, so re-fetching `post.url` here only duplicates
        // parse work.
        let firstHtml: String
        if let detailHTML {
            firstHtml = detailHTML
        } else {
            firstHtml = try await fetcher(post.url)
        }
        let (info, firstPage) = try parsedDocument(firstHtml) { firstDoc -> ((current: Int, total: Int), [PostComment]) in
            let info = try commentPageInfo(in: firstDoc)
            let firstPage = try parseComments(in: firstDoc, fallbackPage: info.current)
            return (info, firstPage)
        }
        if info.total <= 1 { return firstPage }

        // 모바일 detail 은 댓글 **마지막** 페이지를 inline 으로 렌더한다(page 1
        // 아님). 그 댓글을 무조건 page 1 로 놓으면 `current` 페이지가 중복되고
        // 빠진 페이지(특히 1번)가 누락된다 — "스크롤하면 같은 댓글이 다시 나옴"
        // 의 원인. detail 댓글을 실제 인덱스(info.current)에 놓고 나머지 페이지만
        // 가져온다. 병렬 fetch + 실패 흡수 골격은 `mergeCommentPages` 참조.
        return try await mergeCommentPages(
            total: info.total, inlinePage: info.current, inline: firstPage
        ) { page in
            guard let pageURL = self.appendingCommentPage(to: post.url, page: page) else { return [] }
            let html = try await fetcher(pageURL)
            return try self.parsedDocument(html) { pageDoc in
                try self.parseComments(in: pageDoc, fallbackPage: page)
            }
        }
    }

    public nonisolated func parseComments(html: String) throws -> [PostComment] {
        try parsedDocument(html) { doc in
            try parseComments(in: doc, fallbackPage: 1)
        }
    }

    /// `fallbackPage` 는 id 없는 댓글의 synthetic id 에 섞어 페이지 간 충돌을
    /// 막는다 — 페이지마다 `results.count` 가 0 부터 다시 시작하므로, page 를
    /// 안 섞으면 서로 다른 페이지의 id 없는 두 댓글이 같은 id 를 받아 SwiftUI
    /// ForEach 키가 충돌한다(멀티페이지 병합 후 발생).
    nonisolated private func parseComments(in doc: Document, fallbackPage: Int) throws -> [PostComment] {
        let nodes = try doc.select("div.cmAr div[class*=sect-cmt]")
        var results: [PostComment] = []
        for node in nodes {
            // Ignore nested wrappers if any: only take elements whose own class includes sect-cmt.
            let classAttr = (try? node.attr("class")) ?? ""
            let classTokens = classAttr.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard classTokens.contains("sect-cmt") else { continue }

            let depthAttr = try node.attr("data-depth")
            let isReply = (Int(depthAttr) ?? 0) > 0

            // PostComment ID lives on the preceding anchor, or inside ctx_{id}.
            // Fallback uses the result index so identity stays stable across re-parses
            // (avoids SwiftUI ForEach churn).
            let cmtID: String = try {
                if let anchor = try node.previousElementSibling(),
                   anchor.tagName().lowercased() == "a" {
                    let id = try anchor.attr("id")
                    if !id.isEmpty { return id }
                }
                if let ctx = try node.select("[id^=ctx_]").first() {
                    let raw = try ctx.attr("id")
                    return String(raw.dropFirst(4))
                }
                return "fallback-p\(fallbackPage)-\(results.count)"
            }()

            let writerEl = try node.select("h6.com_name span.com_name_writer").first()
            let writerCopy = writerEl.flatMap { $0.copy() as? Element } ?? writerEl
            try writerCopy?.select("i, span, img").remove()
            let author = try writerCopy?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let levelClass = try node.select("h6.com_name i.nlevel").first()
                .flatMap { try? $0.classNames() }
                .flatMap { $0.first(where: { $0.hasPrefix("lv") }) }
            let levelIconURL = Self.levelIconURL(level: levelClass)

            let likeText = try node.select("[id^=vote_cnt_]").first()?.text() ?? "0"
            let likeCount = ParserText.integerFromDigits(in: likeText) ?? 0

            let dateText = try node.select("div.cin_02 time").first()?.text()
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let contentEl = try node.select("[id^=ctx_]").first()
            let content = try contentEl.map { try cleanCommentText(from: $0) } ?? ""
            let stickerURL = try contentEl.flatMap { try extractStickerURL(from: $0) }
            let videoURL = try contentEl.flatMap { try extractCommentVideoURL(from: $0) }

            guard !content.isEmpty || stickerURL != nil || videoURL != nil else { continue }

            results.append(PostComment(
                id: "\(site.rawValue)-c-\(cmtID)",
                author: author,
                dateText: dateText,
                content: content,
                likeCount: likeCount,
                isReply: isReply,
                stickerURL: stickerURL,
                videoURL: videoURL,
                authIconURL: nil,
                levelIconURL: levelIconURL
            ))
        }
        return results
    }

    /// 댓글 페이지 정보 "current / total". 모바일 detail 은 **마지막** 댓글
    /// 페이지를 inline 으로 렌더하므로(예 "3 / 3"), total 뿐 아니라 current 도
    /// 읽어야 detail 댓글을 올바른 페이지 슬롯에 놓을 수 있다. current 를
    /// 1...total 로 clamp. 못 읽으면 (1, 1).
    nonisolated private func commentPageInfo(in doc: Document) throws -> (current: Int, total: Int) {
        guard let pageEl = try doc.select("div.cmt-topInfo span.cmt-page").first() else { return (1, 1) }
        let text = try pageEl.text()
        // Format: "3 / 3" (prevPage/nextPage 앵커는 텍스트 없음).
        let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let current = ParserText.integerFromDigits(in: parts[0]),
              let total = ParserText.integerFromDigits(in: parts[1]), total >= 1
        else { return (1, 1) }
        return (min(max(1, current), total), total)
    }

    nonisolated private func appendingCommentPage(to url: URL, page: Int) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (comps.queryItems ?? []).filter { $0.name != "c_page" }
        items.append(URLQueryItem(name: "c_page", value: "\(page)"))
        comps.queryItems = items
        return comps.url
    }

    /// Ppomppu wraps user-uploaded video files in `<img src="...mov">` /
    /// `<img src="...mp4">` tags and relies on a desktop-only JS shim to
    /// swap the element to a `<video>` player at runtime. The mobile site
    /// (`m.ppomppu`) skips that swap entirely, so the raw `<img>` ships
    /// pointing at video bytes that no `<img>` decoder can render — Safari
    /// shows nothing, and our `CachedAsyncImage` decode returns nil and
    /// flips to "다시 시도". When the parsed `<img src>` actually points at
    /// a video container, route it to the inline video player instead.
    /// Sample post: `m.ppomppu.co.kr/new/bbs_view.php?id=car&no=968820`
    /// (an `IMG_*.mov` from iOS Photos) — desktop renders, mobile didn't.
    nonisolated private static let videoPathExtensions: Set<String> = [
        "mov", "mp4", "m4v", "webm",
    ]

    nonisolated private func imageOrVideoBlock(for url: URL, aspect: CGFloat?) -> ContentBlock {
        let ext = url.pathExtension.lowercased()
        if Self.videoPathExtensions.contains(ext) {
            return .video(url, posterURL: nil)
        }
        return .image(url, aspectRatio: aspect)
    }

    nonisolated private func imageURL(from element: Element) throws -> URL? {
        // Match the comment-image attribute priority so body GIFs that use
        // the same lazy-loading pattern as comments (src = placeholder like
        // `/images/gif_load.gif`, `data-original` = real CDN URL) aren't
        // silently rendered as the placeholder or dropped.
        let candidates = [
            try element.attr("data-original"),
            try element.attr("data-src"),
            try element.attr("src"),
        ]
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains("lazyloading"),
                  !trimmed.contains("/images/gif_load"),
                  let url = resolveHTTPURL(trimmed)
            else { continue }
            return url
        }
        return nil
    }

    nonisolated private func dealAnchor(from view: Element) throws -> (url: URL, label: String)? {
        // Affiliate-enabled posts wrap the header link:
        //   Mobile:  <div class="link-box"> inside <h4>
        //   Desktop: <li class="topTitle-link partner"> inside <ul class="topTitle-mainbox">
        // Non-affiliate posts drop the wrapper and ship the header link as bare
        // "링크 : <a class='noeffect' href='https://s.ppomppu.co.kr?...'>" text
        // inside <h4>. Without the fallback the deal block silently disappears
        // for any non-affiliate external link.
        // Sample non-affiliate post: m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=705778
        if let el = try view.select("div.link-box a[href], li.topTitle-link a[href]").first() {
            return try anchor(from: el)
        }
        if let el = try view.select("h4 a.noeffect[href*=s.ppomppu.co.kr]").first() {
            return try anchor(from: el)
        }
        return nil
    }


    nonisolated private func extractStickerURL(from element: Element) throws -> URL? {
        // PostComment images are lazy-loaded: src is "/images/lazyloading.jpg"
        // and the real URL lives in data-original. Walk all imgs to find one
        // with a content URL, then fall back to a GIF preview (data-org-src
        // on the <a class="btn_show_org">) for video-only comments.
        for img in try element.select("img") {
            if let url = try commentImageURL(from: img) { return url }
        }
        if let gif = try element.select("a.btn_show_org").first() {
            let href = try gif.attr("data-org-src")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = resolveHTTPURL(href) {
                return url
            }
        }
        return nil
    }

    /// Inline `<video>` attachments inside a Ppomppu comment — the site
    /// wraps uploaded mp4s in `<div class="wrapper_video"><video><source
    /// src="..."></video></div>`. Without this, `cleanCommentText` strips
    /// the `<video>` from the rendered text and nothing surfaces in the UI.
    nonisolated private func extractCommentVideoURL(from element: Element) throws -> URL? {
        guard let vid = try element.select("video").first() else { return nil }
        var src = try vid.attr("src")
        if src.isEmpty, let source = try vid.select("source").first() {
            src = try source.attr("src")
        }
        if src.isEmpty { src = try vid.attr("data-src") }
        // Drop AVPlayer-unfriendly fragment identifiers (`#t=0.05` etc.).
        if let hash = src.firstIndex(of: "#") {
            src = String(src[..<hash])
        }
        guard !src.isEmpty,
              let url = URL(string: src, relativeTo: site.baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    nonisolated private func commentImageURL(from el: Element) throws -> URL? {
        let candidates = [
            try el.attr("data-original"),
            try el.attr("data-src"),
            try el.attr("src"),
        ]
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains("lazyloading"),
                  !trimmed.contains("/images/gif_load")
            else { continue }
            guard let url = URL(string: trimmed, relativeTo: site.baseURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { continue }
            return url
        }
        return nil
    }

    nonisolated private func cleanCommentText(from element: Element) throws -> String {
        let copy = (element.copy() as? Element) ?? element
        // `.scrap_bx_href` / `.scrap_bx` is the OpenGraph link-preview card
        // ppomppu injects when a comment contains an external URL. Web
        // hides the `<small>` description via CSS; flattening the subtree
        // with `.text()` leaks the full article body into the comment.
        // The card is an inline `<a>` wrapping a `<div>`, so the block
        // newline it visually created is lost when we remove the subtree.
        // Stamp the block-marker sentinel in its place so the user's
        // sibling text and the fallback URL keep the line break the DOM
        // implied; the sibling `<a class="noeffect">` already carries the
        // same URL as plain text so the tappable link survives.
        for scrap in try copy.select("a.scrap_bx_href, .scrap_bx") where scrap.parent() != nil {
            _ = try? scrap.before(Self.blockMarker)
        }
        // Remove media elements *and* their decorative siblings so that
        // the <video> fallback string ("Your browser does not support...")
        // and the GIF-expansion button's "원본보기" label don't leak into
        // the comment content.
        try copy.select(
            "img, script, style, video, source, .wrapper_video, a.btn_show_org, a.scrap_bx_href, .scrap_bx"
        ).remove()
        // Preserve remaining anchors as tappable markdown links, stamp block
        // breaks, flatten and normalize (shared BoardParser comment pipeline).
        return renderCommentText(from: copy)
    }

    nonisolated private func splitCategoryAuthor(_ raw: String) -> (category: String?, author: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") else { return (nil, trimmed) }
        guard let close = trimmed.firstIndex(of: "]") else { return (nil, trimmed) }
        let category = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        let rest = trimmed[trimmed.index(after: close)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (category.isEmpty ? nil : category, rest)
    }

    nonisolated private func queryValue(in url: URL, name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    nonisolated private func strippingPageQuery(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.queryItems = comps.queryItems?.filter { $0.name != "page" }
        if comps.queryItems?.isEmpty == true { comps.queryItems = nil }
        return comps.url ?? url
    }

    nonisolated private func ppomppuBoardID(from board: Board) -> String? {
        guard let comps = URLComponents(string: board.path) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "id" })?.value
    }

    nonisolated private static func levelIconURL(level: String?) -> URL? {
        // Ppomppu levels are CSS sprites without standalone image URLs; show plain text instead.
        _ = level
        return nil
    }
}
