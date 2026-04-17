import Foundation

struct Comment: Identifiable, Hashable {
    let id: String
    let author: String
    let dateText: String
    let content: String
    let likeCount: Int
    let isReply: Bool
}
