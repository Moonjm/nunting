import Foundation
import Observation
/// Owns the network + parse + state-machine for `BoardListView`.
///
/// Pulled out of the view so:
///  - Tests can drive the cold-path / loadMore branches without
///    spinning up SwiftUI.
///  - The view stays close to "render this state" with `.task(id:)` as
///    the only lifecycle hook.
///  - Future loader features (offline mode, retry policies) only touch
///    this file.
///
/// Mirrors the prior in-view implementation byte-for-byte on observable
/// state and timing — same `currentKey == loadedKey` short-circuit on
/// re-entry, same Clien-search HTTP 400 fallback to a cookieless
/// re-fetch.
///
/// 보드 전환(드로어 탭, 하단바 좌우 스텝, 필터/검색)은 **의도적으로 cold
/// path** — 한때 key 별 SWR 캐시(이전 목록 즉시 표시 + 백그라운드 재검증)
/// 를 넣었다가, "전환 시 이전 목록 유지보다 최신글을 새로 뿌리는 게 좋다"
/// 는 피드백으로 되돌렸다. 유일한 SWR 은 콜드 스타트 디스크 스냅샷(세션
/// 첫 refresh 한정, 아래 snapshotStore) — 기동 스피너만 제거하고 이후
/// 전환은 전부 fresh. SwiftUI's view identity already preserves `posts`
/// across structural re-renders (e.g. dismissing the detail overlay), so
/// transparent continuity for non-navigation paths needs no separate
/// cache.
@Observable
@MainActor
final class BoardListLoader {
    /// Routes every fetch through one seam so test fakes can intercept
    /// list/search/loadMore traffic uniformly. Fourth arg toggles
    /// cookie handling — `false` is needed for the Clien search retry
    /// path (the shared session occasionally caches a bad
    /// boardCd/sort that triggers 400).
    typealias Fetcher = @Sendable (URL, String.Encoding, String?, Bool) async throws -> String

    // MARK: - Observed state

    private(set) var posts: [Post] = []
    private(set) var hasMorePages: Bool = true
    private(set) var isLoading: Bool = false
    private(set) var isLoadingMore: Bool = false
    private(set) var loadMoreError: Bool = false
    private(set) var errorMessage: String?

    /// Inven-only: true when the most recently parsed search page
    /// surfaced a "다음 검색" total-link. Drives the tap-to-load-more
    /// footer in the list view (auto-paging is suppressed for inven
    /// search to avoid bursting on duplicate-heavy result pages).
    var hasNextSearchPage: Bool { nextSearchURL != nil }

    // MARK: - Private state

    private var seenIDs: Set<String> = []
    private var currentPage: Int = 1
    private var nextSearchURL: URL?

    /// Latest request the view asked us to handle. Used as the stale-
    /// write guard in `defer` and post-await checks: a load that
    /// completes after the view has navigated to a new request must
    /// not overwrite the new request's state.
    private var currentKey: String?
    /// Last key whose first page successfully landed in `posts`. Used
    /// by `refresh` to short-circuit re-entry on the same request.
    private var loadedKey: String?

    private let fetcher: Fetcher
    /// 콜드 스타트용 디스크 스냅샷. 세션 첫 refresh(인메모리 캐시가 빈
    /// 상태)에서 key 일치 시 복원, 첫 페이지 성공마다 갱신.
    private let snapshotStore: BoardListSnapshotStore

    init(
        fetcher: @escaping Fetcher = { url, encoding, userAgent, handlesCookies in
            try await Networking.fetchHTML(
                url: url,
                encoding: encoding,
                userAgent: userAgent,
                handlesCookies: handlesCookies,
                // 보드 목록은 항상 최신글이 중요 — HTTP 캐시를 우회해 보드 전환/
                // 새로고침 때마다 무조건 서버에서 새로 받는다. (전환 자체는 이미
                // reload 로 재요청하지만, URLSession 캐시가 stale 응답을 내주면
                // "새로고침 안 된 듯" 보이던 것을 차단.)
                cachePolicy: .reloadIgnoringLocalCacheData
            )
        },
        snapshotStore: BoardListSnapshotStore = BoardListSnapshotStore()
    ) {
        self.fetcher = fetcher
        self.snapshotStore = snapshotStore
    }

    // MARK: - Public API

    /// Canonical key for a request. Static so the view can compute it
    /// for `.task(id:)` without instantiating a loader.
    nonisolated static func taskKey(board: Board, filter: BoardFilter?, searchQuery: String?) -> String {
        "\(board.id)|\(filter?.id ?? "_all")|\(searchQuery ?? "")"
    }

