import Foundation

enum Site: String, CaseIterable, Identifiable, Codable {
    case clien
    case coolenjoy
    case inven
    case ppomppu
    case aagag
    /// Aagag mirror-only target (no direct browsing). Added so `Site.detect`
    /// can route humoruniv.com redirects to `HumorParser`.
    case humor
    /// Aagag mirror-only target. Routes bobaedream.co.kr redirects to `BobaeParser`.
    case bobae
    /// Aagag mirror-only target. Routes slrclub.com redirects to `SLRParser`.
    case slr
    /// Aagag mirror-only target. Routes ddanzi.com redirects to `DdanziParser`.
    case ddanzi
    /// Aagag mirror-only target. Routes 82cook.com redirects to `Cook82Parser`.
    /// Swift enum cases can't start with a digit, so we flip the numeric prefix.
    case cook82

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .clien: "클리앙"
        case .coolenjoy: "쿨엔조이"
        case .inven: "인벤"
        case .ppomppu: "뽐뿌"
        case .aagag: "애객"
        case .humor: "웃대"
        case .bobae: "보배드림"
        case .slr: "SLR클럽"
        case .ddanzi: "딴지일보"
        case .cook82: "82쿡"
        }
    }

    nonisolated var baseURL: URL {
        switch self {
        case .clien: URL(string: "https://www.clien.net")!
        case .coolenjoy: URL(string: "https://coolenjoy.net")!
        case .inven: URL(string: "https://m.inven.co.kr")!
        case .ppomppu: URL(string: "https://m.ppomppu.co.kr")!
        case .aagag: URL(string: "https://aagag.com")!
        case .humor: URL(string: "https://m.humoruniv.com")!
        case .bobae: URL(string: "https://m.bobaedream.co.kr")!
        case .slr: URL(string: "https://m.slrclub.com")!
        case .ddanzi: URL(string: "https://www.ddanzi.com")!
        case .cook82: URL(string: "https://www.82cook.com")!
        }
    }

    nonisolated var encoding: String.Encoding {
        switch self {
        case .ppomppu, .humor:
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
    nonisolated static func detect(host: String?) -> Site? {
        guard let host = host?.lowercased() else { return nil }
        if host.hasSuffix("clien.net") { return .clien }
        if host.hasSuffix("coolenjoy.net") { return .coolenjoy }
        if host.hasSuffix("inven.co.kr") { return .inven }
        if host.hasSuffix("ppomppu.co.kr") { return .ppomppu }
        if host.hasSuffix("aagag.com") { return .aagag }
        if host.hasSuffix("humoruniv.com") { return .humor }
        if host.hasSuffix("bobaedream.co.kr") { return .bobae }
        if host.hasSuffix("slrclub.com") { return .slr }
        if host.hasSuffix("ddanzi.com") { return .ddanzi }
        if host.hasSuffix("82cook.com") { return .cook82 }
        return nil
    }
}
