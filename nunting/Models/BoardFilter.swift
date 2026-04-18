import Foundation

struct BoardFilter: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let queryItems: [String: String]
}
