import XCTest
import os
import SDWebImage
import SDWebImageWebPCoder
@testable import nunting

/// **정적 WebP 가 어느 디코드 메서드로 들어오는가.**
///
/// `SignpostWebPCoder` 의 ImageIO 라우팅은 `decodedImage(with:options:)` 안에만 있다.
/// 그런데 본문 이미지는 `AnimatedImage` 가 컨텍스트에 `animatedImageClass` 를 심어서
/// 열린다. SD 는 그때 애니메 코더를 먼저 찾고, `SDImageWebPCoder` 는 정적 WebP 도
/// `canDecodeFromData` 로 받는다 — 그러면 프레임 0 이 `animatedImageFrame(at:)`
/// (libwebp)로 나오고 ImageIO 라우팅은 영영 안 걸린다.
///
/// 소스만 읽어선 갈리지 않아(계측엔 `webpViaIO` 가 이미지 수만큼 찍힌다) 실제 호출을
/// 센다. 이 테스트가 라우팅이 살아 있는지를 지키는 유일한 지점이다.
final class WebPCoderRoutingTests: XCTestCase {

    /// 호출을 세는 코더. 디코드 로직은 super 그대로.
    final class CountingWebPCoder: SDImageWebPCoder, @unchecked Sendable {
        nonisolated(unsafe) static let decodedImageCalls = OSAllocatedUnfairLock(initialState: 0)
        nonisolated(unsafe) static let animatedFrameCalls = OSAllocatedUnfairLock(initialState: 0)
        /// 그중 **실제로 프레임을 돌려준** 횟수. 정적 WebP 는 시도만 하고 nil 이 온다.
        nonisolated(unsafe) static let animatedFrameHits = OSAllocatedUnfairLock(initialState: 0)

        static func reset() {
            decodedImageCalls.withLock { $0 = 0 }
            animatedFrameCalls.withLock { $0 = 0 }
            animatedFrameHits.withLock { $0 = 0 }
        }

        override func decodedImage(with data: Data?, options: [SDImageCoderOption: Any]?) -> UIImage? {
            Self.decodedImageCalls.withLock { $0 += 1 }
            return super.decodedImage(with: data, options: options)
        }

        override func animatedImageFrame(at index: UInt) -> UIImage? {
            let frame = super.animatedImageFrame(at: index)
            if index == 0 {
                Self.animatedFrameCalls.withLock { $0 += 1 }
                if frame != nil { Self.animatedFrameHits.withLock { $0 += 1 } }
            }
            return frame
        }
    }

    private var originalCoders: [any SDImageCoder] = []

    override func setUp() {
        super.setUp()
        let manager = SDImageCodersManager.shared
        originalCoders = manager.coders ?? []
        manager.coders = originalCoders.filter { !($0 is SignpostWebPCoder) }
        manager.addCoder(CountingWebPCoder())
        CountingWebPCoder.reset()
    }

    override func tearDown() {
        SDImageCodersManager.shared.coders = originalCoders
        super.tearDown()
    }

    private func staticWebPData() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { ctx in
            UIColor.systemIndigo.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return try XCTUnwrap(SDImageWebPCoder.shared.encodedData(with: image, format: .webP, options: nil))
    }

    private func animatedWebPData() throws -> Data {
        let frames = (0..<3).map { index -> SDImageFrame in
            let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { ctx in
                UIColor(hue: CGFloat(index) / 3, saturation: 1, brightness: 1, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
            return SDImageFrame(image: image, duration: 0.05)
        }
        let animated = try XCTUnwrap(SDImageCoderHelper.animatedImage(with: frames))
        return try XCTUnwrap(SDImageWebPCoder.shared.encodedData(with: animated,
                                                                format: .webP, options: nil))
    }

    private var context: [SDWebImageContextOption: Any] {
        // 본문 이미지가 열리는 방식 그대로 — `AnimatedImage` 가 이걸 심는다.
        [.animatedImageClass: SDAnimatedImage.self]
    }

    /// **정적 WebP 는 `decodedImage` 로 온다** — 즉 ImageIO 라우팅이 본문 경로에 걸린다.
    ///
    /// `animatedImageClass` 가 있어도 그렇다. SD 는 애니메 코더를 먼저 시도하지만
    /// (`SDImageWebPCoder` 는 정적 WebP 도 `canDecodeFromData` 로 받는다) 프레임 0 이
    /// nil 로 와서 `SDAnimatedImage` 생성이 실패하고, 그대로 `decodedImage` 로 떨어진다.
    ///
    /// 그 실패 시도는 **공짜다** — 디코드가 아니라 nil 반환이다. 옛 `webpFrame0` 계측이
    /// 1,363건 전부 p50/max 0ms 였던 게 이것이고, 건수가 `webpViaIO` 와 1:1 이었던
    /// 이유도 이것이다.
    ///
    /// 이 순서가 바뀌면 라우팅이 조용히 죽고 libwebp 로 되돌아간다 — 화면은 그대로라
    /// 증상이 "그냥 느림" 으로만 나타난다.
    func testStaticWebPGoesThroughDecodedImage() throws {
        let image = SDImageCacheDecodeImageData(try staticWebPData(), "static", [], context)

        XCTAssertNotNil(image)
        XCTAssertGreaterThan(CountingWebPCoder.decodedImageCalls.withLock { $0 }, 0,
                             "정적 WebP 가 decodedImage 를 안 거쳤다 — ImageIO 라우팅이 죽는다")
        XCTAssertEqual(CountingWebPCoder.animatedFrameHits.withLock { $0 }, 0,
                       "애니메 경로가 프레임을 실제로 냈다 — 그럼 libwebp 로 디코드된 것이고 "
                       + "ImageIO 결과는 버려진다(디코드 두 번)")
    }

    /// **애니메 WebP 는 프레임 경로로 온다** — libwebp 유지가 의도다(다중 프레임에선
    /// libwebp 가 2~3배 빠르다는 게 이 코더를 등록한 애초 이유).
    func testAnimatedWebPGoesThroughFramePath() throws {
        let image = SDImageCacheDecodeImageData(try animatedWebPData(), "animated", [], context)

        XCTAssertNotNil(image)
        XCTAssertGreaterThan(CountingWebPCoder.animatedFrameCalls.withLock { $0 }, 0,
                             "애니메 WebP 가 프레임 경로로 안 갔다")
    }
}
