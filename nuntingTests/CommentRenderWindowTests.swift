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

    /// 새로고침으로 댓글이 늘면 그만큼 더 볼 수 있어야 한다.
    ///
    /// 회귀: 창이 이미 끝까지 열린 상태(그린 개수 == 전체)에서는 센티넬의
    /// 가시성 값이 이미 true 라 변하지 않는다. `onGeometryChange` 는 값이
    /// **바뀔 때만** 액션을 부르므로 성장이 다시 촉발되지 않고, 새로 받은
    /// 뒷부분이 영영 안 보인다 — 성능이 아니라 데이터 유실이다.
    func testRefreshedCommentsBeyondTheWindowBecomeReachable() throws {
        let initial = comments(40)
        let host = UIHostingController(
            rootView: RefreshHarness(comments: initial)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        settle(host.view)

        // 끝까지 스크롤해 창을 전부 연다(40개 < 창+청크라 전부 그려진다).
        let scroll = try XCTUnwrap(Self.firstScrollView(host.view))
        scroll.contentOffset = CGPoint(
            x: 0,
            y: max(0, scroll.contentSize.height - scroll.bounds.height)
        )
        host.view.layoutIfNeeded()
        settle(host.view)
        XCTAssertEqual(Self.countTextViews(host.view), initial.count,
                       "전제: 40개는 전부 그려져 있어야 한다")

        // 새로고침으로 댓글이 두 배가 됐다.
        host.rootView = RefreshHarness(comments: comments(80))
        host.view.layoutIfNeeded()
        settle(host.view)

        // 콘텐츠 높이가 아니라 **그려진 행 수**로 본다 — 높이는 마지막 행에
        // 구분선이 하나 붙는 것만으로도 늘어나(전체 개수가 커졌으므로)
        // 실제로는 아무것도 더 안 그려졌는데 통과한다(처음 이 테스트가 그랬다).
        XCTAssertGreaterThan(
            Self.countTextViews(host.view), initial.count,
            "새로고침으로 늘어난 댓글이 영영 가려졌다"
        )
    }

    /// 같은 유실인데 위 테스트가 못 잡는 경우: 그린 구간이 **청크 경계에 딱
    /// 맞는** 새로고침(30→60, 50→80 …).
    ///
    /// 40→80 은 그리는 개수가 40 에서 50 으로 늘며 인덱스 40 에 센티넬이 새로
    /// 생기고, 그 센티넬은 지오메트리를 처음 계산하므로 사슬이 스스로 이어진다.
    /// 반면 30 개를 다 그린 상태에서 60 개가 되면 그리는 구간(0..<30)이 그대로라
    /// 센티넬 집합도 그대로고, 이미 true 인 가시성 값은 변하지 않는다.
    /// `onGeometryChange` 는 값이 바뀔 때만 액션을 부르므로 성장이 영영 안 돈다.
    func testRefreshAtAChunkBoundaryStillOpensTheWindow() throws {
        let host = UIHostingController(rootView: RefreshHarness(comments: comments(30)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        settle(host.view)

        // 끝까지 내려간다 — 센티넬(인덱스 20)이 "여기까지 왔다" 를 보고하지만
        // 이 시점엔 그린 개수 == 전체라 성장 자격이 없다.
        let scroll = try XCTUnwrap(Self.firstScrollView(host.view))
        scroll.contentOffset = CGPoint(
            x: 0,
            y: max(0, scroll.contentSize.height - scroll.bounds.height)
        )
        host.view.layoutIfNeeded()
        settle(host.view)
        XCTAssertEqual(Self.countTextViews(host.view), 30,
                       "전제: 30개는 전부 그려져 있어야 한다")

        host.rootView = RefreshHarness(comments: comments(60))
        host.view.layoutIfNeeded()
        settle(host.view)

        XCTAssertGreaterThan(
            Self.countTextViews(host.view), 30,
            "청크 경계에서 새로고침하니 늘어난 댓글이 영영 가려졌다"
        )
    }

    /// 댓글 배열만 갈아끼우는 하네스 — 새로고침 재현용.
    private struct RefreshHarness: View {
        let comments: [PostComment]
        var body: some View {
            ScrollView {
                PostDetailCommentsSection(
                    comments: comments,
                    onImageTap: { _ in },
                    onVideoDismissBegin: {}
                )
            }
        }
    }

    /// 새로고침으로 **전체 수만** 바뀌어도 진단 프로브가 따라가야 한다.
    /// 그린 수만 관찰하면 창이 아직 안 자란 사이의 백드래그가 "comments 30/40"
    /// 처럼 옛 총수로 올라가, 히치와 댓글 수의 상관을 보려고 넣은 값이 오히려
    /// 오답을 준다.
    func testProbeFollowsTheRefreshedTotal() throws {
        let host = UIHostingController(rootView: RefreshHarness(comments: comments(40)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        settle(host.view)
        XCTAssertEqual(CommentRenderProbe.shared.total, 40)

        host.rootView = RefreshHarness(comments: comments(80))
        host.view.layoutIfNeeded()
        settle(host.view)

        XCTAssertEqual(CommentRenderProbe.shared.total, 80,
                       "새로고침으로 늘어난 총수를 프로브가 못 따라갔다")
    }

    // MARK: - 창 규칙

    func testClampNeverGoesBelowInitialOrAboveTotal() {
        XCTAssertEqual(CommentRenderWindow.clamped(0, total: 500), CommentRenderWindow.initialCount)
        XCTAssertEqual(CommentRenderWindow.clamped(120, total: 500), 120)
        XCTAssertEqual(CommentRenderWindow.clamped(600, total: 500), 500)
        // 새로고침으로 댓글이 창보다 적게 줄어든 경우.
        XCTAssertEqual(CommentRenderWindow.clamped(120, total: 5), 5)
    }

    /// 성장은 단조 증가하고, **그리는 개수**는 전체에서 멈춘다.
    /// (상태 자체는 자르지 않는다 — 아래 정렬 불변식 참고.)
    func testGrowthIsMonotonicAndRenderStopsAtTotal() {
        let total = 137
        var state = CommentRenderWindow.initialCount
        var steps = 0
        while CommentRenderWindow.clamped(state, total: total) < total {
            let next = CommentRenderWindow.grown(from: state)
            XCTAssertGreaterThan(next, state, "성장이 진행되지 않는다")
            state = next
            steps += 1
            XCTAssertLessThan(steps, 100, "성장이 수렴하지 않는다")
        }
        XCTAssertEqual(CommentRenderWindow.clamped(state, total: total), total)
    }

    /// **정렬 불변식**: 어떤 성장 단계에서도 "창 끝에서 마진만큼 앞" 지점에
    /// 센티넬이 정확히 놓여야 한다. 이게 깨지면 다음 청크를 촉발할 센티넬이
    /// 없어 성장 사슬이 조용히 끊긴다(그 상태로 남은 댓글은 영영 안 보인다).
    /// 상태를 전체 개수로 잘라 저장하면 바로 이게 깨졌다.
    func testEveryGrowthStepKeepsASentinelAtTheTriggerPoint() {
        var state = CommentRenderWindow.initialCount
        for _ in 0..<10 {
            XCTAssertTrue(
                CommentRenderWindow.hasSentinel(after: state - CommentRenderWindow.growthMargin),
                "창 \(state) 에서 촉발 지점(\(state - CommentRenderWindow.growthMargin))에 센티넬이 없다"
            )
            state = CommentRenderWindow.grown(from: state)
        }
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
        let grown = CommentRenderWindow.grown(from: initial)

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
