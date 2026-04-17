import SwiftUI

struct SiteBadge: View {
    let site: Site

    var body: some View {
        Text(site.displayName)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(site.badgeColor, in: Capsule())
    }
}

extension Site {
    var badgeColor: Color {
        switch self {
        case .clien: .blue
        case .coolenjoy: .orange
        case .inven: .red
        case .ppomppu: .green
        }
    }
}
