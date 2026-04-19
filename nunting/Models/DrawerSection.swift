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
        }
    }

    /// Sites browseable from the side drawer. Excludes `.humor`, which is a
    /// dispatch-only target used from aagag mirror detail pages.
    static let all: [DrawerSection] = [.favorites]
        + Site.allCases.filter { $0 != .humor }.map(DrawerSection.site)
}
