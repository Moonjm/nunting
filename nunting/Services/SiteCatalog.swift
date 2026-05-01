import Foundation
import SwiftSoup

/// Per-site fetcher that returns the full board list. Each implementation
/// knows the catalog URL on its own site and how to parse the menu HTML.
/// Sendable so we can run the heavy SwiftSoup parse off the main actor.
protocol SiteCatalog: Sendable {
    var site: Site { get }
    /// Fetch + parse the catalog as one or more named groups. Sites without
    /// natural grouping return a single group with `name: nil` so the drawer
    /// renders a flat list.
    ///
    /// `html`'s third argument is an optional `User-Agent` override
    /// (`nil` = shared session UA). Catalogs that need a desktop UA
    /// pass `Networking.desktopUserAgent` per-request rather than
    /// bypassing the seam — keeps store-level test fakes effective for
    /// every catalog.
    func fetchGroups(html: @Sendable (URL, String.Encoding, String?) async throws -> String) async throws -> [BoardGroup]
}

enum SiteCatalogFactory {
    static func catalog(for site: Site) -> SiteCatalog? {
        switch site {
        case .clien: return ClienCatalog()
        case .coolenjoy: return CoolenjoyCatalog()
        case .ppomppu: return PpomppuCatalog()
        case .inven, .aagag, .humor, .bobae, .slr, .ddanzi, .cook82: return nil
        }
    }
}

// MARK: - Clien

struct ClienCatalog: SiteCatalog {
    let site: Site = .clien

    /// Marketplace board excluded — user prefers browse-only content (no
    /// member-only sections).
    private static let excludedIDs: Set<String> = [
        "sold",  // 회원중고장터
    ]

    func fetchGroups(html fetcher: @Sendable (URL, String.Encoding, String?) async throws -> String) async throws -> [BoardGroup] {
        // Desktop home tags every board with the right class so we get the
        // exact 커뮤니티(`menu-list`) + 소모임(`menu-list somoim`) sets without
        // pulling in admin / sell / info-archive groups.
        guard let url = URL(string: "https://www.clien.net/") else {
            return [BoardGroup(id: "clien", name: nil, boards: Board.boards(for: .clien))]
        }
        let body = try await fetcher(url, .utf8, nil)
        let doc = try SwiftSoup.parse(body)

        var community: [Board] = []
        var somoim: [Board] = []
        var seen = Set<String>()

        for el in try doc.select("a.menu-list[href^=/service/board/]") {
            let href = try el.attr("href")
            let id = href.replacingOccurrences(of: "/service/board/", with: "")
                .components(separatedBy: "?").first ?? ""
            guard !id.isEmpty,
                  !seen.contains(id),
                  !Self.excludedIDs.contains(id)
            else { continue }
            let name = (try? el.select("span.menu_over").first()?.text())?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (try? el.attr("title")).flatMap { $0.isEmpty ? nil : $0 }
                ?? ""
            guard !name.isEmpty else { continue }
            seen.insert(id)
            let board = Board(
                id: "clien-\(id)",
                site: .clien,
                name: name,
                path: "/service/board/\(id)"
            )
            // `menu-list somoim` → 소모임; bare `menu-list` → 커뮤니티.
            let classAttr = (try? el.attr("class")) ?? ""
            if classAttr.contains("somoim") {
                somoim.append(board)
            } else {
                community.append(board)
            }
        }

        var groups: [BoardGroup] = []
        if !community.isEmpty {
            groups.append(BoardGroup(id: "community", name: "커뮤니티", boards: community))
        }
        if !somoim.isEmpty {
            groups.append(BoardGroup(id: "somoim", name: "소모임", boards: somoim))
        }
        return groups.isEmpty
            ? [BoardGroup(id: "clien", name: nil, boards: Board.boards(for: .clien))]
            : groups
    }
}

// MARK: - Coolenjoy

struct CoolenjoyCatalog: SiteCatalog {
    let site: Site = .coolenjoy

