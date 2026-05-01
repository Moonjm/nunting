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
/// No SWR cache — board transitions (drawer tap, swipe-step, filter
/// change, search) all go through the cold path with a visible spinner.
/// SwiftUI's view identity already preserves `posts` across structural
/// re-renders (e.g. dismissing the detail overlay), so transparent
/// continuity for non-navigation paths needs no separate cache.
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

    /// Drive from the view's `.refreshable` modifier (pull-to-refresh).
    /// Bypasses the `loadedKey` short-circuit so a manual refresh
    /// always re-fetches even if the same key was just loaded.
    func reload(board: Board, filter: BoardFilter?, searchQuery: String?) async {
        let key = Self.taskKey(board: board, filter: filter, searchQuery: searchQuery)
        currentKey = key
        // Don't clear `posts` first — the existing list stays on
        // screen during the refresh and `.refreshable` shows its own
        // native spinner.
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
            let parser = try ParserFactory.parser(for: board.site)
            return try parser.parseList(html: html, board: board)
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
