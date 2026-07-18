import Foundation
import SwiftSoup
/// Parses 다모앙 (damoang.net) detail pages. Reached exclusively via aagag
/// mirror dispatch — 다모앙 is not exposed as a directly-browsable site.
///
/// 다모앙 runs a SvelteKit front end ("Angple", tiptap editor) that
/// server-side renders the detail page: title in `[data-slot=card-title]`,
/// author-block date in `p.text-secondary-foreground`, `조회/공감` counts in
/// the header spans, and the body inside the page's single `div.prose`
/// (`<p>` / `<img>` / YouTube `<iframe class="tiptap-youtube">`).
///
/// Comments are only partially SSR'd (first page); `fetchAllComments` calls
/// the JSON API the web client itself uses:
/// `GET /api/boards/{board}/posts/{id}/comments?page=N&limit=20`
/// (`total_pages` in the envelope drives pagination).
public struct DamoangParser: BoardParser {
    public let site: Site = .damoang

    /// 댓글 API GET 시임 — `(api URL, referer)`. 다모앙 API 는 page≥2 를
    /// Referer(글 URL) 없이는 403 으로 거절한다(실측 2026-07-18: page=1 은
    /// 무-Referer 허용 — 스크레이핑 가드로 보임). 프로토콜의 fetcher 시임은
    /// `(URL) -> String` 이라 Referer 를 실을 수 없어, Aagag/딴지가 댓글
    /// leg 에서 `Networking.postForm` 을 직접 부르는 것과 같은 관례로 파서
    /// 자체 시임을 둔다. 테스트는 canned JSON 을 주입한다.
    nonisolated private let commentFetch: @Sendable (URL, URL) async throws -> String

    public nonisolated init() {
        self.init(commentFetch: { url, referer in
            try await Networking.fetchHTML(url: url, referer: referer)
        })
    }

    // internal(테스트 주입용)
    nonisolated init(commentFetch: @escaping @Sendable (URL, URL) async throws -> String) {
        self.commentFetch = commentFetch
    }

    public nonisolated func parseList(html: String, board: Board) throws -> [Post] {
        // 다모앙 is aagag-dispatch-only; list parsing is never invoked.
        []
    }