    func fetchGroups(html fetcher: @Sendable (URL, String.Encoding, String?) async throws -> String) async throws -> [BoardGroup] {
        // Any board page exposes the full side menu via `a.me-a` items.
        guard let url = URL(string: "https://coolenjoy.net/bbs/freeboard2") else {
            return [BoardGroup(id: "coolenjoy", name: nil, boards: Board.boards(for: .coolenjoy))]
        }
        let body = try await fetcher(url, .utf8, nil)
        let doc = try SwiftSoup.parse(body)

        var seen = Set<String>()
        var boards: [Board] = []
        for el in try doc.select("a.me-a[href*=/bbs/]") {
            let href = try el.attr("href")
            let trimmedHref = href.components(separatedBy: "?").first ?? href
            guard let bbsRange = trimmedHref.range(of: "/bbs/") else { continue }
            let id = String(trimmedHref[bbsRange.upperBound...])
                .components(separatedBy: "/").first ?? ""
            guard !id.isEmpty,
                  !id.contains(".php"),
                  !seen.contains(id)
            else { continue }
            let name = try el.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            seen.insert(id)
            boards.append(Board(
                id: "coolenjoy-\(id)",
                site: .coolenjoy,
                name: name,
                path: "/bbs/\(id)"
            ))
        }
        return [BoardGroup(
            id: "coolenjoy",
            name: nil,
            boards: boards.isEmpty ? Board.boards(for: .coolenjoy) : boards
        )]
    }
}

// MARK: - Ppomppu

struct PpomppuCatalog: SiteCatalog {
    let site: Site = .ppomppu

    /// Desktop home (`menu01` 뽐뿌, `menu04` 커뮤니티 sub-menus inline) +
    /// `/recent_forum_article.php` (`menu07` 포럼 list rendered server-side).
    private static let homeURL = URL(string: "https://www.ppomppu.co.kr/")!
    private static let forumURL = URL(string: "https://www.ppomppu.co.kr/recent_forum_article.php")!

    func fetchGroups(html fetcher: @Sendable (URL, String.Encoding, String?) async throws -> String) async throws -> [BoardGroup] {
        var seen = Set<String>()
        var deals: [Board] = []
        var community: [Board] = []
        var forum: [Board] = []

        // Desktop UA — `www.ppomppu.co.kr` serves a JS redirect to
        // `m.ppomppu.co.kr` whenever it sees a mobile UA. Routed through
        // the injected fetcher (third arg = UA override) so store-level
        // test fakes intercept these requests like every other catalog.
        let desktopUA = Networking.desktopUserAgent
        if let homeBody = try? await fetcher(Self.homeURL, site.encoding, desktopUA) {
            let doc = (try? SwiftSoup.parse(homeBody)) ?? Document("")
            if let elements = try? doc.select("li.menu01 a[href*=zboard]") {
                appendBoards(from: elements, into: &deals, seen: &seen)
            }
            if let elements = try? doc.select("li.menu04 a[href*=zboard]") {
                appendBoards(from: elements, into: &community, seen: &seen)
            }
        }

        if let forumBody = try? await fetcher(Self.forumURL, site.encoding, desktopUA) {
            let doc = (try? SwiftSoup.parse(forumBody)) ?? Document("")
            if let elements = try? doc.select("div.forum_ranking_box a[href*=zboard]") {
                appendBoards(from: elements, into: &forum, seen: &seen)
            }
        }

        var groups: [BoardGroup] = []
        if !deals.isEmpty { groups.append(BoardGroup(id: "deals", name: "뽐뿌", boards: deals)) }
        if !community.isEmpty { groups.append(BoardGroup(id: "community", name: "커뮤니티", boards: community)) }
        if !forum.isEmpty { groups.append(BoardGroup(id: "forum", name: "포럼", boards: forum)) }
        return groups.isEmpty
            ? [BoardGroup(id: "ppomppu", name: nil, boards: Board.boards(for: .ppomppu))]
            : groups
    }

    private func appendBoards(from elements: Elements, into boards: inout [Board], seen: inout Set<String>) {
        for el in elements {
            guard let href = try? el.attr("href"),
                  let id = Self.extractID(from: href),
                  !seen.contains(id)
            else { continue }
            let name = ((try? el.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count < 30 else { continue }
            seen.insert(id)
            boards.append(Board(
                id: "ppomppu-\(id)",
                site: .ppomppu,
                name: name,
                path: "/new/bbs_list.php?id=\(id)",
                searchQueryName: "keyword",
                pageQueryName: "page"
            ))
        }
    }

    /// Pull `id={value}` out of `…/zboard.php?id=ppomppu&page=1` style URLs.
    private static func extractID(from href: String) -> String? {
        guard let r = href.range(of: "id=") else { return nil }
        let tail = href[r.upperBound...]
        let id = tail.prefix { ch in
            ch.isLetter || ch.isNumber || ch == "_"
        }
        return id.isEmpty ? nil : String(id)
    }
}
