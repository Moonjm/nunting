import XCTest
import SwiftUI
@testable import nunting

/// 댓글 비디오 슬롯의 레이아웃 계약.
///
/// 회귀 대상: 댓글 mp4 의 종횡비는 AVAsset 메타데이터가 도착해야 알 수 있는데,
/// 그 값이 슬롯 높이를 바꾸면 뷰포트 위쪽 행이 늘었다 줄었다 하면서 스크롤이
/// 튄다. 실측(humoruniv pds#1419395 댓글 영상 500×786 기준):
///   16:9 기본값 180pt → 실제 비율 240pt (행마다 +60pt 이동)
/// 슬롯은 비율과 무관하게 항상 같은 높이를 차지해야 한다.
@MainActor
final class CommentVideoSlotTests: XCTestCase {

    private func hostedHeight<V: View>(_ view: V, width: CGFloat = 393) -> CGFloat {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    /// 플레이어 자리에 같은 레이아웃 특성(폭 채우기 + 비율 맞춤)의 대역을 넣어
    /// 슬롯만 측정한다 — 실제 AVPlayer 를 띄우지 않고 레이아웃 계약만 검증.
    private func slotHeight(aspect: CGFloat) -> CGFloat {
        hostedHeight(
            PostDetailCommentRow.videoSlot {
                Color.black
                    .frame(maxWidth: .infinity)
                    .aspectRatio(aspect, contentMode: .fit)
            }
        )
    }

    func testSlotHeightIsConstantAcrossAspects() {
        let landscape = slotHeight(aspect: 16.0 / 9.0)                        // 메타데이터 도착 전 기본 예약
        let portrait = slotHeight(aspect: 500.0 / 786.0)                      // 실제 댓글 영상
        let cinemascope = slotHeight(aspect: 2.35)

        XCTAssertEqual(landscape, PostDetailCommentRow.videoSlotHeight, accuracy: 0.5)
        XCTAssertEqual(portrait, landscape, accuracy: 0.5,
                       "세로 영상 비율이 도착해도 행 높이가 변하면 안 됨")
        XCTAssertEqual(cinemascope, landscape, accuracy: 0.5,
                       "와이드 영상 비율이 도착해도 행 높이가 변하면 안 됨")
    }

    func testPlayerStillFitsInsideTheSlot() {
        // 슬롯 고정 높이가 플레이어를 늘리지 않는지(= 비율 유지) 확인.
        let url = URL(string: "https://example.com/a.mp4")!
        let height = hostedHeight(PostDetailCommentRow.videoSlot { InlineVideoPlayer(url: url) })
        XCTAssertEqual(height, PostDetailCommentRow.videoSlotHeight, accuracy: 0.5)
    }
}
