import Foundation
import SDWebImage

/// 이미지 캐시(메모리+디스크)를 통째로 비우는 **측정용 도구**.
///
/// 왜 있는가 — 이미지 파이프라인 A/B(슬롯 폭, ioQueue 동시성 …)를 판정하려면 같은 글을
/// 여러 번 **콜드** 로 열 수 있어야 한다. 실제로 두 번 연속 판정이 무효였다: 한 번은
/// 가벼운 워크로드라 증상이 없었고(대기 p90 325ms), 한 번은 같은 글을 다시 열어
/// 디스크 캐시가 따뜻한 바람에 다운로드가 0건이었다(net 0 / disk 52 / mem 3).
/// "안 본 무거운 글" 을 매번 찾는 것보다 같은 글을 콜드로 되돌리는 쪽이 비교가 깨끗하다.
///
/// 메모리만 비우면 안 된다 — 디스크 히트로 떨어져 여전히 네트워크가 0건이라, 정작
/// 재현하려던 다운로드+대기 구간이 생기지 않는다.
///
/// 실험이 끝나면 이 도구를 남길지는 그때 정한다. 남긴다면 성격은 "개발용" 이다.
@MainActor
final class ImageCacheReset {
    static let shared = ImageCacheReset()

    /// Test seam — `MemoryPressureResponder` 와 같은 패턴. 기본값이 실제 SDK 를
    /// 부르고, 테스트는 스파이를 꽂아 SDK 싱글톤을 건드리지 않는다.
    var clearMemoryCache: @MainActor () -> Void = {
        AppImageCache.app.clearMemory()
    }
    var clearDiskCache: @MainActor (@escaping @MainActor () -> Void) -> Void = { done in
        AppImageCache.app.clearDisk { done() }
    }
    var diskSizeBytes: @MainActor (@escaping @MainActor (UInt) -> Void) -> Void = { report in
        AppImageCache.app.calculateSize { _, totalSize in report(totalSize) }
    }

    /// 비우고, **비우기 전** 디스크 사용량을 돌려준다(비운 뒤에 재면 항상 0 이라
    /// 얼마나 비웠는지 못 본다).
    @discardableResult
    func run() async -> UInt {
        let before = await withCheckedContinuation { (c: CheckedContinuation<UInt, Never>) in
            diskSizeBytes { c.resume(returning: $0) }
        }
        clearMemoryCache()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            clearDiskCache { c.resume() }
        }
        return before
    }
}
