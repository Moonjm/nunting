import Foundation

enum Site: String, CaseIterable, Identifiable, Codable {
    case clien
    case coolenjoy
    case inven
    case ppomppu
    case aagag

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clien: "클리앙"
        case .coolenjoy: "쿨엔조이"
        case .inven: "인벤"
        case .ppomppu: "뽐뿌"
        case .aagag: "애객"
        }
    }

    var baseURL: URL {
        switch self {
        case .clien: URL(string: "https://www.clien.net")!
        case .coolenjoy: URL(string: "https://coolenjoy.net")!
        case .inven: URL(string: "https://www.inven.co.kr")!
        case .ppomppu: URL(string: "https://m.ppomppu.co.kr")!
        case .aagag: URL(string: "https://aagag.com")!
        }
    }

    var encoding: String.Encoding {
        switch self {
        case .ppomppu:
            // Server advertises EUC-KR but actually serves CP949 (Windows-949), which is a superset.
            // Decoding strictly as EUC-KR fails on extended characters.
            let cf = CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        default:
            return .utf8
        }
    }

    /// Best-effort site detection from a URL host. Used when resolving aagag mirror
    /// redirects so we can dispatch to the source site's parser.
    static func detect(host: String?) -> Site? {
        guard let host = host?.lowercased() else { return nil }
        if host.hasSuffix("clien.net") { return .clien }
        if host.hasSuffix("coolenjoy.net") { return .coolenjoy }
        if host.hasSuffix("inven.co.kr") { return .inven }
        if host.hasSuffix("ppomppu.co.kr") { return .ppomppu }
        if host.hasSuffix("aagag.com") { return .aagag }
        return nil
    }
}
