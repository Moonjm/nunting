import SwiftUI

extension Site {
    var accentColor: Color {
        switch self {
        case .clien: .blue
        case .coolenjoy: .orange
        case .inven: .red
        case .ppomppu: .green
        case .aagag: .purple
        case .humor: .pink
        case .bobae: Color(red: 0x45/255.0, green: 0x88/255.0, blue: 0xCE/255.0)
        }
    }
}
