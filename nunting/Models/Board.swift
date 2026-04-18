import Foundation

struct Board: Identifiable, Hashable, Codable {
    let id: String
    let site: Site
    let name: String
    let path: String
    let filters: [BoardFilter]

    init(id: String, site: Site, name: String, path: String, filters: [BoardFilter] = []) {
        self.id = id
        self.site = site
        self.name = name
        self.path = path
        self.filters = filters
    }

    var url: URL { url(filter: nil) }

    func url(filter: BoardFilter?) -> URL {
        let base = URL(string: path, relativeTo: site.baseURL)?.absoluteURL ?? site.baseURL
        guard let filter, !filter.queryItems.isEmpty,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return base }

        var items = comps.queryItems ?? []
        for (key, value) in filter.queryItems {
            items.removeAll { $0.name == key }
            items.append(URLQueryItem(name: key, value: value))
        }
        comps.queryItems = items
        return comps.url ?? base
    }
}

extension Board {
    static let clienNews = Board(id: "clien-news", site: .clien, name: "새로운 소식", path: "/service/board/news")
    static let clienJirum = Board(id: "clien-jirum", site: .clien, name: "알뜰구매", path: "/service/board/jirum")
    static let clienPark = Board(id: "clien-park", site: .clien, name: "모두의 공원", path: "/service/board/park")

    static let coolenjoyJirum = Board(id: "coolenjoy-jirum", site: .coolenjoy, name: "지름게시판", path: "/bbs/jirum")
    static let coolenjoyFree = Board(id: "coolenjoy-free", site: .coolenjoy, name: "자유게시판", path: "/bbs/freeboard2")
    static let coolenjoyReview = Board(id: "coolenjoy-review", site: .coolenjoy, name: "사용기/리뷰", path: "/bbs/review")
    static let coolenjoyQna = Board(id: "coolenjoy-qna", site: .coolenjoy, name: "질문답변", path: "/bbs/qa")

    static let invenMaple = Board(
        id: "inven-maple",
        site: .inven,
        name: "메이플 자유게시판",
        path: "/board/maple/5974",
        filters: [
            BoardFilter(id: "chu", name: "10추", queryItems: ["my": "chu"]),
            BoardFilter(id: "chuchu", name: "30추", queryItems: ["my": "chuchu"]),
            BoardFilter(id: "inbang", name: "인방", queryItems: ["category": "인방"]),
        ]
    )

    static let ppomppuMain = Board(id: "ppomppu-main", site: .ppomppu, name: "뽐뿌게시판", path: "/zboard/zboard.php?id=ppomppu")
    static let ppomppuFree = Board(id: "ppomppu-free", site: .ppomppu, name: "자유게시판", path: "/zboard/zboard.php?id=freeboard")

    static let all: [Board] = [
        .clienNews, .clienJirum, .clienPark,
        .coolenjoyJirum, .coolenjoyFree, .coolenjoyReview, .coolenjoyQna,
        .invenMaple,
        .ppomppuMain, .ppomppuFree,
    ]

    static func boards(for site: Site) -> [Board] {
        all.filter { $0.site == site }
    }
}
