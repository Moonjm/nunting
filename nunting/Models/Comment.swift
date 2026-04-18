import Foundation

struct Comment: Identifiable, Hashable {
    let id: String
    let author: String
    let dateText: String
    let content: String
    let likeCount: Int
    let isReply: Bool
    let stickerURL: URL?
    let authIconURL: URL?

    init(
        id: String,
        author: String,
        dateText: String,
        content: String,
        likeCount: Int,
        isReply: Bool,
        stickerURL: URL? = nil,
        authIconURL: URL? = nil
    ) {
        self.id = id
        self.author = author
        self.dateText = dateText
        self.content = content
        self.likeCount = likeCount
        self.isReply = isReply
        self.stickerURL = stickerURL
        self.authIconURL = authIconURL
    }
}

