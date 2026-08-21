import XCTest
import UIKit
@testable import nunting

/// `DecodedImageRetainer` — 방금 디코드한 비트맵을 아주 잠깐 강하게 붙잡는다.
///
/// 목적: SDWebImage 의 재사용 캐시(`SDWebImageDownloaderOperation.imageMap`)는 값이
/// **weak** 라(`NSPointerFunctionsWeakMemory`), 같은 다운로드에 붙은 두 토큰
/// (프리페치 + 표시)의 두 번째가 첫 디코드 결과를 놓치고 같은 바이트를 통째로 다시
/// 디코드한다(기기 계측: webpStatic 214건 중 46쌍이 0~1초 간격 동일 크기 중복,
/// 디코드 시간의 24%). 첫 결과를 잠깐만 살려두면 그 쌍이 사라진다.
///
/// 붙잡는 만큼 메모리를 더 쓰므로(9.8MP 한 장이 ~39MB) 상한이 이 클래스의 본체다.
final class DecodedImageRetainerTests: XCTestCase {

    private func image(pixels: Int) -> UIImage {
        let side = max(1, Int(Double(pixels).squareRoot()))
        UIGraphicsBeginImageContext(CGSize(width: side, height: side))
        defer { UIGraphicsEndImageContext() }
        return UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    }

    /// 본질: 붙잡는 동안 weak 참조가 살아 있어야 한다. 이게 안 되면 SDWebImage 의
    /// weak 엔트리도 그대로 비어 중복 디코드가 남는다.
    func testHeldImageKeepsWeakReferenceAlive() {
        let retainer = DecodedImageRetainer(maxCount: 4, maxBytes: 64 << 20, window: 10)
        weak var weakRef: UIImage?

        autoreleasepool {
            let img = image(pixels: 100)
            weakRef = img
            retainer.hold(img, bytes: 400, now: Date(timeIntervalSince1970: 0))
        }

        XCTAssertNotNil(weakRef, "붙잡은 동안에는 살아 있어야 한다")
    }

    /// 창이 지난 항목은 놓는다 — 안 그러면 잠깐 붙잡는 게 아니라 캐시가 된다.
    func testReleasesEntriesOlderThanWindow() {
        let retainer = DecodedImageRetainer(maxCount: 4, maxBytes: 64 << 20, window: 1)
        let t0 = Date(timeIntervalSince1970: 1_000)
        weak var weakRef: UIImage?

        autoreleasepool {
            let img = image(pixels: 100)
            weakRef = img
            retainer.hold(img, bytes: 400, now: t0)
        }
        XCTAssertNotNil(weakRef)

        // 창(1s)을 넘긴 시점의 다음 hold 가 오래된 항목을 밀어낸다.
        autoreleasepool {
            retainer.hold(image(pixels: 100), bytes: 400, now: t0.addingTimeInterval(1.5))
        }

        XCTAssertNil(weakRef, "창을 넘긴 항목은 놓아야 한다")
    }

    /// 장수 상한 — 오래된 것부터 놓는다.
    func testEvictsOldestBeyondCountCap() {
        let retainer = DecodedImageRetainer(maxCount: 2, maxBytes: 64 << 20, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        weak var first: UIImage?

        autoreleasepool {
            let img = image(pixels: 100)
            first = img
            retainer.hold(img, bytes: 400, now: t0)
            retainer.hold(image(pixels: 100), bytes: 400, now: t0.addingTimeInterval(0.1))
            retainer.hold(image(pixels: 100), bytes: 400, now: t0.addingTimeInterval(0.2))
        }

        XCTAssertNil(first, "3번째가 들어오면 가장 오래된 1번째를 놓는다")
        XCTAssertEqual(retainer.heldCount, 2)
    }

    /// 바이트 상한 — 큰 비트맵이 상한을 넘기면 이전 것들을 놓는다.
    /// 9.8MP 한 장이 ~39MB 라 장수만으로는 메모리가 안 잡힌다(OOM 이력이 있는 앱).
    func testEvictsBeyondByteCap() {
        let retainer = DecodedImageRetainer(maxCount: 10, maxBytes: 1_000, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        weak var first: UIImage?

        autoreleasepool {
            let img = image(pixels: 100)
            first = img
            retainer.hold(img, bytes: 600, now: t0)
            retainer.hold(image(pixels: 100), bytes: 600, now: t0.addingTimeInterval(0.1))
        }

        XCTAssertNil(first, "합계가 상한을 넘으면 오래된 것부터 놓는다")
        XCTAssertEqual(retainer.heldCount, 1)
    }

    /// 상한 자체보다 큰 한 장은 아예 안 붙잡는다 — 붙잡아도 상한을 이미 넘고,
    /// 그 한 장 때문에 다른 항목이 전부 밀려나면 중복 제거 효과도 사라진다.
    func testDoesNotHoldSingleImageLargerThanCap() {
        let retainer = DecodedImageRetainer(maxCount: 10, maxBytes: 1_000, window: 60)

        retainer.hold(image(pixels: 100), bytes: 5_000, now: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(retainer.heldCount, 0)
    }
}
