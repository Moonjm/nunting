import SwiftUI

extension Site {
    var accentColor: Color {
        switch self {
        case .clien: .blue
        case .coolenjoy: .orange
        case .inven: .red
        case .ppomppu: .green
        }
    }
}
