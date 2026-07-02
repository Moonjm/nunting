import Foundation

// nonisolated(타입 단위): 파서(백그라운드)가 생성하고 테스트가 nonisolated
// 컨텍스트에서 프로퍼티를 읽는 순수 값 — 기본 MainActor 격리 추론에서 통째로
// 뺀다(Swift 6 모드에선 저장 프로퍼티 접근까지 격리가 강제됨).
nonisolated public struct PostComment: Identifiable, Hashable, Sendable {
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
