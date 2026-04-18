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
            .foregroundStyle(info.textColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(info.color, in: Capsule())
            .accessibilityLabel("출처 \(info.label)")
    }

    struct Info {
        let label: String
        let color: Color
        let textColor: Color
    }

    static func info(for code: String) -> Info {
        switch code.lowercased() {
        case "clien":   return entry("끌량",   0x3D4881)
        case "ou":      return entry("오유",   0x4D6C77)
        case "slrclub": return entry("SLR",    0x438EDD)
        case "ppomppu": return entry("뽐뿌",   0xA5A5A5)
        case "mlbpark": return entry("엠팍",   0xFE5E00)
        case "82cook":  return entry("82쿡",   0x37832D)
        case "bobae":   return entry("보배",   0x4588CE)
        case "ruli":    return entry("루리",   0x0861B6)
        case "inven":   return entry("인벤",   0xBF0404)
        case "humor":   return entry("웃대",   0xED1746)
        case "ddanzi":  return entry("딴지",   0xDECDAF)
        case "fmkorea": return entry("에펨",   0x5176CF)
        case "etoland": return entry("이토",   0x72CA47)
        case "damoang": return entry("다뫙",   0x383838)
        case "beti":    return entry("베티",   0xBBCAE7)
        case "instiz":  return entry("인스티즈", 0x28C05E)
        case "dealbada": return entry("딜바다", 0xC6D0E1)
        case "quasar":  return entry("퀘이사", 0xFF9900)
        case "cnjoy", "coolenjoy": return entry("쿨엔", 0x696969)
        case "eomisae": return entry("어미새", 0xF44336)
        default:        return Info(label: code, color: .gray, textColor: .white)
        }
    }

    /// Build (label, color, textColor) once from the literal sRGB hex —
    /// `textColor` is computed via W3C luminance so we never need a UIColor
    /// round-trip (which can lose precision on dynamic / wide-gamut colors).
    private static func entry(_ label: String, _ rgb: UInt32) -> Info {
        let r = Double((rgb >> 16) & 0xff) / 255.0
        let g = Double((rgb >> 8) & 0xff) / 255.0
        let b = Double(rgb & 0xff) / 255.0
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        return Info(
            label: label,
            color: Color(red: r, green: g, blue: b),
            textColor: lum > 0.6 ? .black : .white
        )
    }
}
