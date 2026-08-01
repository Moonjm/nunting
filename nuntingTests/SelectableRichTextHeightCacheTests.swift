import XCTest
import SwiftUI
import UIKit
@testable import nunting

/// 텍스트 높이 측정 캐시의 계약.
///
/// 왜: 기기 정체 스택이 SwiftUI 레이아웃 패스 → `SelectableRichText.sizeThatFits`
/// → TextKit 측정에서 175ms 를 잡았다(댓글 159행). 드래그 중 레이아웃이 한 번만
/// 돌아도 그려진 행 전부를 다시 재는데, 내용이 그대로면 잴 필요가 없다.
/// 다만 틀린 높이를 돌려주면 행이 잘리거나 겹치므로 무효화 조건이 계약이다.
@MainActor
final class SelectableRichTextHeightCacheTests: XCTestCase {

    private let font = UIFont.preferredFont(forTextStyle: .subheadline)

    private func measuredHeight(
        _ text: AttributedString,
        width: CGFloat = 361,
        font: UIFont? = nil
    ) -> CGFloat? {
        let view = SelectableRichText(attributedString: text, font: font ?? self.font)
        let host = UIHostingController(rootView: view.frame(width: width))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    override func setUp() async throws {
        try await super.setUp()
        SelectableRichText.resetHeightCacheForTesting()
    }

    /// 캐시가 있든 없든 같은 높이를 돌려줘야 한다 — 이게 깨지면 행이 잘린다.
    func testCachedHeightMatchesFreshMeasurement() throws {
        let text = AttributedString("두 줄쯤 나오도록 적당히 긴 한국어 댓글 본문입니다. 링크도 하나 https://example.com 섞습니다.")
        let fresh = try XCTUnwrap(measuredHeight(text))
        let cached = try XCTUnwrap(measuredHeight(text))
        XCTAssertEqual(cached, fresh, accuracy: 0.5)
    }

    /// 폭이 바뀌면 다시 재야 한다 — 좁아지면 줄이 늘어난다.
    func testNarrowerWidthProducesTallerText() throws {
        let text = AttributedString("폭에 따라 줄 수가 달라지는 충분히 긴 한국어 문장을 여기에 둡니다. 한 번 더 반복해서 길이를 확보합니다.")
        let wide = try XCTUnwrap(measuredHeight(text, width: 361))
        let narrow = try XCTUnwrap(measuredHeight(text, width: 180))
        XCTAssertGreaterThan(narrow, wide, "폭이 좁아졌는데 높이가 그대로다 — 캐시가 폭을 무시했다")
    }

    /// 폰트(= Dynamic Type)가 바뀌면 다시 재야 한다.
    func testLargerFontProducesTallerText() throws {
        let text = AttributedString("글자 크기에 따라 높이가 달라지는 문장입니다.")
        let small = try XCTUnwrap(measuredHeight(text, font: .preferredFont(forTextStyle: .caption1)))
        let large = try XCTUnwrap(measuredHeight(text, font: .preferredFont(forTextStyle: .largeTitle)))
        XCTAssertGreaterThan(large, small, "폰트가 커졌는데 높이가 그대로다 — 캐시가 폰트를 무시했다")
    }

    /// 내용이 다르면 당연히 다른 높이 — 캐시가 서로 다른 댓글을 섞지 않는다.
    func testDifferentTextIsNotConflated() throws {
        let short = try XCTUnwrap(measuredHeight(AttributedString("한 줄")))
        let long = try XCTUnwrap(measuredHeight(
            AttributedString("여러 줄이 되도록 아주 길게 늘여 쓴 문장입니다. " +
                             "충분히 길어야 하므로 같은 문장을 한 번 더 반복합니다. " +
                             "그리고 한 번 더 반복해 확실히 줄을 넘깁니다.")
        ))
        XCTAssertGreaterThan(long, short)
    }
}
