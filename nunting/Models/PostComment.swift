import Foundation

public struct PostComment: Identifiable, Hashable {
    public let id: String
    public let author: String
    public let dateText: String
    public let content: String
    public let likeCount: Int
    public let isReply: Bool
    public let stickerURL: URL?
    /// Inline video attachment (e.g. humoruniv's click-to-play comment mp4s).
    /// When set, the comment renders an `InlineVideoPlayer` instead of a
    /// static sticker image.
    public let videoURL: URL?
    public let authIconURL: URL?
    public let levelIconURL: URL?

    public nonisolated init(
        id: String,
        author: String,
        dateText: String,
        content: String,
        likeCount: Int,
        isReply: Bool,
        stickerURL: URL? = nil,
        videoURL: URL? = nil,
        authIconURL: URL? = nil,
        levelIconURL: URL? = nil
    ) {
        self.id = id
        self.author = author
        self.dateText = dateText
        self.content = content
        self.likeCount = likeCount
        self.isReply = isReply
        self.stickerURL = stickerURL
        self.videoURL = videoURL
        self.authIconURL = authIconURL
        self.levelIconURL = levelIconURL
    }
}
