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

struct ContentBlock: Identifiable, Hashable {
    let id: UUID
    let kind: Kind

    enum Kind: Hashable {
        case text(String)
        case image(URL)
        case video(URL)
    }

    static func text(_ s: String) -> ContentBlock { .init(id: UUID(), kind: .text(s)) }
    static func image(_ url: URL) -> ContentBlock { .init(id: UUID(), kind: .image(url)) }
    static func video(_ url: URL) -> ContentBlock { .init(id: UUID(), kind: .video(url)) }
}

struct PostSource: Hashable {
    let name: String
    let url: URL
}

struct PostDetail {
    let post: Post
    let blocks: [ContentBlock]
    let fullDateText: String?
    let viewCount: Int?
    let source: PostSource?
    let comments: [Comment]

    var images: [URL] {
        blocks.compactMap { block in
            if case .image(let url) = block.kind { url } else { nil }
        }
    }
}
