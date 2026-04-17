import Foundation

protocol BoardParser {
    var site: Site { get }
    func parseList(html: String, board: Board) throws -> [Post]
    func parseDetail(html: String, post: Post) throws -> PostDetail
}

enum ParserError: Error, LocalizedError {
    case missingField(String)
    case invalidHTML

    var errorDescription: String? {
        switch self {
        case .missingField(let field): "파싱 실패: \(field) 누락"
        case .invalidHTML: "HTML 파싱 실패"
        }
    }
}
