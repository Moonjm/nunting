import Foundation

struct Comment: Identifiable, Hashable {
    let id: String
    let author: String
    let dateText: String
    let content: String
    let likeCount: Int
    let isReply: Bool
    let stickerURL: URL?
    /// Inline video attachment (e.g. humoruniv's click-to-play comment mp4s).
    /// When set, the comment renders an `InlineVideoPlayer` instead of a
    /// static sticker image.
    let videoURL: URL?
    let authIconURL: URL?
    let levelIconURL: URL?

    nonisolated init(
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

