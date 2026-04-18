import Foundation

struct Board: Identifiable, Hashable, Codable {
    let id: String
    let site: Site
    let name: String
    let path: String
    let filters: [BoardFilter]
    /// When non-nil, the board supports keyword search; the URL receives a
    /// `?{searchQueryName}=KEYWORD` parameter merged into its query items.
    let searchQueryName: String?
    /// Query parameter name used for paging (e.g. `page` on aagag). Nil means
    /// the board does not support infinite scroll.
    let pageQueryName: String?

    init(id: String, site: Site, name: String, path: String, filters: [BoardFilter] = [], searchQueryName: String? = nil, pageQueryName: String? = nil) {
        self.id = id
        self.site = site
        self.name = name
        self.path = path
        self.filters = filters
        self.searchQueryName = searchQueryName
        self.pageQueryName = pageQueryName
    }

    var url: URL { url(filter: nil, search: nil, page: nil) }

    func url(filter: BoardFilter?) -> URL {
        url(filter: filter, search: nil, page: nil)
    }

    func url(filter: BoardFilter?, search: String?) -> URL {
        url(filter: filter, search: search, page: nil)
    }

    func url(filter: BoardFilter?, search: String?, page: Int?) -> URL {
        let effectivePath = filter?.pathOverride ?? path
        let base = URL(string: effectivePath, relativeTo: site.baseURL)?.absoluteURL ?? site.baseURL

        let extraItems: [(String, String)] = (filter?.queryItems.map { ($0.key, $0.value) } ?? [])
            + searchItems(query: search)
            + pageItems(page: page)
        if extraItems.isEmpty { return base }

        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        var items = comps.queryItems ?? []
        for (key, value) in extraItems {
            items.removeAll { $0.name == key }
            items.append(URLQueryItem(name: key, value: value))
        }
        comps.queryItems = items
        return comps.url ?? base
    }

    var supportsSearch: Bool { searchQueryName != nil }
    var supportsPaging: Bool { pageQueryName != nil }

    private func searchItems(query: String?) -> [(String, String)] {
        guard let searchQueryName,
              let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        return [(searchQueryName, query)]
    }

    private func pageItems(page: Int?) -> [(String, String)] {
        guard let pageQueryName, let page, page > 1 else { return [] }
        return [(pageQueryName, "\(page)")]
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

    static let ppomppuMain = Board(id: "ppomppu-main", site: .ppomppu, name: "뽐뿌게시판", path: "/new/bbs_list.php?id=ppomppu")
    static let ppomppuFree = Board(id: "ppomppu-free", site: .ppomppu, name: "자유게시판", path: "/new/bbs_list.php?id=freeboard")

    static let aagag = Board(
        id: "aagag",
        site: .aagag,
        name: "모음",
        path: "/mirror/?site=clien%7Cppomppu%7C82cook%7Cbobae%7Chumor%7Cddanzi%7Cslrclub%7Cdamoang&select=multi",
        filters: [
            BoardFilter(id: "issue", name: "이슈모음", pathOverride: "/issue/"),
        ],
        searchQueryName: "word",
        pageQueryName: "page"
    )

    static let all: [Board] = [
        .clienNews, .clienJirum, .clienPark,
        .coolenjoyJirum, .coolenjoyFree, .coolenjoyReview, .coolenjoyQna,
        .invenMaple,
        .ppomppuMain, .ppomppuFree,
        .aagag,
    ]

    static func boards(for site: Site) -> [Board] {
        all.filter { $0.site == site }
    }
}
