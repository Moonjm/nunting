import Foundation

public struct BoardFilter: Identifiable, Hashable, Codable {
    public let id: String
    public let name: String
    /// Merged onto the active path's existing query items.
    public let queryItems: [String: String]
    /// When non-nil, replaces `Board.path` entirely (e.g. switching between
    /// `/mirror/` and `/issue/` on aagag). `queryItems` are still merged onto
    /// the resulting URL — both modes can coexist.
    public let replacementPath: String?

    public init(id: String, name: String, queryItems: [String: String] = [:], replacementPath: String? = nil) {
        self.id = id
        self.name = name
        self.queryItems = queryItems
        self.replacementPath = replacementPath
    }
}
