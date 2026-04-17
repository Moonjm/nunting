import Foundation

enum ParserFactory {
    static func parser(for site: Site) throws -> BoardParser {
        switch site {
        case .clien: return ClienParser()
        case .coolenjoy, .inven, .ppomppu:
            throw ParserError.unsupportedSite(site)
        }
    }
}
