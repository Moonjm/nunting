import Foundation

/// Runtime board value. Persistence goes through `FavoriteBoardSnapshot`,
/// which rebuilds a `Board` via the designated initializer so the
/// `normalizedSearchQueryName` / default-page-query migration always runs.
/// Intentionally non-`Codable` to prevent bypassing that migration path.
struct Board: Identifiable, Hashable {
    let id: String
    let site: Site
    let name: String
    let path: String
    let filters: [BoardFilter]
    /// When non-nil, the board supports keyword search; the URL receives the
    /// site's search parameters merged into its query items.
    let searchQueryName: String?
    /// Query parameter name used for paging. Defaults to the site's known
    /// board-list paging parameter.
    let pageQueryName: String?

    init(id: String, site: Site, name: String, path: String, filters: [BoardFilter] = [], searchQueryName: String? = nil, pageQueryName: String? = nil) {
        self.id = id
        self.site = site
        self.name = name
        self.path = path
        self.filters = filters
        self.searchQueryName = Self.normalizedSearchQueryName(for: site, provided: searchQueryName)
        self.pageQueryName = pageQueryName ?? Self.defaultPageQueryName(for: site)
    }

    var url: URL { url(filter: nil, search: nil, page: nil) }

    func url(filter: BoardFilter?) -> URL {
        url(filter: filter, search: nil, page: nil)
    }

    func url(filter: BoardFilter?, search: String?) -> URL {
        url(filter: filter, search: search, page: nil)
    }

    func url(filter: BoardFilter?, search: String?, page: Int?) -> URL {
        let trimmedSearch = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = trimmedSearch?.isEmpty == false
        let listPath = filter?.replacementPath ?? path
        let effectivePath = isSearching ? searchPath(for: listPath) : listPath
        let baseURL = isSearching ? searchBaseURL : site.baseURL
        let base = URL(string: effectivePath, relativeTo: baseURL)?.absoluteURL ?? baseURL

        let extraItems: [(String, String)] = (filter?.queryItems.map { ($0.key, $0.value) } ?? [])
            + searchItems(query: trimmedSearch)
            + pageItems(page: page, isSearching: isSearching)
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
              let query, !query.isEmpty
        else { return [] }
        return defaultSearchPrefixItems() + [(searchQueryName, query)]
    }

    private func pageItems(page: Int?, isSearching: Bool) -> [(String, String)] {
        guard let pageQueryName, let page, page > 1 else { return [] }
        let name = Self.pageQueryName(for: site, pageQueryName: pageQueryName, isSearching: isSearching)
        let value = Self.pageQueryValue(for: site, page: page, isSearching: isSearching)
        guard value > 0 else { return [] }
        return [(name, "\(value)")]
    }

    private static func defaultPageQueryName(for site: Site) -> String? {
        switch site {
        case .clien:
            "po"
        case .coolenjoy, .ppomppu, .aagag:
            "page"
        case .inven:
            "p"
        case .humor, .bobae, .slr:
            // Mirror-only dispatch targets — no direct browsing, no paging.
            nil
        }
    }

    private static func defaultSearchQueryName(for site: Site) -> String? {
        switch site {
        case .clien:
            "q"
        case .coolenjoy:
            "stx"
        case .ppomppu:
            "keyword"
        case .inven:
            "svalue"
        case .aagag:
            "word"
        case .humor, .bobae, .slr:
            nil
        }
    }

    private static func normalizedSearchQueryName(for site: Site, provided: String?) -> String? {
        switch site {
        case .clien, .coolenjoy, .inven:
            // Older favorite snapshots can persist stale names such as
            // Clien's former `sv`; these sites need the current fixed keys.
            return defaultSearchQueryName(for: site)
        case .ppomppu, .aagag:
            return provided ?? defaultSearchQueryName(for: site)
        case .humor, .bobae, .slr:
            return nil
        }
    }

    private func defaultSearchPrefixItems() -> [(String, String)] {
        switch site {
        case .clien:
            guard let boardID = Self.clienBoardID(from: path) else { return [] }
            return [("boardCd", boardID), ("isBoard", "true"), ("sort", "recency")]
        case .coolenjoy:
            return [("sfl", "wr_subject")]
        case .inven:
            return [("stype", "subject")]
        case .ppomppu, .aagag, .humor, .bobae, .slr:
            return []
        }
    }

    private func searchPath(for listPath: String) -> String {
        switch site {
        case .clien:
            return "/service/search"
        case .coolenjoy, .inven, .ppomppu, .aagag, .humor, .bobae, .slr:
            return listPath
        }
    }

    private var searchBaseURL: URL {
        switch site {
        case .clien:
            URL(string: "https://m.clien.net")!
        case .coolenjoy, .inven, .ppomppu, .aagag, .humor, .bobae, .slr:
            site.baseURL
        }
    }

    private static func clienBoardID(from path: String) -> String? {
        let cleanPath = path.components(separatedBy: "?").first ?? path
        guard let range = cleanPath.range(of: "/service/board/") else { return nil }
        let tail = cleanPath[range.upperBound...]
        let id = tail.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return id.isEmpty ? nil : String(id)
    }

    private static func pageQueryName(for site: Site, pageQueryName: String, isSearching: Bool) -> String {
        switch site {
        case .clien where isSearching:
            "p"
        case .clien, .coolenjoy, .inven, .ppomppu, .aagag, .humor, .bobae, .slr:
            pageQueryName
        }
    }

    private static func pageQueryValue(for site: Site, page: Int, isSearching: Bool) -> Int {
        switch site {
        case .clien:
            // Clien uses zero-based offsets: page 2 => po/p=1.
            page - 1
        case .coolenjoy, .inven, .ppomppu, .aagag, .humor, .bobae, .slr:
            page
        }
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
            BoardFilter(id: "issue", name: "이슈모음", replacementPath: "/issue/"),
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
