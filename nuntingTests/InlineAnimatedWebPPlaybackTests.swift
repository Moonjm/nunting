import XCTest
import SwiftUI
import SDWebImage
import SDWebImageWebPCoder
@testable import nunting

/// 통합 검증: 본문 인라인 경로(NetworkImage → AnimatedImage →
/// SDAnimatedImageView)가 애니메이션 WebP 를 실제로 **재생**하는지 —
/// 디코드 클래스 확인을 넘어, 뷰 계층에 SDAnimatedImage 가 물리고
/// 프레임 인덱스가 전진하는 것까지 본다. 네트워크 없이 디스크 캐시
/// 시드 + 캐시 히트로 돈다. (async 컨텍스트는 SwiftUI 레이아웃/
/// CADisplayLink 를 안 돌리므로 RunLoop.run 으로 직접 구동한다.)
@MainActor
final class InlineAnimatedWebPPlaybackTests: XCTestCase {

    private func makeAnimatedWebPData(frames frameCount: Int = 4) throws -> Data {
        func solid(_ hue: CGFloat) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { ctx in
                UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
        }
        let frames = (0..<frameCount).map {
            SDImageFrame(image: solid(CGFloat($0) / CGFloat(frameCount)), duration: 0.05)
        }
        let animated = try XCTUnwrap(SDImageCoderHelper.animatedImage(with: frames))
        return try XCTUnwrap(
            SDImageWebPCoder.shared.encodedData(with: animated, format: .webP, options: nil)
        )
    }

    private func allAnimatedImageViews(in view: UIView) -> [SDAnimatedImageView] {
        var result: [SDAnimatedImageView] = []
        if let found = view as? SDAnimatedImageView { result.append(found) }
        for sub in view.subviews {
            result.append(contentsOf: allAnimatedImageViews(in: sub))
        }
        return result
    }

