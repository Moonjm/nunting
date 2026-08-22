import XCTest
@testable import nunting

/// `ImageCacheReset` — 측정용 콜드 캐시 재현 도구.
///
/// 왜 필요한가: 슬롯 4 ↔ 8 비교를 두 번 시도했는데 두 번 다 판정이 무효였다. 첫 번째는
/// 가벼운 워크로드라 증상 자체가 없었고, 두 번째는 같은 글을 다시 열어 **디스크 캐시가
/// 따뜻해 다운로드가 0건**이었다(net 0 / disk 52). 조건을 바꿔가며 같은 글을 콜드로
/// 반복해서 열 수 있어야 A/B 가 성립한다.
@MainActor
final class ImageCacheResetTests: XCTestCase {

    /// 메모리와 디스크를 **둘 다** 비워야 콜드가 된다 — 메모리만 비우면 디스크 히트로
    /// 떨어져서(느리지만 네트워크는 0) 정작 재현하려던 다운로드 구간이 안 생긴다.
    func testClearsBothMemoryAndDisk() async {
        let reset = ImageCacheReset()
        var cleared: [String] = []
        reset.clearMemoryCache = { cleared.append("memory") }
        reset.clearDiskCache = { done in cleared.append("disk"); done() }
        reset.diskSizeBytes = { $0(0) }

        _ = await reset.run()

        XCTAssertEqual(cleared, ["memory", "disk"])
    }

    /// 비운 양을 돌려준다 — 눌렀는데 아무 반응이 없으면 정말 비워졌는지 알 수 없다.
    func testReportsFreedDiskBytes() async {
        let reset = ImageCacheReset()
        reset.clearMemoryCache = {}
        reset.clearDiskCache = { $0() }
        reset.diskSizeBytes = { $0(12_582_912) }  // 12MB

        let freed = await reset.run()

        XCTAssertEqual(freed, 12_582_912)
    }

    /// 디스크 크기는 **비우기 전** 값이어야 한다. 비운 뒤에 재면 항상 0 이라
    /// "얼마나 비웠나" 를 못 본다.
    func testMeasuresSizeBeforeClearing() async {
        let reset = ImageCacheReset()
        var order: [String] = []
        reset.clearMemoryCache = {}
        reset.clearDiskCache = { done in order.append("clear"); done() }
        reset.diskSizeBytes = { cb in order.append("measure"); cb(100) }

        _ = await reset.run()

        XCTAssertEqual(order.first, "measure", "크기를 먼저 재고 그다음 비운다")
    }
}
