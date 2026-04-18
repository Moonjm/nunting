import Foundation

enum ParserFactory {
    static func parser(for site: Site) throws -> BoardParser {
        switch site {
        case .clien: return ClienParser()
        case .coolenjoy: return CoolenjoyParser()
        case .inven, .ppomppu:
            throw ParserError.unsupportedSite(site)
        }
    }
}
