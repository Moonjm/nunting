import Foundation

struct Post: Identifiable, Hashable {
    let id: String
    let site: Site
    let boardID: String
    let title: String
    let author: String
    let date: Date?
    let dateText: String
    let commentCount: Int
    let url: URL
}

enum ContentBlock: Identifiable, Hashable {
    case text(String)
    case image(URL)

    var id: String {
        switch self {
        case .text(let s): "t-\(s.hashValue)"
        case .image(let url): "i-\(url.absoluteString)"
        }
    }
}

struct PostDetail {
    let post: Post
    let blocks: [ContentBlock]
    let images: [URL]
    let fullDateText: String?
    let viewCount: Int?
}
