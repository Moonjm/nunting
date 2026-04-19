import Foundation

enum DrawerSection: Hashable, Identifiable {
    case favorites
    case site(Site)

    var id: String {
        switch self {
        case .favorites: "favorites"
        case .site(let s): "site-\(s.rawValue)"
        }
    }

    var label: String {
        switch self {
        case .favorites: "모음"
        case .site(let s): s.displayName
        }
    }

    var shortLabel: String {
        switch self {
        case .favorites: "모음"
        case .site(.clien): "클량"
        case .site(.coolenjoy): "쿨엔"
        case .site(.inven): "인벤"
        case .site(.ppomppu): "뽐뿌"
        case .site(.aagag): "애객"
        case .site(.humor): "웃대"
        case .site(.bobae): "보배"
        case .site(.slr): "SLR"
        case .site(.ddanzi): "딴지"
        }
    }

    /// Sites that are dispatch-only targets (reached via aagag mirror
    /// redirects) and shouldn't appear in the drawer as browseable entries.
    private static let dispatchOnly: Set<Site> = [.humor, .bobae, .slr, .ddanzi]

    /// Sites browseable from the side drawer. Dispatch-only targets stay
    /// hidden so the drawer only lists sites the user can actually browse.
    static let all: [DrawerSection] = [.favorites]
        + Site.allCases.filter { !dispatchOnly.contains($0) }.map(DrawerSection.site)
}