    /// Drive from `BoardListView.task(id: BoardListLoader.taskKey(...))`.
    /// Cold path with visible spinner. Idempotent on re-entry with the
    /// same key (post-success).
    func refresh(board: Board, filter: BoardFilter?, searchQuery: String?) async {
        let key = Self.taskKey(board: board, filter: filter, searchQuery: searchQuery)
        currentKey = key
        guard loadedKey != key else { return }

        // 콜드 스타트 SWR: 세션 첫 refresh(아직 아무 key 도 로드 전)에서
        // 디스크 스냅샷의 key 가 일치하면 복원 — 기동 시 "스피너 1~3초"가
        // "목록 즉시 + 조용한 재검증"이 된다. 페이징 상태는 디스크에 안
        // 실으므로 첫 페이지 기준으로 초기화. 이후의 보드 전환은 전부
        // cold path (class doccomment 의 fresh-우선 결정 참조).
        if loadedKey == nil,
           let snap = await snapshotStore.load(),
           snap.key == key, !snap.posts.isEmpty {
            // 디스크 await 사이 보드가 바뀌었으면 이 요청은 stale.
            guard key == currentKey else { return }
            posts = snap.posts
            seenIDs = Set(snap.posts.map(\.id))
            currentPage = 1
            hasMorePages = board.supportsPaging
            nextSearchURL = nil
            isLoadingMore = false
            loadMoreError = false
            errorMessage = nil
            // loadedKey 는 여기서 설정하지 않는다 — fresh 재검증 fetch 가 성공해야
            // (load() 내부에서) 비로소 설정된다. 콜드 스타트 재검증이 실패하면
            // loadedKey 가 nil 로 남아, 다음 refresh 가 stale 스냅샷에 갇히지 않고
            // 다시 fresh 를 시도할 수 있다. (cold-path 분기와도 일관 — 거기도
            // load 성공 시에만 loadedKey 를 찍는다.)
            await load(board: board, filter: filter, searchQuery: searchQuery)
            return
        }
        guard key == currentKey else { return }

        posts = []
        seenIDs = []
        currentPage = 1
        hasMorePages = true
        // Reset both `isLoadingMore` and `loadMoreError` here even though
        // `loadMore`'s `defer` normally clears `isLoadingMore`: a board /
        // filter swap mid-paging orphans the in-flight `loadMore` task,
        // and once `currentKey` advances, the orphan's `defer` skips the
        // `isLoadingMore = false` write (key mismatch). Without this
        // explicit clear the new board inherits a stuck spinner footer
        // from the previous board's never-finished page.
        isLoadingMore = false
        loadMoreError = false
        errorMessage = nil
        nextSearchURL = nil
        await load(board: board, filter: filter, searchQuery: searchQuery)
    }

    /// Drive from the view's `.refreshable` modifier (pull-to-refresh)
    /// and from board-switch reload-token bumps. Bypasses the `loadedKey`
    /// short-circuit so a manual refresh always re-fetches even if the
    /// same key was just loaded.
    ///
    /// `clearingList`: 보드 전환은 `true` — 목록을 비우고 스피너를 띄워
    /// "새로고침 중"이 눈에 보이게(헐렸다 다시 만들어지는 먼 보드와 동일한
    /// 피드백). pull-to-refresh 는 `false`(기본) — `.refreshable` 자체 스피너가
    /// 있으니 이전 목록을 화면에 유지한다.
    func reload(board: Board, filter: BoardFilter?, searchQuery: String?, clearingList: Bool = false) async {
        let key = Self.taskKey(board: board, filter: filter, searchQuery: searchQuery)
        currentKey = key
        if clearingList {
            posts = []
            seenIDs = []
            currentPage = 1
            hasMorePages = true
            isLoadingMore = false
            loadMoreError = false
            errorMessage = nil
            nextSearchURL = nil
        }
        await load(board: board, filter: filter, searchQuery: searchQuery)
    }

