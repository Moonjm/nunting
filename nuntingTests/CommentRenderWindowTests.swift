import XCTest
import SwiftUI
@testable import nunting

/// 댓글 목록 점진 렌더(`CommentRenderWindow`)의 계약.
///
/// 회귀 대상 둘:
///  1) 진입 비용 — eager VStack 은 화면 밖 행까지 즉시 실체화해 비용이 댓글
///     수에 정비례했다(계측: 1개당 6.1ms, 400개 2.46s 메인스레드 블록).
///     창(window)이 그 항을 상수로 묶는다.
///  2) #160 의 스크롤 튐 — 창은 **늘어나기만** 해야 한다. 한 번 그린 행이
///     사라졌다 되돌아오면 높이 복원 실패로 오프셋이 뒤로 끌린다.
@MainActor
final class CommentRenderWindowTests: XCTestCase {

    private func comments(_ n: Int) -> [PostComment] {
        (0..<n).map { i in
            PostComment(
                id: "c\(i)",
                author: "닉네임\(i % 37)",
                dateText: "07-30 21:1\(i % 10)",
                content: "적당한 길이의 댓글 본문 \(i) — 두 줄쯤 나오도록 한국어로 채운 문장입니다.",
                likeCount: i % 5,
                isReply: i % 3 == 0
            )
        }
    }

    private static func countTextViews(_ view: UIView) -> Int {
        var count = view is UITextView ? 1 : 0
        for sub in view.subviews { count += countTextViews(sub) }
        return count
    }

