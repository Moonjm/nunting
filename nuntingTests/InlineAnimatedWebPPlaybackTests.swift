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
        SDImageCache.shared.store(nil, imageData: data, forKey: key, cacheType: .disk) {
            seeded.fulfill()
        }
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

    func testInlineBodyImageSelfHealsPoisonedStaticMemoryEntry() throws {
        // 구버전 인라인 경로(first-frame 정지컷)가 메모리 캐시에 남긴 정지
        // UIImage 를 새 경로가 같은 키로 집어가는 시나리오. SDWebImage 의
        // `.matchAnimatedImageClass` 는 디스크 조회 블록의 #3523 메모리
        // 재확인이 클래스 체크 없이 오염 엔트리를 재획득해 무력(실측) —
        // `purgePoisonedMemoryEntry`(로드 시작 전 선제 제거)가 있어야
        // 움짤이 정지컷으로 고착되지 않는다.
        let data = try makeAnimatedWebPData()
        let url = URL(string: "https://unit.test/\(UUID().uuidString)/poisoned.webp")!
        let key = try XCTUnwrap(SDWebImageManager.shared.cacheKey(for: url))

        let seeded = expectation(description: "disk seed")
        SDImageCache.shared.store(nil, imageData: data, forKey: key, cacheType: .disk) {
            seeded.fulfill()
        }
        wait(for: [seeded], timeout: 5)

        // 오염 주입: 정지 첫 프레임 디코드를 메모리에 저장(구버전 잔재 재현).
        let poisoned = try XCTUnwrap(
            SDImageCacheDecodeImageData(data, key, [.decodeFirstFrameOnly], nil)
        )
        XCTAssertFalse(poisoned is SDAnimatedImage)
        SDImageCache.shared.storeImage(toMemory: poisoned, forKey: key)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let host = UIHostingController(rootView: NetworkImage(url: url, aspectRatio: 1.0))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        defer { window.isHidden = true }

        // 자가치유(리로드 1회) 시간을 포함해 폴링 — 재마운트 직후엔 낡은
        // 뷰가 계층에 잠깐 공존할 수 있어 전체를 훑어 아무 뷰나
        // SDAnimatedImage 를 물면 성공으로 본다.
        var healedImage: UIImage?
        for _ in 0..<60 {
            pump(0.05)
            if let image = allAnimatedImageViews(in: window)
                .compactMap(\.image).first(where: { $0 is SDAnimatedImage }) {
                healedImage = image
                break
            }
        }
        if healedImage == nil {
            let views = allAnimatedImageViews(in: window)
            print("[DIAG] final views: \(views.map { $0.image.map { String(describing: type(of: $0)) } ?? "nil" })")
            let mem = SDImageCache.shared.imageFromMemoryCache(forKey: key)
            print("[DIAG] memory after: \(mem.map { String(describing: type(of: $0)) } ?? "nil")")
        }
        XCTAssertTrue(
            healedImage is SDAnimatedImage,
            "오염된 메모리 정지컷을 감지해 제거·리로드 후 SDAnimatedImage 로 회복해야 함"
        )
    }
}
