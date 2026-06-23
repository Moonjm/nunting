import Foundation

/// 앱의 현재 메모리 사용량 측정. **`phys_footprint`** 를 쓴다 — 이게 iOS jetsam 이
/// OOM 판정에 비교하는 값이고 JetsamEvent 로그의 메모리량과 같은 계열이다.
/// (흔히 쓰는 `resident_size` 는 jetsam 이 보는 값이 아니라 과대계상돼 무의미.)
enum MemoryFootprint {
    /// 현재 phys_footprint (MB). 실패 시 0.
    static func currentMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    /// 현재 프로세스 malloc 힙 통계 (MB). `live`=실제 사용중(size_in_use),
    /// `alloc`=OS 에서 예약(size_allocated). **alloc − live = 단편화로 묶인 빈
    /// 페이지** — SwiftSoup tiny-object churn 으로 small-region 이 잘게 단편화되면
    /// live 는 평탄해도 alloc(=footprint 의 malloc 분)이 래칫된다. 이 gap 을 서버에
    /// 같이 찍어 단편화 vs leak 을 원격으로 가른다. zone=nil → 전 zone 합산.
    static func mallocMB() -> (live: Int, alloc: Int) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (Int(stats.size_in_use) / (1024 * 1024),
                Int(stats.size_allocated) / (1024 * 1024))
    }

    /// 앱 메모리 한도까지 남은 여유 (MB). iOS 13+. 0 이면 한도 임박/조회 실패.
    /// `os_proc_available_memory` 는 네이티브 macOS 엔 없다(iOS/visionOS/Catalyst만).
    /// 이 앱은 UIKit 기반이라 macOS 빌드 자체가 불가하지만, SUPPORTED_PLATFORMS 에
    /// macosx 가 남아 있어 인덱서/만일의 슬라이스 컴파일을 위해 가드한다.
    static func availableMB() -> Int {
        #if os(macOS)
        return 0
        #else
        return Int(os_proc_available_memory() / (1024 * 1024))
        #endif
    }
}
