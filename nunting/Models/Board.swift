import Foundation

struct Board: Identifiable, Hashable, Codable {
    let id: String
    let site: Site
    let name: String
    let path: String

    var url: URL {
        URL(string: path, relativeTo: site.baseURL)?.absoluteURL ?? site.baseURL
    }
}

extension Board {
    static let clienNews = Board(id: "clien-news", site: .clien, name: "새로운 소식", path: "/service/board/news")
    static let clienJirum = Board(id: "clien-jirum", site: .clien, name: "알뜰구매", path: "/service/board/jirum")
    static let clienPark = Board(id: "clien-park", site: .clien, name: "모두의 공원", path: "/service/board/park")

    static let coolenjoyJirum = Board(id: "coolenjoy-jirum", site: .coolenjoy, name: "지름게시판", path: "/bbs/jirum")
    static let coolenjoyFree = Board(id: "coolenjoy-free", site: .coolenjoy, name: "자유게시판", path: "/bbs/fboard")

    static let invenMaple = Board(id: "inven-maple", site: .inven, name: "메이플 자유게시판", path: "/board/maple/5974")

    static let ppomppuMain = Board(id: "ppomppu-main", site: .ppomppu, name: "뽐뿌게시판", path: "/zboard/zboard.php?id=ppomppu")
    static let ppomppuFree = Board(id: "ppomppu-free", site: .ppomppu, name: "자유게시판", path: "/zboard/zboard.php?id=freeboard")

    static let all: [Board] = [
        .clienNews, .clienJirum, .clienPark,
        .coolenjoyJirum, .coolenjoyFree,
        .invenMaple,
        .ppomppuMain, .ppomppuFree,
    ]

    static func boards(for site: Site) -> [Board] {
        all.filter { $0.site == site }
    }
}
