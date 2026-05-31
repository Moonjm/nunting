import Foundation
import SwiftSoup
/// Parses humoruniv (웃대) mobile detail pages. Reached exclusively via aagag
/// mirror redirects — humoruniv is not exposed as a directly-browsable site.
public struct HumorParser: BoardParser {
    public let site: Site = .humor

    public nonisolated init() {}

    nonisolated private static let mp4ExpandRegex = try! NSRegularExpression(
        pattern: #"comment_mp4_expand\s*\(\s*'[^']*'\s*,\s*'([^']+)'"#,
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

    public nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        // Humoruniv is aagag-dispatch-only; list parsing is never invoked.
        []
    }

    public nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)

        // 너굴맨(안심맨) 디코이 영역을 본문/댓글 양쪽에서 한 번에 정리.
        // 마크업 형태가 동일하므로(`<div id="racy_show_X">` 디코이 + 형제
        // `<div id="racy_hidden_X">` 실 이미지) doc 레벨에서 한 번에 떼면
        // extractBlocks/extractComments 모두 자동으로 깨끗한 트리를 받음.
        // racy_hidden_* 안의 "원본" 펼치기 버튼도 같은 이유로 함께 제거.
        try doc.select("[id^=racy_show_], [id^=btn_nemo_expand_all]").remove()
        // racy_hidden_* 컨테이너에는 인라인 `display:none` 이 박혀 있어
        // BoardParser.isHidden 가 서브트리 전체(=실제 mp4 OnClick 핸들러
        // + 썸네일)를 드롭. 디코이를 이미 떼낸 이상 hidden 상태로 둘 이유가
        // 없으므로 style 만 비워 가시화. selector 를 `racy_hidden_*` 로
        // 좁혀 두어 다른 사이트가 의존하는 진짜 hidden 가드와 충돌 없음.
        for el in try doc.select("[id^=racy_hidden_]") {
            try el.removeAttr("style")
        }

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

        let updated = post.enrichedForDetail(
            title: title,
            author: author,
            viewCount: viewCount,
            recommendCount: recommend
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
    public nonisolated func commentsURL(for post: Post) -> URL? { nil }

    // MARK: - Field extraction

    nonisolated private func extractTitle(in doc: Document, fallback: String) throws -> String {
        let text = try doc.select("#read_subject_div h2 a").first()?.text() ?? ""
        let cleaned = ParserText.cleanTitle(text)
        return cleaned.isEmpty ? fallback : cleaned
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
        guard let url = resolveHTTPURL(href),
              let host = url.host
        else { return nil }
        let label = try anchor.text().trimmingCharacters(in: .whitespacesAndNewlines)
        return PostSource(name: label.isEmpty ? host : label, url: url)
    }

    // MARK: - Body blocks

    nonisolated private func extractBlocks(in doc: Document) throws -> [ContentBlock] {
        // The article body is nested under <wrap_copy id="wrap_copy"> whose
        // closing tag in the source is a typo (</warp_copy>). SwiftSoup
        // ignores the unmatched close, so the custom element stays open
        // until its parent closes — which means everything that follows
        // (comment list DOM, ad widgets, footer chrome) gets sucked into
        // wrap_copy's subtree. On a real pds post that inflated the body
        // to 22+ image blocks: comment-author icons (icon-file.humoruniv),
        // timg thumb proxies, 11번가/G마켓 광고 CDN URLs, plus loose UI
        // GIFs (waitplz / blt_ad / memo_notice) that aren't in
        // skipImageMarkers. Many simultaneous NetworkImage placeholders
        // → SwiftUI state-update churn + downloader queueing → the
        // "이미지 하나가 hang하면 화면이 멈춘다" symptom.
        //
        // Prefer `div.body_editor` (the editor's own root inside wrap_copy)
        // because its `</div>` close is matched correctly by the HTML5
        // parser regardless of the wrap_copy typo. Fallbacks stay for
        // legacy / Daum-imported posts that don't ship body_editor.
        // Scoped `#wrap_copy div.body_editor` runs before the unscoped
        // `div.body_editor` so a future preview / quoted-post widget
        // sharing the `body_editor` class outside wrap_copy can't win
        // ahead of the real body.
        let candidates: [Element?] = [
            try doc.select("div.daum-wm-content").first(),
            try doc.select("#wrap_copy div.body_editor").first(),
            try doc.select("div.body_editor").first(),
            try doc.select("#wrap_copy").first(),
            try doc.select("div.wrap_body").first(),
        ]
        guard let wrap = candidates.compactMap({ $0 }).first else { return [] }
        // 너굴맨(안심맨) 디코이 + "원본" 펼치기 버튼 정리는 parseDetail
        // 진입 시 doc 레벨에서 이미 처리됨 (본문/댓글 공통).

        var rules = WalkerRules.standard(for: self)
        // humoruniv 본문 이미지는 `down-webp.humoruniv.com` 압축본을 `src` 에 두고
        // 원본 JPG 를 `img_file_url` 속성에 백업으로 박아둔다. 페이지는 WebP 가
        // 404 일 때 인라인 `OnError` 핸들러로 `img_file_url` 로 갈아끼우는데, 우리
        // 파서는 그 JS 를 안 돌리니 src 가 사라진 WebP 면 "다시 시도" 플레이스홀더가
        // 뜬다 (관측 사례: pds#1410992). 댓글 측 stickerURL 과 정책을 맞춰 원본 JPG 가
        // 있으면 그쪽을 1순위로 시도하고, skipImageMarkers 로 chrome 이미지를 거른다.
        rules.resolveImageURL = {
            imageURL(from: $0, attributes: ["img_file_url", "src", "data-src"], skipMarkers: Self.skipImageMarkers)
        }
        // `img_compress` 이미지는 위 resolveImageURL 이 `img_file_url` 의 작은
        // 정적 JPG 로 갈아끼우지만, `simple_attach_img` 직접 첨부는 원본
        // webp 가 그대로 남는다 — 이 중 애니메이션 움짤은 수 MB~수십 MB 라
        // 다운로드+디코드에 수 초가 걸리고 그동안 placeholder 가 회색 박스로만
        // 떠서 "깨진 것"처럼 보였다 (pds#1412160: 354프레임 720×1280 15.5MB).
        // humoruniv 의 `timg.humoruniv.com/thumb.php?url=…&SIZE=…` 프록시가
        // 같은 이미지의 ~2KB 정적 썸네일을 주므로, webp 로 resolve 된 경우에만
        // 이걸 blur-up 포스터로 달아 즉시 저해상도 프리뷰를 띄운다. JPG 로
        // 갈아탄 이미지(=가벼움)는 webp 가 아니라 자연히 제외돼 불필요한
        // 썸네일 요청이 붙지 않는다.
        rules.imageBlock = { url in
            guard url.pathExtension.lowercased() == "webp",
                  let poster = URL(string: "https://timg.humoruniv.com/thumb.php?url=\(url.absoluteString)&SIZE=120x90")
            else { return .image(url) }
            return .image(url, posterURL: poster)
        }
        rules.customElement = { [self] el in
            // Humor 본문 비디오는 raw `<video>` 가 아니라
            // `<div onclick="comment_mp4_expand('id', 'url.mp4')">` wrapper 로
            // 옴. onclick handler 가 매칭되면 wrapper 자체를 claim 하고
            // 자식 썸네일은 무시.
            let onclick = try el.attr("onclick")
            guard !onclick.isEmpty, let videoURL = try parseMp4Click(onclick) else {
                return nil
            }
            return [.video(videoURL)]
        }
        return try ParserBlockWalker(parser: self, rules: rules).walk(wrap)
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


    // MARK: - Comments

    nonisolated private func extractComments(in doc: Document) throws -> [PostComment] {
        let nodes = try doc.select("#comment li[id^=comment_li_]")
        var results: [PostComment] = []
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
                // Preserve anchors as tappable markdown links — `.text()`
                // below would otherwise drop the href.
                convertAnchorsToMarkdown(in: copy)
                return try copy.text().trimmingCharacters(in: .whitespacesAndNewlines)
            }()

            let videoURL = try extractCommentVideo(in: li)
            // When a comment carries a playable mp4 attachment we render the
            // video directly and skip the static thumbnail — otherwise the
            // thumbnail would flash behind the player while it loads.
            let stickerURL = videoURL == nil ? extractCommentSticker(in: li) : nil
            let authIconURL = try extractAuthIcon(in: li)

            guard !author.isEmpty || !content.isEmpty || stickerURL != nil || videoURL != nil
            else { continue }

            results.append(PostComment(
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

    /// Humor renders attached comment images via:
    ///   <div class="comment_file">
    ///     <img src='/images/loading_bar2.gif' ...>          (progress bar)
    ///     <img class="img_compress"
    ///          src="//timg.humoruniv.com/thumb.php?url=..." (proxy thumb)
    ///          img_file_url="//down.humoruniv.com/.../r_r...jpg" (original)>
    /// Iterate every <img> in the wrapper so the progress bar doesn't shadow
    /// the real attachment, prefer img_file_url (untransformed original) over
    /// the thumb proxy for zoom quality, and skip the loading-bar decoy.
    nonisolated private func extractCommentSticker(in li: Element) -> URL? {
        firstImageURL(
            in: li,
            selector: ".comment_file img",
            attributes: ["img_file_url", "data-original", "src"],
            skipMarkers: ["loading_bar"]
        )
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
