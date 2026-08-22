import XCTest
import SDWebImage
@testable import nunting

// @MainActor: SDWebImageSetup.configure() 가 main actor 소속(앱 시작 시 설정).
@MainActor
final class SDWebImageSetupTests: XCTestCase {
    func testConfigureRegistersSingleSignpostWebPCoderAtHighestPriority() {
        let manager = SDImageCodersManager.shared
        let originalCoders = manager.coders ?? []
        manager.coders = originalCoders.filter { !($0 is SignpostWebPCoder) }
        defer { manager.coders = originalCoders }

        SDWebImageSetup.configure()
        SDWebImageSetup.configure()

        let signpostCoders = (manager.coders ?? []).filter { $0 is SignpostWebPCoder }
        XCTAssertEqual(signpostCoders.count, 1)
        XCTAssertTrue(manager.coders?.last is SignpostWebPCoder)
    }

    /// 다운로드 슬롯 폭 8 — 스레드 풀 고갈을 없앤 뒤의 재실험 조건. 종전 세 번의 폭
    /// 실험이 무효였던 건 그 아래 고갈이 총량을 묶고 있었기 때문이고, 지금은 p90 이
    /// 거의 전부 슬롯 회전 대기다. 근거와 판정 기준은 `SDWebImageSetup` 주석.
    func testConfigureKeepsMeasuredDownloadSlotWidth() {
        SDWebImageSetup.configure()

        XCTAssertEqual(SDWebImageDownloader.shared.config.maxConcurrentDownloads, 8)
    }


    /// 캐시 정책은 **실제로 설치된 캐시**에 걸려야 한다.
    ///
    /// 한동안 안 걸려 있었다. 설정을 `SDImageCache.shared.config` 에 썼는데 그건
    /// `SDImageCacheConfig.default` 의 **복사본**이고(`SDImageCache.m:127`
    /// `_config = [config copy]`), 우리가 설치한 `ThreadedImageCache` 는 원본
    /// `.default` 를 참조한다. 그래서 atomic 해제도 400MB 캡도 안 쓰는 캐시만
    /// 고치고 있었다 — 조용히. 이 테스트는 그 조용함을 없앤다.
    ///
    /// atomic 해제 근거: 기본값은 임시 파일 + rename 2단계라 I/O 가 두 배이고, 그
    /// 쓰기가 백그라운드 풀을 고갈시켜 이미지 로딩 전체를 막는다(근거 표는
    /// `SDWebImageSetup` 주석). 라이브러리가 atomic 을 요구하는 조건은 **동시 큐**
    /// 인데 우리는 직렬 기본값이라 해당하지 않는다.
    func testConfigureAppliesCachePolicyToTheInstalledCache() {
        SDWebImageSetup.configure()

        XCTAssertTrue(SDWebImageManager.defaultImageCache === AppImageCaches.disk,
                      "설치된 캐시가 우리 구현이 아니면 아래 검증이 무의미하다")
        let config = AppImageCaches.disk.config
        XCTAssertEqual(config.diskCacheWritingOptions, [])
        XCTAssertEqual(config.maxMemoryCost, 400 * 1024 * 1024)
        XCTAssertEqual(config.maxDiskSize, 500 * 1024 * 1024)
        XCTAssertEqual(config.maxDiskAge, 7 * 24 * 60 * 60)
    }

    /// 캐시 IO 큐는 **라이브러리 기본(직렬)** 을 유지한다. 동시 큐로 바꾸는 실험을
    /// 했고 대기 p50 이 343ms → 2,173ms 로 6배 악화됐다(근거 표는 `SDWebImageSetup`
    /// 주석). 병렬도를 올리는 방향이 이 파이프라인에서 안 통한다는 세 번째 확인이라,
    /// 누가 이 설정을 다시 건드리면 여기서 걸리게 한다.
    func testConfigureLeavesCacheIOQueueAtLibraryDefault() {
        let pristine = SDImageCacheConfig()

        SDWebImageSetup.configure()

        XCTAssertTrue(SDImageCacheConfig.default.ioQueueAttributes === pristine.ioQueueAttributes,
                      "IO 큐 attr 이 라이브러리 기본에서 바뀌었다 — 측정상 더 느려진 방향이다")
    }



}
