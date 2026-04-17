import Foundation

struct Board: Identifiable, Hashable, Codable {
    let id: String
    let site: Site
    let name: String
    let path: String

    var url: URL {
        site.baseURL.appendingPathComponent(path)
    }
}

extension Board {
    static let clienNews = Board(
        id: "clien-news",
        site: .clien,
        name: "새로운 소식",
        path: "/service/board/news"
    )
}
