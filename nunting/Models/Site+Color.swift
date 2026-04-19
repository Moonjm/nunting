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
        case .slr: Color(red: 0x43/255.0, green: 0x8E/255.0, blue: 0xDD/255.0)
        case .ddanzi: Color(red: 0xDE/255.0, green: 0xCD/255.0, blue: 0xAF/255.0)
        case .cook82: Color(red: 0x37/255.0, green: 0x83/255.0, blue: 0x2D/255.0)
        }
    }
}
