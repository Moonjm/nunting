import Foundation

enum Site: String, CaseIterable, Identifiable, Codable {
    case clien
    case coolenjoy
    case inven
    case ppomppu

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clien: "클리앙"
        case .coolenjoy: "쿨엔조이"
        case .inven: "인벤"
        case .ppomppu: "뽐뿌"
        }
    }

    var baseURL: URL {
        switch self {
        case .clien: URL(string: "https://www.clien.net")!
        case .coolenjoy: URL(string: "https://coolenjoy.net")!
        case .inven: URL(string: "https://www.inven.co.kr")!
        case .ppomppu: URL(string: "https://m.ppomppu.co.kr")!
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
}
