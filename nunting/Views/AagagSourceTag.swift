import SwiftUI

/// Color-coded badge for the source-site label that aagag's mirror page tags
/// each row with (e.g. `bc_ppomppu` → "뽐뿌"). Colors and labels mirror aagag's
/// own CSS so the visual feel matches the upstream site.
struct AagagSourceTag: View {
    let code: String

    var body: some View {
        let info = Self.info(for: code)
        Text(info.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Self.textColor(on: info.color))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(info.color, in: Capsule())
            .accessibilityLabel("출처 \(info.label)")
    }

    static func info(for code: String) -> (label: String, color: Color) {
        switch code.lowercased() {
        case "clien":   return ("끌량", hex(0x3D4881))
        case "ou":      return ("오유", hex(0x4D6C77))
        case "slrclub": return ("SLR",  hex(0x438EDD))
        case "ppomppu": return ("뽐뿌", hex(0xA5A5A5))
        case "mlbpark": return ("엠팍", hex(0xFE5E00))
        case "82cook":  return ("82쿡", hex(0x37832D))
        case "bobae":   return ("보배", hex(0x4588CE))
        case "ruli":    return ("루리", hex(0x0861B6))
        case "inven":   return ("인벤", hex(0xBF0404))
        case "humor":   return ("웃대", hex(0xED1746))
        case "ddanzi":  return ("딴지", hex(0xDECDAF))
        case "fmkorea": return ("에펨", hex(0x5176CF))
        case "etoland": return ("이토", hex(0x72CA47))
        case "damoang": return ("다뫙", hex(0x383838))
        case "beti":    return ("베티", hex(0xBBCAE7))
        case "instiz":  return ("인스티즈", hex(0x28C05E))
        case "dealbada": return ("딜바다", hex(0xC6D0E1))
        case "quasar":  return ("퀘이사", hex(0xFF9900))
        case "cnjoy", "coolenjoy": return ("쿨엔", hex(0x696969))
        case "eomisae": return ("어미새", hex(0xF44336))
        default:        return (code, .gray)
        }
    }

    private static func hex(_ v: UInt32) -> Color {
        let r = Double((v >> 16) & 0xff) / 255.0
        let g = Double((v >> 8) & 0xff) / 255.0
        let b = Double(v & 0xff) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    /// Pick black on bright backgrounds, white on dark backgrounds (W3C luminance).
    private static func textColor(on color: Color) -> Color {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.6 ? .black : .white
    }
}
