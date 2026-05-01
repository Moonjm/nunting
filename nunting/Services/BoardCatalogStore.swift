import Foundation
import Observation

/// Caches the per-site board catalog (grouped). Drawer reads from here and
/// triggers `loadIfNeeded(_:)` when the user opens a site that hasn't been
/// fetched yet. Falls back to a single ungrouped bootstrap from
/// `Board.boards(for:)` until the network call completes.
///
/// Catalogs revalidate after `staleTTL`: a `loadIfNeeded` call against an
/// already-loaded but aged site silently re-fetches in the background and
/// swaps the new groups in on success. Failures during silent revalidate
/// are swallowed — the existing catalog stays visible. The cold-load path
/// still surfaces spinner state via `loading` and errors via `errors`.
@Observable
@MainActor
final class BoardCatalogStore {
    typealias Fetcher = @Sendable (URL, String.Encoding) async throws -> String

    private(set) var groups: [Site: [BoardGroup]] = [:]
    /// Surfaced to the drawer header as a spinner. Only populated on the
    /// cold-load path so a silent revalidate after foreground re-entry
    /// doesn't flicker the UI.
    private(set) var loading: Set<Site> = []
    private(set) var errors: [Site: String] = [:]
    /// When this site's catalog was last successfully fetched. Drives
    /// the silent-revalidate decision in `loadIfNeeded`.
    private(set) var lastFetchedAt: [Site: Date] = [:]
    /// Concurrent-fetch guard. Distinct from `loading` because silent
    /// revalidates need re-entrancy protection without showing a spinner.
    private var inFlight: Set<Site> = []

    let staleTTL: TimeInterval
    private let fetcher: Fetcher
    private let now: @Sendable () -> Date

    init(
        fetcher: @escaping Fetcher = { url, encoding in
            try await Networking.fetchHTML(url: url, encoding: encoding)
        },
        staleTTL: TimeInterval = 6 * 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.staleTTL = staleTTL
        self.now = now
    }

    func groups(for site: Site) -> [BoardGroup] {
        groups[site] ?? [BoardGroup(id: site.rawValue, name: nil, boards: Board.boards(for: site))]
    }

    func boards(for site: Site) -> [Board] {
        groups(for: site).flatMap(\.boards)
    }

    func isLoading(_ site: Site) -> Bool { loading.contains(site) }
    func error(for site: Site) -> String? { errors[site] }

    func loadIfNeeded(_ site: Site) async {
        let isCold = groups[site] == nil
        let isStale = isCatalogStale(site)
        guard (isCold || isStale), !inFlight.contains(site) else { return }
        guard let catalog = SiteCatalogFactory.catalog(for: site) else { return }

        inFlight.insert(site)
        if isCold {
            loading.insert(site)
            errors[site] = nil
        }
        defer {
            inFlight.remove(site)
            loading.remove(site)
        }

        do {
            // SwiftSoup parsing inside fetchGroups is non-trivial (ppomppu
            // parses two HTML docs and runs three selector sets). Detach so
            // the work runs off the main actor and the site rail tap doesn't
            // hitch the UI.
            let fetcher = self.fetcher
            let result = try await Task.detached(priority: .userInitiated) {
                try await catalog.fetchGroups(html: fetcher)
            }.value
            groups[site] = result
            lastFetchedAt[site] = now()
        } catch {
            // Silent revalidate failure: leave the previously-loaded catalog
            // visible rather than wiping it for a transient network blip.
            // Cold-load failure still propagates to the drawer header.
            if isCold {
                errors[site] = error.localizedDescription
            }
        }
    }

    /// Trigger from `scenePhase == .active` so apps backgrounded long
    /// enough for upstream board renames / additions to land catch the
    /// drift on next foreground. Only revalidates sites already in
    /// `groups` — sites the user hasn't opened yet load lazily on next
    /// drawer navigation.
    func revalidateLoadedCatalogs() async {
        let candidates = Array(groups.keys)
        for site in candidates where isCatalogStale(site) {
            await loadIfNeeded(site)
        }
    }

    private func isCatalogStale(_ site: Site) -> Bool {
        guard let last = lastFetchedAt[site] else { return false }
        return now().timeIntervalSince(last) > staleTTL
    }
}