    private static func firstScrollView(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(sub) { return found }
        }
        return nil
    }

    /// 실제 조건과 같게 — 댓글 섹션을 ScrollView 안에 넣고 852pt 뷰포트를 가진
    /// 창에 띄운다. 성장 트리거는 스크롤 뷰의 가시 영역을 기준으로 판정하므로
    /// ScrollView 없이 재면(가시 영역 없음) 계약이 그대로 검증되지 않는다.
    private func hostInScrollView(_ comments: [PostComment]) -> UIHostingController<some View> {
        let host = UIHostingController(
            rootView: ScrollView {
                PostDetailCommentsSection(
                    comments: comments,
                    onImageTap: { _ in },
                    onVideoDismissBegin: {}
                )
            }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        settle(host.view)
        return host
    }

    /// SwiftUI 의 지오메트리 콜백 → 상태 변경 → 재레이아웃이 돌 시간을 준다.
    /// 콜백이 상태를 바꾸면 그 결과를 UIKit 이 실체화하려면 레이아웃 패스가
    /// 한 번 더 필요하므로, 런루프와 레이아웃을 번갈아 돌린다.
    private func settle(_ view: UIView? = nil, turns: Int = 4) {
        for _ in 0..<turns {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            // 호스팅 컨트롤러는 화면에 실제로 붙어 있지 않으면 디스플레이
            // 사이클을 안 받는다 — 대기 중인 SwiftUI 업데이트를 직접 커밋시킨다.
            CATransaction.flush()
            view?.setNeedsLayout()
            view?.layoutIfNeeded()
        }
    }

    // MARK: - 진입 비용

    /// 댓글이 아무리 많아도 진입 시 실체화되는 행은 창 크기까지다. UITextView
    /// 개수가 곧 지불한 TextKit 레이아웃 수라 진입 비용의 직접 대리 지표다.
    func testInitialRenderIsBoundedRegardlessOfCommentCount() {
        for total in [200, 400] {
            let host = hostInScrollView(comments(total))
            XCTAssertEqual(
                Self.countTextViews(host.view),
                CommentRenderWindow.initialCount,
                "댓글 \(total)개 진입 시 창 크기를 넘는 행이 실체화됐다"
            )
        }
    }

    /// 댓글이 창보다 적으면 전부 그린다(자르지 않는다).
    func testShortThreadRendersEveryComment() {
        let total = 7
        let host = hostInScrollView(comments(total))
        XCTAssertEqual(Self.countTextViews(host.view), total)
    }

    /// 끝까지 스크롤하면 다음 청크가 실제로 붙는다 — 창이 열리지 않으면
    /// 댓글이 잘린 채로 끝나 버린다.
    func testScrollingToTheEndGrowsTheWindow() throws {
        let host = hostInScrollView(comments(200))
        let scroll = try XCTUnwrap(Self.firstScrollView(host.view))
        XCTAssertEqual(Self.countTextViews(host.view), CommentRenderWindow.initialCount)

        // 창이 늘었는지는 콘텐츠 높이로 본다. UITextView 실체화는 호스팅
        // 컨트롤러의 다음 커밋 타이밍에 달려 있어 테스트 런루프에서 시점이
        // 불안정하지만, 콘텐츠 높이는 SwiftUI 레이아웃이 끝나면 곧바로 반영된다.
        let heightBefore = scroll.contentSize.height
        scroll.contentOffset = CGPoint(
            x: 0,
            y: max(0, heightBefore - scroll.bounds.height)
        )
        host.view.layoutIfNeeded()
        settle(host.view)

        XCTAssertGreaterThan(
            scroll.contentSize.height,
            heightBefore,
            "끝까지 스크롤했는데 창이 늘지 않았다"
        )
    }

    // MARK: - 창 규칙

    func testClampNeverGoesBelowInitialOrAboveTotal() {
        XCTAssertEqual(CommentRenderWindow.clamped(0, total: 500), CommentRenderWindow.initialCount)
        XCTAssertEqual(CommentRenderWindow.clamped(120, total: 500), 120)
        XCTAssertEqual(CommentRenderWindow.clamped(600, total: 500), 500)
        // 새로고침으로 댓글이 창보다 적게 줄어든 경우.
        XCTAssertEqual(CommentRenderWindow.clamped(120, total: 5), 5)
    }

    /// 성장은 단조 증가하고 전체 개수에서 멈춘다.
    func testGrowthIsMonotonicAndStopsAtTotal() {
        let total = 137
        var count = CommentRenderWindow.initialCount
        var steps = 0
        while count < total {
            let next = CommentRenderWindow.grown(from: count, total: total)
            XCTAssertGreaterThan(next, count, "성장이 진행되지 않으면 끝에서 멈춘다")
            count = next
            steps += 1
            XCTAssertLessThan(steps, 100, "성장이 수렴하지 않는다")
        }
        XCTAssertEqual(count, total)
        // 끝에 닿은 뒤로는 더 늘지 않는다.
        XCTAssertEqual(CommentRenderWindow.grown(from: count, total: total), total)
    }

    /// 센티넬은 창 끝보다 `growthMargin` 앞에 놓여, 사용자가 실제 끝에 닿기
    /// 전에 다음 청크가 붙는다.
    func testFirstSentinelSitsAheadOfTheWindowEnd() {
        let firstSentinel = (0..<CommentRenderWindow.initialCount)
            .first { CommentRenderWindow.hasSentinel(after: $0) }
        XCTAssertEqual(
            firstSentinel,
            CommentRenderWindow.initialCount - CommentRenderWindow.growthMargin
        )
    }

    /// 센티넬 간격은 청크 크기와 같아야 한다 — 그래야 성장할 때마다 트리거
    /// 지점이 항상 새 끝에서 `growthMargin` 만큼 앞에 놓인다. 간격이 청크와
    /// 어긋나면 트리거가 창 끝을 지나쳐 빈 구간이 보이거나, 필요 이상으로
    /// 이른 지점에서 붙는다.
    func testSentinelsAreOneChunkApart() {
        let sentinels = (0..<300).filter { CommentRenderWindow.hasSentinel(after: $0) }
        XCTAssertGreaterThan(sentinels.count, 3)
        for (a, b) in zip(sentinels, sentinels.dropFirst()) {
            XCTAssertEqual(b - a, CommentRenderWindow.chunkSize)
        }
    }

    /// 위쪽에 남아 있는 과거 센티넬은 다시 화면에 들어와도 성장시키지 않는다
    /// — 뒤로 스크롤할 때마다 청크가 붙어버리면 창이 의미를 잃는다.
    func testStaleSentinelsDoNotTriggerGrowth() {
        let rendered = 120
        let total = 400
        XCTAssertFalse(
            CommentRenderWindow.shouldGrow(sentinelAfter: 18, rendered: rendered, total: total),
            "창 한참 위의 센티넬이 성장을 촉발했다"
        )
        XCTAssertTrue(
            CommentRenderWindow.shouldGrow(
                sentinelAfter: rendered - CommentRenderWindow.growthMargin,
                rendered: rendered,
                total: total
            )
        )
    }

    /// 다 그린 뒤에는 어떤 센티넬도 성장시키지 않는다.
    func testNoGrowthOnceEverythingIsRendered() {
        XCTAssertFalse(
            CommentRenderWindow.shouldGrow(sentinelAfter: 90, rendered: 100, total: 100)
        )
    }

    // MARK: - 추가만 한다(#160 회귀 가드)

    /// 창이 커져도 이미 그려진 행의 레이아웃은 1pt 도 변하지 않아야 한다.
    /// 앞 `initialCount` 개만 그린 목록의 높이와, 더 많이 그린 목록에서 같은
    /// 구간이 차지하는 높이가 같은지로 확인한다(구분선 포함 — 마지막 행에도
    /// 구분선을 남겨 둔 이유가 이것이다).
    func testGrowingTheWindowDoesNotResizeAlreadyRenderedRows() {
        let all = comments(200)
        let initial = CommentRenderWindow.initialCount
        let grown = CommentRenderWindow.grown(from: initial, total: all.count)

        let before = hostedHeight(of: Array(all.prefix(initial)))
        let after = hostedHeight(of: Array(all.prefix(grown)))
        let addedRows = hostedHeight(of: Array(all[initial..<grown]))

        // 늘어난 높이가 "새로 붙은 행들의 높이" 와 정확히 같다 = 기존 행 구간의
        // 높이가 변하지 않았다는 뜻. 한 pt 라도 다르면 위쪽 콘텐츠가 움직였고,
        // 그게 #160 의 스크롤 튐이다.
        XCTAssertEqual(after - before, addedRows, accuracy: 1.0)
    }

    /// 같은 행 구성(마지막 행에도 구분선)으로 높이만 잰다.
    private func hostedHeight(of rows: [PostComment]) -> CGFloat {
        let view = VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { comment in
                PostDetailCommentRow(
                    comment: comment,
                    onImageTap: { _ in },
                    onVideoDismissBegin: {}
                )
                Divider().padding(.vertical, 2)
            }
        }
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: 393, height: CGFloat.greatestFiniteMagnitude)).height
    }
}
