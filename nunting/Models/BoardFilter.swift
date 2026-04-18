import Foundation

struct BoardFilter: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let queryItems: [String: String]
    /// When non-nil, swap the board's path entirely (e.g. switching between
    /// `/mirror/` and `/issue/` on aagag) instead of merging query items.
    let pathOverride: String?

    init(id: String, name: String, queryItems: [String: String] = [:], pathOverride: String? = nil) {
        self.id = id
        self.name = name
        self.queryItems = queryItems
        self.pathOverride = pathOverride
    }
}
