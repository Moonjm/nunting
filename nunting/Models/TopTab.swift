import Foundation

enum TopTab: Hashable, Identifiable {
    case site(Site)
    case favorites

    var id: String {
        switch self {
        case .site(let s): "site-\(s.rawValue)"
        case .favorites: "favorites"
        }
    }

    var displayName: String {
        switch self {
        case .site(let s): s.displayName
        case .favorites: "모음"
        }
    }

    static let all: [TopTab] = Site.allCases.map(TopTab.site) + [.favorites]
}
