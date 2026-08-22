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

    /// 다운로드 슬롯 폭 4. 2·4·8 세 지점을 다 재봤고 본문 show p90 이 5,049 / 5,096 /
    /// 5,120ms 로 붙어 있다 — 폭으로는 총량이 안 준다(처리량 한계). 4 는 그중 대기가
    /// 가장 낮은 지점이다. 근거 표는 `SDWebImageSetup` 주석.
    func testConfigureKeepsMeasuredDownloadSlotWidth() {
        SDWebImageSetup.configure()

        XCTAssertEqual(SDWebImageDownloader.shared.config.maxConcurrentDownloads, 4)
    }


    /// 디스크 쓰기의 원자성을 해제한 상태를 못 박는다. 기본값 `.atomic` 은 임시 파일 +
    /// rename 2단계라 I/O 가 두 배이고, 그 쓰기가 백그라운드 풀을 고갈시켜 이미지
    /// 로딩 전체를 막는다는 게 실측으로 확정됐다(근거 표는 `SDWebImageSetup` 주석).
    /// 라이브러리가 atomic 을 요구하는 조건은 **동시 큐**인데 우리는 직렬 기본값이라
    /// 해당하지 않는다 — 그 전제가 바뀌면(동시 큐로 바꾸면) 이 값도 되돌려야 한다.
    func testConfigureDropsAtomicDiskWrite() {
        SDWebImageSetup.configure()

        XCTAssertEqual(SDImageCache.shared.config.diskCacheWritingOptions, [])
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
