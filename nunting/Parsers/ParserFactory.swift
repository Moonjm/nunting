import Foundation

enum ParserFactory {
    nonisolated static func parser(for site: Site) throws -> BoardParser {
        switch site {
        case .clien: return ClienParser()
        case .coolenjoy: return CoolenjoyParser()
        case .inven: return InvenParser()
        case .ppomppu: return PpomppuParser()
        case .aagag: return AagagParser()
        case .humor: return HumorParser()
        case .bobae: return BobaeParser()
        case .slr: return SLRParser()
        case .ddanzi: return DdanziParser()
        }
    }
}
