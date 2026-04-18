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
        case .site(.clien): "클앙"
        case .site(.coolenjoy): "쿨엔"
        case .site(.inven): "인벤"
        case .site(.ppomppu): "뽐뿌"
        }
    }

    static let all: [DrawerSection] = [.favorites] + Site.allCases.map(DrawerSection.site)
}
