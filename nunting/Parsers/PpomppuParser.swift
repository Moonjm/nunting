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

        // ppomppu 모바일 리스트는 긴 제목을 리터럴 "…" 로 잘라 내보내, 그 잘린
        // 제목이 detail 헤더까지 그대로 따라온다. detail 페이지의 og:title 은
        // 항상 전체 제목(모바일/데스크톱 공통)이라 이를 헤더용 fullTitle 로 올린다.
        let fullTitle = try doc.select("meta[property=og:title]").first()
            .map { try ParserText.cleanTitle($0.attr("content")) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // Comments are deferred to fetchAllComments so multi-page (`c_page`) threads work.
        return PostDetail(
            post: post,
            blocks: blocks,
            fullDateText: fullDateText,
            viewCount: viewCount,
            source: nil,
            comments: [],
            fullTitle: fullTitle
        )
    }

    public nonisolated func commentsURL(for post: Post) -> URL? {
        // Non-nil so PostDetailLoader triggers the comment leg; the actual
        // JSON endpoint URL is built in `fetchAllComments`.
        post.url
    }

    /// Ppomppu moved comments out of the server-rendered detail DOM into a
    /// per-page JSON endpoint (`ajax_bbs_comment.php?cmd=get_comment_json`).
    /// The old `div.cmAr div.sect-cmt` markup is gone from the detail page —
    /// `#cmAr` now ships empty and the browser fills it via XHR — so the
    /// former HTML scraper returned nothing. `detailHTML` is unused: the
    /// JSON endpoint is independent of the detail body (and, unlike that
    /// CP949 page, it returns UTF-8 — see `responseEncoding(for:)`).
    public nonisolated func fetchAllComments(
        for post: Post,
        detailHTML _: String?,
        fetcher: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [PostComment] {
        guard let id = queryValue(in: post.url, name: "id"),
              let no = queryValue(in: post.url, name: "no"),
              let firstURL = commentJSONURL(id: id, no: no, page: 1)
        else { return [] }

        let first = try parseCommentPage(try await fetcher(firstURL))
        guard first.totalPage > 1 else { return first.comments }

        // `comment_mode=sort_asc` makes page 1 the oldest comments and each
        // page ascend chronologically on every board (the default order is
        // board-dependent — ppomppu descends, pmarket ascends), so a plain
        // 1...total concat is already chronological. Parallel fetch + per-page
        // failure absorption skeleton lives in `mergeCommentPages`.
        return try await mergeCommentPages(
            total: first.totalPage, inlinePage: 1, inline: first.comments
        ) { page in
            guard let pageURL = self.commentJSONURL(id: id, no: no, page: page) else { return [] }
            return try self.parseCommentPage(try await fetcher(pageURL)).comments
        }
    }

    public nonisolated func parseComments(html json: String) throws -> [PostComment] {
        try parseCommentPage(json).comments
    }

    /// Ppomppu comment JSON is UTF-8 while its HTML pages are CP949, so the
    /// detail-fetching fetcher (bound to `site.encoding`) must decode this
    /// endpoint as UTF-8 instead. `PostDetailLoader` asks the parser per URL.
    public nonisolated func responseEncoding(for url: URL) -> String.Encoding {
        url.lastPathComponent == "ajax_bbs_comment.php" ? .utf8 : site.encoding
    }

    /// Decode one `get_comment_json` page into comments + page count. Internal
    /// (not private) so the empty-thread / mapping contract is unit-testable
    /// without a live fetch — a 0-comment post returns `{"comments":[],
    /// "total_page":0,…}`, which must yield `([], 1)` rather than throw (a
    /// throw here surfaces as a false "댓글 로드 실패" banner on a loaded thread).
    nonisolated func parseCommentPage(_ json: String) throws -> (comments: [PostComment], totalPage: Int) {
        let resp = try JSONDecoder().decode(CommentResponse.self, from: Data(json.utf8))
        var flattened: [PostComment] = []
        for raw in resp.comments { appendComment(raw, into: &flattened) }
        return (flattened, max(1, resp.totalPage))
    }

    /// Ppomppu nests replies (and replies-to-replies) inside each comment's
    /// `sub_cmt` array rather than the flat `comments` list — with `depth`
    /// growing per level. Emit each comment pre-order (parent, then its reply
    /// subtree) so threaded order is preserved and the row's `isReply` indent
    /// reflects `depth>0`. Without this recursion every reply is dropped:
    /// a 127-comment thread surfaced only its 82 top-level comments.
    nonisolated private func appendComment(_ raw: CommentResponse.RawComment, into out: inout [PostComment]) {
        if let mapped = mapComment(raw) { out.append(mapped) }
        // Recurse even when the parent maps to nil (genuinely empty row) so a
        // deleted/blank parent doesn't swallow its still-visible replies.
        for reply in raw.subCmt { appendComment(reply, into: &out) }
    }

    nonisolated func commentJSONURL(id: String, no: String, page: Int) -> URL? {
        guard var comps = URLComponents(url: site.baseURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.path = "/new/bbs_view/ajax_bbs_comment.php"
        comps.queryItems = [
            URLQueryItem(name: "cmd", value: "get_comment_json"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "no", value: no),
            URLQueryItem(name: "c_page", value: "\(page)"),
            URLQueryItem(name: "comment_mode", value: "sort_asc"),
        ]
        return comps.url
    }

    nonisolated private func mapComment(_ raw: CommentResponse.RawComment) -> PostComment? {
        let author = authorName(fromNameHTML: raw.name)
        let (content, stickerURL, videoURL) = renderMemo(raw.memo)
        // Keep author-only comments — drop only the genuinely empty row
        // (no content, no sticker, no video, no nickname).
        guard !content.isEmpty || stickerURL != nil || videoURL != nil || !author.isEmpty else { return nil }
        return PostComment(
            id: "\(site.rawValue)-c-\(raw.no)",
            author: author,
            dateText: raw.meta?.timeDisplay ?? "",
            content: content,
            likeCount: raw.voteBtn?.voteCount ?? 0,
            isReply: raw.depth > 0,
            stickerURL: stickerURL,
            videoURL: videoURL,
            authIconURL: nil,
            levelIconURL: nil
        )
    }

    /// `name` is an HTML fragment (`<b><a><i class="nlevel lvN"></i>닉네임</a></b>`);
    /// drop the level-icon `<i>` and any image, then flatten to the nickname.
    nonisolated private func authorName(fromNameHTML html: String) -> String {
        (try? parsedBodyFragment(html) { doc -> String in
            let body = doc.body() ?? doc
            try body.select("i, img").remove()
            return try body.text().trimmingCharacters(in: .whitespacesAndNewlines)
        }) ?? ""
    }

    /// `memo` is the comment-body HTML fragment (same markup the old `ctx_`
    /// container held), so the existing sticker/video/text extractors apply
    /// unchanged once it's parsed. One parse feeds all three.
    nonisolated private func renderMemo(_ html: String) -> (content: String, sticker: URL?, video: URL?) {
        (try? parsedBodyFragment(html) { doc -> (String, URL?, URL?) in
            let body = doc.body() ?? doc
            let content = try cleanCommentText(from: body)
            let sticker = try extractStickerURL(from: body)
            let video = try extractCommentVideoURL(from: body)
            return (content, sticker, video)
        }) ?? ("", nil, nil)
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
        // 본문 GIF 도 댓글과 같은 lazy-load 패턴(src=placeholder 예 `/images/
        // gif_load.gif`, data-original=실제 CDN URL)을 써서 속성 우선순위·skip
        // 마커를 댓글과 동일하게 맞춘다. 공용 BoardParser.imageURL 로 위임.
        imageURL(from: element,
                 attributes: ["data-original", "data-src", "src"],
                 skipMarkers: ["lazyloading", "/images/gif_load"])
            .map(Self.strippingMobileVariantPrefix)
    }

    /// 모바일 본문 마크업은 업로드 이미지를 `m_` 접두사 600px 폭 변형으로
    /// 내려준다(`…/data3/2026/0712/m_20260712101248_….png`, 실측 600×815).
    /// 원본은 접두사 없는 경로에 있고(실측 960×1305; 사이트 자체 PpomImgViewer
    /// onclick 이 항상 접두사 없는 파일명을 참조하므로 존재가 보장), 600px 이하
    /// 원본은 두 경로가 바이트 동일이라 blind strip 이 안전하다. 파일명이
    /// `m_{14자리 타임스탬프}_` 기계 생성 패턴일 때만 벗겨 사용자 파일명
    /// (`m_photo.jpg` 류) 오탐을 막는다. 댓글 첨부는 별도 `_550w` 변형
    /// (`strippingCommentWidthVariant`)을 쓰므로 여긴 본문 전용. 유닛 테스트용
    /// internal.
    nonisolated static func strippingMobileVariantPrefix(_ url: URL) -> URL {
        guard url.path.contains("/zboard/data3/") else { return url }
        let last = url.lastPathComponent
        guard last.range(of: #"^m_\d{14}_"#, options: .regularExpression) != nil,
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var path = comps.path
        guard path.hasSuffix(last) else { return url }
        path.removeLast(last.count)
        comps.path = path + last.dropFirst(2)
        return comps.url ?? url
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
        imageURL(from: el,
                 attributes: ["data-original", "data-src", "src"],
                 skipMarkers: ["lazyloading", "/images/gif_load"])
            .map(Self.strippingCommentWidthVariant)
    }

    /// Ppomppu serves comment photos as a `_550w`-suffixed width variant
    /// (`…/comment/16/ppomppu_15633116_550w`, 690px wide) while the original
    /// lives at the suffix-less path (measured 7/7: 958–1200px). The markup
    /// never links the original, so strip the `_<width>w` suffix here — the
    /// fullscreen viewer then decodes full resolution instead of the 690px
    /// thumbnail. Scoped to `/zboard/data3/comment/` paths, whose filenames
    /// are machine-generated (`{board}_{cmtno}`), so a trailing `_\d+w` can
    /// only be the variant marker. Query (cache-buster `?v=`) is preserved.
    /// Internal for the unit test.
    nonisolated static func strippingCommentWidthVariant(_ url: URL) -> URL {
        guard url.path.contains("/zboard/data3/comment/") else { return url }
        let last = url.lastPathComponent
        guard let range = last.range(of: #"_\d+w$"#, options: .regularExpression)
        else { return url }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var path = comps.path
        guard path.hasSuffix(last) else { return url }
        path.removeLast(last.count)
        comps.path = path + last[..<range.lowerBound]
        return comps.url ?? url
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
}

// MARK: - Comment JSON envelope

/// `ajax_bbs_comment.php?cmd=get_comment_json` response. Decoded defensively
/// so neither a 0-comment post (`{"comments":[],"total_page":0,…}`) nor a
/// single malformed comment surfaces as a false "댓글 로드 실패" banner:
/// missing keys default, and each comment decodes through `Failable` so one
/// unparseable row is dropped instead of failing the whole page.
nonisolated private struct CommentResponse: Decodable {
    let comments: [RawComment]
    let totalPage: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        comments = (try c.decodeIfPresent([Failable<RawComment>].self, forKey: .comments) ?? [])
            .compactMap(\.value)
        totalPage = try c.decodeIfPresent(Int.self, forKey: .totalPage) ?? 1
    }

    enum CodingKeys: String, CodingKey {
        case comments
        case totalPage = "total_page"
    }

    /// Wrapper that turns a per-element decode failure into `nil` rather than
    /// aborting the enclosing array — used for both the top-level `comments`
    /// list and each nested `sub_cmt` list so a lone bad row never nukes the
    /// page (or a reply subtree).
    struct Failable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    struct RawComment: Decodable {
        let no: Int
        let depth: Int
        let name: String            // author HTML fragment
        let memo: String            // comment-body HTML fragment
        let meta: Meta?
        let voteBtn: VoteBtn?
        let subCmt: [RawComment]    // nested replies (recursive, `depth`-tagged)

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // `no` is the identity — accept Int or numeric String; a truly
            // absent/garbage id makes the row undroppable-by-id, so fail (the
            // `Failable` wrapper then drops just this row, not the page).
            if let i = try? c.decode(Int.self, forKey: .no) {
                no = i
            } else if let s = try? c.decode(String.self, forKey: .no), let i = Int(s) {
                no = i
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .no, in: c, debugDescription: "comment `no` missing/non-numeric")
            }
            depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 0
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            memo = try c.decodeIfPresent(String.self, forKey: .memo) ?? ""
            meta = try? c.decodeIfPresent(Meta.self, forKey: .meta)
            voteBtn = try? c.decodeIfPresent(VoteBtn.self, forKey: .voteBtn)
            // `sub_cmt` is `null` on leaf comments and an array on threaded
            // ones; `try?` also absorbs any unexpected scalar shape.
            subCmt = ((try? c.decodeIfPresent([Failable<RawComment>].self, forKey: .subCmt)) ?? nil)?
                .compactMap(\.value) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case no, depth, name, memo, meta
            case voteBtn = "vote_btn"
            case subCmt = "sub_cmt"
        }
    }

    struct Meta: Decodable {
        let timeDisplay: String?
        enum CodingKeys: String, CodingKey { case timeDisplay = "time_display" }
    }

    struct VoteBtn: Decodable {
        let voteCount: Int?
        enum CodingKeys: String, CodingKey { case voteCount = "vote_count" }
    }
}