    /// Drive from the list's last-row `.onAppear` paging trigger.
    /// No-ops if the board doesn't paginate, no more pages exist, or a
    /// prior loadMore is still in flight.
    func loadMore(board: Board, filter: BoardFilter?, searchQuery: String?) async {
        guard board.supportsPaging, hasMorePages, !isLoadingMore else { return }
        let key = Self.taskKey(board: board, filter: filter, searchQuery: searchQuery)
        let nextPage = currentPage + 1
        loadMoreError = false
        isLoadingMore = true
        defer {
            if key == currentKey {
                isLoadingMore = false
            }
        }
        do {
            let url = nextSearchURL ?? board.url(filter: filter, search: searchQuery, page: nextPage)
            let html = try await fetchHTML(url: url, board: board, searchQuery: searchQuery)
            try Task.checkCancellation()
            let parsed = try await Self.parseListOffMain(html: html, board: board)
            guard key == currentKey else { return }
            let loadedSearchURL = nextSearchURL
            nextSearchURL = Self.nextSearchPageURL(from: html, board: board, searchQuery: searchQuery)

            // Insert into seenIDs *during* the filter so an intra-page
            // duplicate (e.g. parsed = [A, A, B]) only appends once.
            var fresh: [Post] = []
            for p in parsed where seenIDs.insert(p.id).inserted {
                fresh.append(p)
            }
            if fresh.isEmpty {
                hasMorePages = nextSearchURL != nil
                return
            }
            posts.append(contentsOf: fresh)
            currentPage = loadedSearchURL == nil ? nextPage : 1
            hasMorePages = if loadedSearchURL != nil {
                nextSearchURL != nil
            } else {
                board.supportsPaging && (nextSearchURL != nil || !fresh.isEmpty)
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            // Surface a "다시 시도" footer so users can retry without
            // losing scroll position. `hasMorePages` stays true so the
            // retry button can fire loadMore.
            guard key == currentKey else { return }
            loadMoreError = true
        }
    }

    // MARK: - Private

    private func load(board: Board, filter: BoardFilter?, searchQuery: String?) async {
        guard !Task.isCancelled else { return }
        let key = Self.taskKey(board: board, filter: filter, searchQuery: searchQuery)
        errorMessage = nil
        isLoading = true
        defer {
            if key == currentKey {
                isLoading = false
            }
        }
        do {
            let url = board.url(filter: filter, search: searchQuery, page: nil)
            let html = try await fetchHTML(url: url, board: board, searchQuery: searchQuery)
            try Task.checkCancellation()
            let parsed = try await Self.parseListOffMain(html: html, board: board)
            guard key == currentKey else { return }
            posts = parsed
            seenIDs = Set(parsed.map(\.id))
            currentPage = 1
            nextSearchURL = Self.nextSearchPageURL(from: html, board: board, searchQuery: searchQuery)
            hasMorePages = board.supportsPaging && (!parsed.isEmpty || nextSearchURL != nil)
            loadedKey = key
            // 다음 콜드 스타트 재료. posts commit 이후라 UI 는 이미 갱신됐고,
            // actor 파일 쓰기는 main 밖에서 직렬화되므로 await 비용은 hop 뿐.
            await snapshotStore.save(key: key, posts: parsed)
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            guard key == currentKey else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Single fetch with the Clien-search HTTP 400 fallback. Routed
    /// through the injected `Fetcher` so test fakes intercept *both*
    /// the primary and retry attempts uniformly.
    private func fetchHTML(url: URL, board: Board, searchQuery: String?) async throws -> String {
        do {
            return try await fetcher(url, board.site.encoding, nil, true)
        } catch NetworkError.badResponse(400)
            where board.site == .clien && searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
            // Clien's /service/search returns 400 when the shared session
            // cookie carries residual sort/boardCd state. A clean,
            // cookieless request with explicit UA recovers.
            return try await fetcher(url, board.site.encoding, Networking.userAgent, false)
        }
    }

    /// Inven search-result paging link. Hoisted to a static so list /
    /// loadMore calls don't pay `NSRegularExpression` construction every
    /// time. Matches the convention used by `InvenParser` /
    /// `AagagParser` for similar per-page selectors. `try!` because the
    /// pattern is a compile-time literal — failure would be a build-
    /// time bug, not runtime.
    private nonisolated static let invenNextSearchRegex = try! NSRegularExpression(
        pattern: #"<a\s+href="([^"]*sterm=[^"]*)"\s+class="search-total""#,
        options: [.caseInsensitive]
    )

    private nonisolated static func parseListOffMain(html: String, board: Board) async throws -> [Post] {
        try await Task.detached(priority: .userInitiated) {
            // autoreleasepool: detached(협력 풀) 스레드엔 런루프가 없어 ObjC
            // autorelease 풀이 안 배수된다. SwiftSoup 파싱이 쏟아내는 ObjC 임시
            // 객체가 Document 노드 그래프를 붙들어, 파싱이 끝나도 해제가 무한
            // 지연된다(보드 전환·스크롤마다 ~30글 DOM 누적). parseList 는 값 타입
            // [Post] 만 반환하므로 풀로 감싸 반환 즉시 배수해도 안전.
            // 같은 처리: 상세 파싱(PostDetailLoader)·댓글 파싱.
            try autoreleasepool {
                let parser = try ParserFactory.parser(for: board.site)
                return try parser.parseList(html: html, board: board)
            }
        }.value
    }

    private nonisolated static func nextSearchPageURL(from html: String, board: Board, searchQuery: String?) -> URL? {
        guard board.site == .inven,
              searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return nil }

        guard let match = invenNextSearchRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html)
        else { return nil }

        let href = String(html[range])
            .replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: href, relativeTo: board.site.baseURL)?.absoluteURL
    }
}