    private func firstAnimatedImageView(in view: UIView) -> SDAnimatedImageView? {
        allAnimatedImageViews(in: view).first
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func testInlineBodyImagePlaysAnimatedWebP() throws {
        let data = try makeAnimatedWebPData()
        let url = URL(string: "https://unit.test/\(UUID().uuidString)/inline-play.webp")!

        // NetworkImage 기본 호출(썸네일 파라미터 없음) → context nil → 플레인 키.
        let key = SDWebImageManager.shared.cacheKey(for: url)
        let seeded = expectation(description: "disk seed")
        // `AppImageCache` 는 디스크 쓰기를 미루므로(보는 동안 I/O 로 스레드를 붙잡지
        // 않으려고) 시드는 flush 까지 해야 실제로 파일이 생긴다. store 의 completion 은
        // "메모리 반영 완료" 이지 "디스크 기록 완료" 가 아니다.
        AppImageCache.app.store(nil, imageData: data, forKey: key, cacheType: .disk, completion: nil)
        AppImageCache.app.flushPendingDiskWrites { seeded.fulfill() }
        wait(for: [seeded], timeout: 5)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let host = UIHostingController(rootView: NetworkImage(url: url, aspectRatio: 1.0))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        defer { window.isHidden = true }

        // 로드 + 뷰 마운트 대기(캐시 히트라 짧다). 폴링으로 SDAnimatedImageView 획득.
        var imageView: SDAnimatedImageView?
        for _ in 0..<40 {
            pump(0.05)
            if let found = firstAnimatedImageView(in: window), found.image != nil {
                imageView = found
                break
            }
        }
        let animatedImageView = try XCTUnwrap(imageView, "SDAnimatedImageView 가 뷰 계층에 마운트돼야 함")
        XCTAssertTrue(
            animatedImageView.image is SDAnimatedImage,
            "인라인 로드 결과는 SDAnimatedImage — got \(type(of: animatedImageView.image as Any))"
        )

        // 프레임 전진 확인 — 0.05s×4프레임 루프라 1s 안에 반드시 움직인다.
        let startIndex = animatedImageView.player?.currentFrameIndex ?? 0
        var advanced = false
        for _ in 0..<20 {
            pump(0.05)
            if let player = animatedImageView.player, player.currentFrameIndex != startIndex {
                advanced = true
                break
            }
        }
        XCTAssertTrue(advanced, "재생 중이면 currentFrameIndex 가 전진해야 함")
    }

    /// 프리페치가 메모리 캐시를 **정지컷으로 오염시키지 않는다**는 불변식.
    ///
    /// 종전엔 워밍이 `animatedImageClass` 없이 디코드해 움짤이 정지컷으로
    /// 고착될 수 있었고, 그걸 `NetworkImage.purgePoisonedMemoryEntry`(로드
    /// 직전 선제 제거)로 사후 방어했다. 그 가드는 정적 webp 전체에 오탐이라
    /// 프리페치 결과까지 지워버려 제거했고, 대신 워밍 컨텍스트가 표시 경로와
    /// **같은 lazy 클래스**를 쓰도록 원천을 막았다 — 여기서 그걸 핀한다.
    /// 워밍이 남긴 엔트리를 인라인 경로가 그대로 받아 재생까지 가는지 본다.
    func testPrefetchContextWarmsMemoryCacheWithAnimatedClass() throws {
        let data = try makeAnimatedWebPData()
        let url = URL(string: "https://unit.test/\(UUID().uuidString)/warm.webp")!
        let key = try XCTUnwrap(SDWebImageManager.shared.cacheKey(for: url))

        let seeded = expectation(description: "disk seed")
        // `AppImageCache` 는 디스크 쓰기를 미루므로(보는 동안 I/O 로 스레드를 붙잡지
        // 않으려고) 시드는 flush 까지 해야 실제로 파일이 생긴다. store 의 completion 은
        // "메모리 반영 완료" 이지 "디스크 기록 완료" 가 아니다.
        AppImageCache.app.store(nil, imageData: data, forKey: key, cacheType: .disk, completion: nil)
        AppImageCache.app.flushPendingDiskWrites { seeded.fulfill() }
        wait(for: [seeded], timeout: 5)

        // 프리페치 워밍 재현 — `BodyImagePrefetcher` 가 발행하는 것과 같은
        // 컨텍스트로 로드하면 메모리 캐시에 SDAnimatedImage 가 남아야 한다.
        let warmed = expectation(description: "prefetch warm")
        SDWebImageManager.shared.loadImage(
            with: url,
            options: .lowPriority,
            context: BodyImagePrefetcher.lazyAnimatedContext(nil),
            progress: nil
        ) { image, _, _, _, _, _ in
            XCTAssertTrue(image is SDAnimatedImage,
                          "워밍 디코드 결과는 lazy SDAnimatedImage — got \(type(of: image as Any))")
            warmed.fulfill()
        }
        wait(for: [warmed], timeout: 10)
        XCTAssertTrue(
            AppImageCache.app.imageFromMemoryCache(forKey: key) is SDAnimatedImage,
            "워밍이 남긴 메모리 엔트리도 SDAnimatedImage"
        )

        // 그 엔트리를 인라인 경로가 그대로 물고 재생까지 가는지 — 오염이라면
        // 여기서 정지 UIImage 가 잡힌다(캐시 키는 워밍/표시가 동일).
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let host = UIHostingController(rootView: NetworkImage(url: url, aspectRatio: 1.0))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        defer { window.isHidden = true }

        var mounted: UIImage?
        for _ in 0..<40 {
            pump(0.05)
            if let image = allAnimatedImageViews(in: window).compactMap(\.image).first {
                mounted = image
                break
            }
        }
        XCTAssertTrue(
            mounted is SDAnimatedImage,
            "워밍된 엔트리를 인라인이 그대로 받아야 함 — got \(type(of: mounted as Any))"
        )
    }
}
