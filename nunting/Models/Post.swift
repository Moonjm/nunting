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

struct PostDetail {
    let post: Post
    let contentHTML: String
    let images: [URL]
}
