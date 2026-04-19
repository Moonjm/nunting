import Foundation
import CoreGraphics

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
    let viewCount: Int?
    let recommendCount: Int?
    /// User level on most sites (e.g. Inven "Lv.42"); on aagag mirror posts
    /// it's the source-site code (`ppomppu`, `humor`, ...) which the list
    /// view renders as a colored `AagagSourceTag` instead of plain text.
    let levelText: String?
    let hasAuthIcon: Bool

    init(
        id: String,
        site: Site,
        boardID: String,
        title: String,
        author: String,
        date: Date?,
        dateText: String,
        commentCount: Int,
        url: URL,
        viewCount: Int? = nil,
        recommendCount: Int? = nil,
        levelText: String? = nil,
        hasAuthIcon: Bool = false
    ) {
        self.id = id
        self.site = site
        self.boardID = boardID
        self.title = title
        self.author = author
        self.date = date
        self.dateText = dateText
        self.commentCount = commentCount
        self.url = url
        self.viewCount = viewCount
        self.recommendCount = recommendCount
        self.levelText = levelText
        self.hasAuthIcon = hasAuthIcon
    }
}

struct ContentBlock: Identifiable, Hashable {
    let id: UUID
    let kind: Kind

    enum Kind: Hashable {
        case richText([InlineSegment])
        case image(url: URL, aspectRatio: CGFloat?)
        case video(url: URL, posterURL: URL?)
        case dealLink(url: URL, label: String)
        case embed(provider: EmbedProvider, id: String)
    }

    static func text(_ s: String) -> ContentBlock {
        .init(id: UUID(), kind: .richText([.text(s)]))
    }
    static func richText(_ segments: [InlineSegment]) -> ContentBlock {
        .init(id: UUID(), kind: .richText(segments))
    }
    static func image(_ url: URL, aspectRatio: CGFloat? = nil) -> ContentBlock {
        .init(id: UUID(), kind: .image(url: url, aspectRatio: aspectRatio))
    }
    static func video(_ url: URL, posterURL: URL? = nil) -> ContentBlock {
        .init(id: UUID(), kind: .video(url: url, posterURL: posterURL))
    }
    static func dealLink(_ url: URL, label: String) -> ContentBlock {
        .init(id: UUID(), kind: .dealLink(url: url, label: label))
    }
    static func embed(_ provider: EmbedProvider, id: String) -> ContentBlock {
        .init(id: UUID(), kind: .embed(provider: provider, id: id))
    }
}

enum EmbedProvider: Hashable {
    case youtube
    case instagram
}

enum InlineSegment: Hashable {
    case text(String)
    case link(url: URL, label: String)
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
            if case .image(let url, _) = block.kind { url } else { nil }
        }
    }
}
