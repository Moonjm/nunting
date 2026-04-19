import Foundation
import Observation

/// Caches the per-site board catalog (grouped). Drawer reads from here and
/// triggers `loadIfNeeded(_:)` when the user opens a site that hasn't been
/// fetched yet. Falls back to a single ungrouped bootstrap from
/// `Board.boards(for:)` until the network call completes.
@Observable
@MainActor
final class BoardCatalogStore {
    private(set) var groups: [Site: [BoardGroup]] = [:]
    private(set) var loading: Set<Site> = []
    private(set) var errors: [Site: String] = [:]

    func groups(for site: Site) -> [BoardGroup] {
        groups[site] ?? [BoardGroup(id: site.rawValue, name: nil, boards: Board.boards(for: site))]
    }

    func boards(for site: Site) -> [Board] {
        groups(for: site).flatMap(\.boards)
    }

    func isLoading(_ site: Site) -> Bool { loading.contains(site) }
    func error(for site: Site) -> String? { errors[site] }

    func loadIfNeeded(_ site: Site) async {
        guard groups[site] == nil, !loading.contains(site) else { return }
        guard let catalog = SiteCatalogFactory.catalog(for: site) else { return }
        loading.insert(site)
        errors[site] = nil
        defer { loading.remove(site) }
        do {
            let result = try await catalog.fetchGroups { url, encoding in
                try await Networking.fetchHTML(url: url, encoding: encoding)
            }
            groups[site] = result
        } catch {
            errors[site] = error.localizedDescription
        }
    }
}
