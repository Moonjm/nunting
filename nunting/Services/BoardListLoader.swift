import Foundation
import Observation

/// Owns the network + parse + state-machine for `BoardListView`.
///
/// Pulled out of the view so:
///  - Tests can drive the cold-path / SWR cache hit / silent revalidate /
///    loadMore branches without spinning up SwiftUI.
///  - The view stays close to "render this state" with `.task(id:)` as
///    the only lifecycle hook.
///  - Future loader features (offline mode, retry policies, prefetch
///    coalescing) only touch this file.
///
/// Mirrors the prior in-view implementation byte-for-byte on observable
/// state and timing — same cache-hit instant-render path, same
/// `currentPage > 1` guard against silent overwrites, same Clien-search
/// HTTP 400 fallback to a cookieless re-fetch.
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

    init(fetcher: @escaping Fetcher = { url, encoding, userAgent, handlesCookies in
        try await Networking.fetchHTML(
            url: url,
            encoding: encoding,
            userAgent: userAgent,
            handlesCookies: handlesCookies
        )
    }) {
        self.fetcher = fetcher
    }

    // MARK: - Public API

    /// Mirrors `BoardListCache.key` exactly so the loader and cache
    /// agree on the canonical key for a request. Static so the view
    /// can compute it for `.task(id:)` without instantiating a loader.
    nonisolated static func taskKey(board: Board, filter: BoardFilter?, searchQuery: String?) -> String {
        BoardListCache.key(boardID: board.id, filterID: filter?.id, searchQuery: searchQuery)
    }

    /// Drive from `BoardListView.task(id: BoardListLoader.taskKey(...))`.
    /// Stale-while-revalidate: cache hit → instant render + silent
    /// background revalidate; cache miss → cold path with spinner.
    /// Idempotent on re-entry with the same key (post-success).
    func refresh(
        board: Board,
        filter: BoardFilter?,
        searchQuery: String?,
        cache: BoardListCache
    ) async {
        let key = Self.taskKey(board: board, filter: filter, searchQuery: searchQuery)
        currentKey = key
        guard loadedKey != key else { return }

        if let cached = cache.get(taskKey: key) {
            posts = cached.posts
            seenIDs = Set(cached.posts.map(\.id))
            currentPage = 1
            hasMorePages = cached.hasMorePages
            nextSearchURL = cached.nextSearchURL
            loadMoreError = false
            errorMessage = nil
            // Clear stale `isLoading` from a cancelled prior task —
            // its `defer` is gated on `key == currentKey` so an
            // in-flight cold load we just superseded leaves
            // `isLoading = true` behind. Silent revalidate doesn't
            // touch `isLoading`, so without this reset the view's
            // `loadingView` branch could fire later if `posts` ever
            // transiently empties (refresh, filter swap mid-flight).
            isLoading = false
            loadedKey = key
            await load(board: board, filter: filter, searchQuery: searchQuery, cache: cache, silent: true)
            return
        }

        posts = []
        seenIDs = []
        currentPage = 1
        hasMorePages = true
        loadMoreError = false
        errorMessage = nil
        nextSearchURL = nil
        await load(board: board, filter: filter, searchQuery: searchQuery, cache: cache, silent: false)
    }

    /// Drive from the view's `.refreshable` modifier (pull-to-refresh).
    /// Bypasses the `loadedKey` short-circuit so a manual refresh
    /// always re-fetches even if the same key was just loaded.
    func reload(
        board: Board,
        filter: BoardFilter?,
        searchQuery: String?,
        cache: BoardListCache
    ) async {
        let key = Self.taskKey(board: board, filter: filter, searchQuery: searchQuery)
        currentKey = key
        // Don't clear `posts` first — the existing list stays on
        // screen during the refresh and `.refreshable` shows its own
        // native spinner.
        await load(board: board, filter: filter, searchQuery: searchQuery, cache: cache, silent: false)
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

    private func load(
        board: Board,
        filter: BoardFilter?,
        searchQuery: String?,
        cache: BoardListCache,
        silent: Bool
    ) async {
        guard !Task.isCancelled else { return }
        let key = Self.taskKey(board: board, filter: filter, searchQuery: searchQuery)
        if !silent {
            errorMessage = nil
            isLoading = true
        }
        defer {
            if !silent, key == currentKey {
                isLoading = false
            }
        }
        do {
            let url = board.url(filter: filter, search: searchQuery, page: nil)
            let html = try await fetchHTML(url: url, board: board, searchQuery: searchQuery)
            try Task.checkCancellation()
            let parsed = try await Self.parseListOffMain(html: html, board: board)
            guard key == currentKey else { return }
            // Silent revalidation only owns the first page. If the user
            // has already paginated past it (`currentPage > 1`), keep
            // their merged list — replacing it with a fresh page-1
            // response would drop the loadMore'd tail and jumble scroll.
            if silent, currentPage > 1 { return }
            posts = parsed
            seenIDs = Set(parsed.map(\.id))
            currentPage = 1
            nextSearchURL = Self.nextSearchPageURL(from: html, board: board, searchQuery: searchQuery)
            hasMorePages = board.supportsPaging && (!parsed.isEmpty || nextSearchURL != nil)
            loadedKey = key
            cache.put(
                taskKey: key,
                posts: parsed,
                hasMorePages: hasMorePages,
                nextSearchURL: nextSearchURL
            )
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            // On silent revalidate, leave the cached list visible — the
            // user already sees something useful and a transient
            // network blip shouldn't surface as an error overlay.
            guard !silent, key == currentKey else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Single fetch with the Clien-search HTTP 400 fallback. Routed
    /// through the injected `Fetcher` so test fakes intercept *both*
    /// the primary and retry attempts uniformly (matches the lesson
    /// from the PpomppuCatalog silent-bypass cleanup).
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

    private nonisolated static func parseListOffMain(html: String, board: Board) async throws -> [Post] {
        try await Task.detached(priority: .userInitiated) {
            let parser = try ParserFactory.parser(for: board.site)
            return try parser.parseList(html: html, board: board)
        }.value
    }

    private nonisolated static func nextSearchPageURL(from html: String, board: Board, searchQuery: String?) -> URL? {
        guard board.site == .inven,
              searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return nil }

        let pattern = #"<a\s+href="([^"]*sterm=[^"]*)"\s+class="search-total""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html)
        else { return nil }

        let href = String(html[range])
            .replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: href, relativeTo: board.site.baseURL)?.absoluteURL
    }
}