    public nonisolated func parseDetail(html: String, post: Post) throws -> PostDetail {
        let doc = try SwiftSoup.parse(html)

        // 본문 wrapper 는 페이지에서 유일한 `div.prose`(tiptap 렌더 타깃).
        // 없으면 SvelteKit 404 셸("게시글을 찾을 수 없습니다 / 요청하신
        // 게시글이 삭제되었거나…") 이거나 마크업 변경이다. 직접 fetch 경로는
        // 삭제글이 HTTP 404 라 `fetchHTML` 이 먼저 throw 하지만, 미러
        // 리다이렉트의 prefetched-body 경로는 상태코드와 무관하게 body 를
        // 넘기므로 이 분기가 안내를 살린다.
        guard let prose = try doc.select("div.prose").first() else {
            let body = try doc.text()
            guard body.contains("삭제되었") || body.contains("찾을 수 없") else {
                throw ParserError.structureChanged("prose 본문 없음")
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

        let rawTitle = ParserText.cleanTitle(
            try doc.select("[data-slot=card-title]").first()?.text() ?? "")
        let title = rawTitle.isEmpty ? post.title : rawTitle

        // 작성자 블록의 날짜 줄 ("2026년 7월 18일 AM 08:43"). 댓글 쪽은
        // `text-muted-foreground` 라 첫 `p.text-secondary-foreground` 가 헤더.
        let dateText = try doc.select("p.text-secondary-foreground").first()?.text()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let viewCount = try headerCount(in: doc, label: "조회")
        let recommend = try headerCount(in: doc, label: "공감")

        let rules = WalkerRules.standard(for: self)
        let blocks = try ParserBlockWalker(parser: self, rules: rules).walk(prose)

        return PostDetail(
            post: post.enrichedForDetail(
                title: title,
                viewCount: viewCount,
                recommendCount: recommend
            ),
            blocks: blocks,
            fullDateText: (dateText?.isEmpty ?? true) ? nil : dateText,
            viewCount: viewCount,
            source: nil,
            comments: [], // filled in by fetchAllComments
            fullTitle: title
        )
    }

    /// 헤더 우측 카운트 스팬("조회 1,047" / "공감 3")에서 숫자를 뽑는다.
    /// 라벨을 own text 로 갖는 첫 span 기준 — 본문/댓글 텍스트는 span 이
    /// 아니라 걸리지 않는다.
    nonisolated private func headerCount(in doc: Document, label: String) throws -> Int? {
        guard let span = try doc.select("span:containsOwn(\(label))").first() else { return nil }
        return ParserText.integerFromDigits(in: try span.text())
    }

    // MARK: - 댓글 JSON API

    /// 댓글 페이지 fetch 상한(이상 응답 방어). 20개/페이지 기준 1천 댓글 —
    /// 실제 다모앙 글은 한참 못 미친다.
    nonisolated private static let maxCommentPages = 50
    /// 서버가 `limit` 을 20으로 clamp 한다(100 요청 시에도 20 반환, 실측
    /// 2026-07-18) — 페이징 산식이 서버 echo 와 어긋나지 않게 명시한다.
    nonisolated private static let commentPageLimit = 20

    public nonisolated func commentsURL(for post: Post) -> URL? {
        apiCommentsURL(for: post, page: 1)
    }

    /// `/free/6739140` → `/api/boards/free/posts/6739140/comments?page=N`.
    /// 게시판 슬러그는 글 URL 경로에서 그대로 딴다 — aagag 이 다른 다모앙
    /// 보드를 미러링하게 되어도 성립. `{board}/{숫자 id}` 꼴이 아니면 nil
    /// (댓글 fetch 를 걸지 않는다).
    nonisolated private func apiCommentsURL(for post: Post, page: Int) -> URL? {
        let comps = post.url.pathComponents.filter { $0 != "/" }
        guard comps.count == 2,
              !comps[0].isEmpty,
              !comps[1].isEmpty, comps[1].allSatisfy(\.isNumber)
        else { return nil }
        return URL(string: "https://damoang.net/api/boards/\(comps[0])/posts/\(comps[1])/comments?page=\(page)&limit=\(Self.commentPageLimit)")
    }

    /// 프로토콜 `fetcher` 는 쓰지 않는다 — Referer 를 실을 수 없어 page≥2 가
    /// 403 으로 조용히 빠진다(`commentFetch` 주석 참조). 모든 페이지 요청에
    /// 글 URL 을 Referer 로 싣는다.
    public nonisolated func fetchAllComments(
        for post: Post,
        detailHTML _: String?,
        fetcher _: @escaping @Sendable (URL) async throws -> String
    ) async throws -> [PostComment] {
        guard let firstURL = apiCommentsURL(for: post, page: 1) else { return [] }
        let first = try decodeCommentPage(try await commentFetch(firstURL, post.url))
        let totalPages = min(first.totalPages, Self.maxCommentPages)
        if totalPages <= 1 { return first.comments }

        // 병렬 fetch + 페이지 단위 실패 흡수 골격은 `mergeCommentPages` 참조.
        return try await mergeCommentPages(
            total: totalPages, inlinePage: 1, inline: first.comments
        ) { page in
            guard let url = self.apiCommentsURL(for: post, page: page) else { return [] }
            return try self.decodeCommentPage(try await self.commentFetch(url, post.url)).comments
        }
    }

    nonisolated struct CommentPage {
        let comments: [PostComment]
        let totalPages: Int
    }

    // internal(테스트 접근용): 실측 API JSON 으로 디코딩 로직 검증.
    nonisolated func decodeCommentPage(_ body: String) throws -> CommentPage {
        guard let data = body.data(using: .utf8) else {
            return CommentPage(comments: [], totalPages: 1)
        }
        let response = try JSONDecoder().decode(CommentResponse.self, from: data)
        guard response.success else { return CommentPage(comments: [], totalPages: 1) }
        let comments = response.data.comments.map { raw in
            PostComment(
                id: "damoang-c-\(raw.id)",
                author: raw.author,
                dateText: Self.displayDate(fromISO: raw.created_at),
                content: renderCommentText(fromHTML: raw.content),
                likeCount: raw.likes,
                isReply: raw.depth > 0,
                stickerURL: commentImageURL(fromHTML: raw.content)
            )
        }
        return CommentPage(comments: comments, totalPages: max(1, response.data.total_pages))
    }

    /// 댓글 본문 HTML 의 첫 `<img>` 를 sticker 로 승격 — 텍스트 flatten
    /// (`renderCommentText`) 은 img 를 버리므로 별도 pass 가 필요하다.
    /// 텍스트 전용 댓글이 대다수라 `<img` prefilter 로 DOM 생성을 아낀다.
    nonisolated private func commentImageURL(fromHTML rawHTML: String) -> URL? {
        guard rawHTML.contains("<img") else { return nil }
        return (try? parsedBodyFragment(rawHTML) { doc -> URL? in
            firstImageURL(in: doc.body() ?? doc, attributes: ["src", "data-src"])
        }) ?? nil
    }

    /// API 의 `created_at`(UTC ISO8601, 밀리초 포함) → 로컬 타임존
    /// `yyyy-MM-dd HH:mm` (에토랜드 댓글과 동일 표기). 파싱 실패 시 원문 유지.
    nonisolated static func displayDate(fromISO iso: String) -> String {
        let date = (try? Self.isoFractional.parse(iso)) ?? (try? Self.isoPlain.parse(iso))
        guard let date else { return iso }
        return commentDateFormatter.string(from: date)
    }

    // 포매터 hoist — 댓글 수만큼 호출되므로 per-call 생성 비용을 피한다
    // (에토랜드 `commentDateFormatter` 와 같은 패턴). ISO 파싱은
    // `ISO8601DateFormatter` 가 아닌 `Date.ISO8601FormatStyle` — 전자는
    // Sendable 이 아니라 nonisolated static let 에 둘 수 없다.
    nonisolated private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    nonisolated private static let isoPlain = Date.ISO8601FormatStyle()
    nonisolated private static let commentDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.locale = Locale(identifier: "ko_KR")
        return fmt
    }()

    nonisolated private struct CommentResponse: Decodable {
        let success: Bool
        let data: PageData

        struct PageData: Decodable {
            let comments: [RawComment]
            let total_pages: Int
        }

        struct RawComment: Decodable {
            let id: Int
            let content: String
            let author: String
            let likes: Int
            let depth: Int
            let created_at: String
        }
    }
}
