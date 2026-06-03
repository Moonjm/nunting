import Foundation

public struct PostComment: Identifiable, Hashable {
    public let id: String
    public let author: String
    public let dateText: String
    public let content: String
    public let likeCount: Int
    public let isReply: Bool
    /// 답글 대상 닉네임(있을 때). 뷰가 본문 앞에 파란 `@이름` 멘션으로 렌더한다.
    /// SLR 처럼 대상이 구조화 필드(JSON `tn`)로 오는 사이트가 채운다. 뽐뿌처럼
    /// 멘션이 본문 텍스트에 이미 `@닉` 으로 박혀 오는 사이트는 nil(스캔으로 처리).
    public let replyTarget: String?
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
        replyTarget: String? = nil,
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
        self.replyTarget = replyTarget
        self.stickerURL = stickerURL
        self.videoURL = videoURL
        self.authIconURL = authIconURL
        self.levelIconURL = levelIconURL
    }
}
