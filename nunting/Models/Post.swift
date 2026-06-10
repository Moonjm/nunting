import Foundation
import CoreGraphics

/// `Codable`: 목록 디스크 스냅샷(`BoardListSnapshotStore`)용 — 모든 필드가
/// 텍스트 메타데이터라 합성 인코딩으로 충분하다.
public struct Post: Identifiable, Hashable, Codable {
    public let id: String
    public let site: Site
    public let boardID: String
    public let title: String
    public let author: String
    public let date: Date?
    public let dateText: String
    public let commentCount: Int
    public let url: URL
    public let viewCount: Int?
    public let recommendCount: Int?
    /// User level on most sites (e.g. Inven "Lv.42"); on aagag mirror posts
    /// it's the source-site code (`ppomppu`, `humor`, ...) which the list
    /// view renders as a colored `AagagSourceTag` instead of plain text.
    public let levelText: String?
    public let hasAuthIcon: Bool

    public nonisolated init(
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

    /// Returns a copy enriched with detail-page metadata, preserving every
    /// list-resolved field the detail page doesn't restate (id, site,
    /// boardID, url, date, dateText, levelText, hasAuthIcon). A nil count
    /// keeps the current value, so a `parseDetail` can forward only what the
    /// detail page actually surfaced and let the list-derived value stand in
    /// otherwise — i.e. passing `viewCount: parsed` reproduces the
    /// `parsed ?? post.viewCount` fallback the call sites used to spell out.
    /// Collapses the ~13-line field-copy block the parser `parseDetail`
    /// implementations otherwise repeated verbatim.
    public nonisolated func enrichedForDetail(
        title: String,
        author: String? = nil,
        commentCount: Int? = nil,
        viewCount: Int? = nil,
        recommendCount: Int? = nil
    ) -> Post {
        Post(
            id: id,
            site: site,
            boardID: boardID,
            title: title,
            author: author ?? self.author,
            date: date,
            dateText: dateText,
            commentCount: commentCount ?? self.commentCount,
            url: url,
            viewCount: viewCount ?? self.viewCount,
            recommendCount: recommendCount ?? self.recommendCount,
            levelText: levelText,
            hasAuthIcon: hasAuthIcon
        )
    }
}

public struct ContentBlock: Identifiable, Hashable {
    public let id: UUID
    public let kind: Kind

    public enum Kind: Hashable {
        case richText([InlineSegment])
        case image(url: URL, posterURL: URL?, aspectRatio: CGFloat?)
        case video(url: URL, posterURL: URL?)
        case dealLink(url: URL, label: String)
        case embed(provider: EmbedProvider, id: String)
    }

    public nonisolated init(id: UUID, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public nonisolated static func text(_ s: String) -> ContentBlock {
        .init(id: UUID(), kind: .richText([.text(s)]))
    }
    public nonisolated static func richText(_ segments: [InlineSegment]) -> ContentBlock {
        .init(id: UUID(), kind: .richText(segments))
    }
    public nonisolated static func image(_ url: URL, posterURL: URL? = nil, aspectRatio: CGFloat? = nil) -> ContentBlock {
        .init(id: UUID(), kind: .image(url: url, posterURL: posterURL, aspectRatio: aspectRatio))
    }
    public nonisolated static func video(_ url: URL, posterURL: URL? = nil) -> ContentBlock {
        .init(id: UUID(), kind: .video(url: url, posterURL: posterURL))
    }
    public nonisolated static func dealLink(_ url: URL, label: String) -> ContentBlock {
        .init(id: UUID(), kind: .dealLink(url: url, label: label))
    }
    public nonisolated static func embed(_ provider: EmbedProvider, id: String) -> ContentBlock {
        .init(id: UUID(), kind: .embed(provider: provider, id: id))
    }
}

public enum EmbedProvider: Hashable {
    case youtube
    case instagram
}

public enum InlineSegment: Hashable {
    case text(String)
    case link(url: URL, label: String)
}

public struct PostSource: Hashable {
    public let name: String
    public let url: URL

    public nonisolated init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

public struct PostDetail {
    public let post: Post
    public let blocks: [ContentBlock]
    public let fullDateText: String?
    public let viewCount: Int?
    public let source: PostSource?
    public let comments: [PostComment]

    public nonisolated init(
        post: Post,
        blocks: [ContentBlock],
        fullDateText: String?,
        viewCount: Int?,
        source: PostSource?,
        comments: [PostComment]
    ) {
        self.post = post
        self.blocks = blocks
        self.fullDateText = fullDateText
        self.viewCount = viewCount
        self.source = source
        self.comments = comments
    }

    public var images: [URL] {
        blocks.compactMap { block in
            if case .image(let url, _, _) = block.kind { url } else { nil }
        }
    }
}
