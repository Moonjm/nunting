import Darwin
import Foundation

/// 지정한 mach thread 의 콜스택을 밖에서 캡처한다 — HangWatchdog 이 hang 중인
/// 메인 스레드의 "지금 어디서 막혔나"를 찍는 용도.
///
/// 절차: `thread_suspend` → 레지스터(`thread_get_state`) → 프레임 포인터(x29) 체인을
/// `vm_read_overwrite` 로 안전하게 워크 → `thread_resume` → 그 뒤에야 심볼화.
///
/// suspend~resume 구간의 두 가지 철칙(KSCrash/PLCrashReporter 와 동일):
/// 1. **힙 할당 금지** — 대상 스레드가 malloc 존 락을 쥔 채 멈춰 있으면 이쪽의
///    할당이 같은 락을 기다리며 resume 에 영원히 도달하지 못한다(앱 전체 정지).
///    출력 버퍼는 suspend **전에** 확보하고, 구간 안은 mach 호출과 버퍼 쓰기만.
/// 2. **심볼화(`dladdr`)는 resume 후에** — 대상이 dyld 락을 쥔 채 멈춘 경우의
///    데드락 회피.
///
/// 스택 메모리 읽기는 포인터 역참조가 아니라 `vm_read_overwrite` — 썩은 fp 를
/// 만나도 crash 없이 KERN_FAILURE 로 끝난다(suspend 중이라 스택 자체는 안정).
nonisolated enum ThreadBacktrace {

    /// 대상 스레드의 심볼화된 프레임 목록. 실패/미지원 아키텍처면 빈 배열.
    /// 자기 자신은 캡처 불가(suspend 하면 resume 할 스레드가 없다) — 빈 배열.
    static func capture(thread: thread_t, maxFrames: Int = 64) -> [String] {
        symbolicate(rawAddresses(thread: thread, maxFrames: maxFrames))
    }

    // MARK: - Raw unwind (suspend 구간 — mach call + 사전 확보 버퍼 쓰기만)

    /// 심볼화 없이 return address 목록만. HangWatchdog 이 캡처(빠름, µs 단위)와
    /// 심볼화(느림, ms 단위)를 분리해 레이스 윈도우를 줄이는 데 쓴다.
    static func rawAddresses(thread: thread_t, maxFrames: Int = 64) -> [UInt64] {
        #if arch(arm64)
        guard thread != pthread_mach_thread_np(pthread_self()) else { return [] }

        // suspend 전에 확보 — 구간 안 힙 할당 금지(위 철칙 1).
        let buffer = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: maxFrames)
        defer { buffer.deallocate() }
        var count = 0

        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        // ---- 여기서부터 thread_resume 까지 할당 금지 ----
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
            }
        }
        if kr == KERN_SUCCESS {
            let pc = stripPAC(state.__pc)
            if pc != 0 { buffer[count] = pc; count += 1 }
            let lr = stripPAC(state.__lr)
            if lr != 0, count < maxFrames { buffer[count] = lr; count += 1 }

            // arm64 프레임 레이아웃: [fp] = 이전 fp, [fp+8] = return address.
            var fp = state.__fp
            while count < maxFrames, fp != 0, fp % 8 == 0 {
                var frame: (previous: UInt64, returnAddress: UInt64) = (0, 0)
                var outSize = vm_size_t(0)
                let readKR = withUnsafeMutableBytes(of: &frame) { raw in
                    vm_read_overwrite(
                        mach_task_self_,
                        vm_address_t(fp),
                        vm_size_t(raw.count),
                        vm_address_t(UInt(bitPattern: raw.baseAddress)),
                        &outSize)
                }
                guard readKR == KERN_SUCCESS else { break }
                let ret = stripPAC(frame.returnAddress)
                guard ret != 0 else { break }
                buffer[count] = ret
                count += 1
                // fp 는 스택 위쪽으로만 자라야 한다 — 루프/썩은 체인 방어.
                guard frame.previous > fp else { break }
                fp = frame.previous
            }
        }
        thread_resume(thread)
        // ---- 할당 허용 ----
        return Array(buffer[..<count])
        #else
        return []
        #endif
    }

    /// arm64e pointer authentication 상위 비트 제거. iOS 유저스페이스 텍스트 주소는
    /// 36bit 안이라 이 마스크로 충분(Crashlytics/KSCrash 와 동일 관례).
    private static func stripPAC(_ address: UInt64) -> UInt64 {
        address & 0x0000_000F_FFFF_FFFF
    }

    // MARK: - Symbolication (resume 후, 할당 자유)

    static func symbolicate(_ addresses: [UInt64]) -> [String] {
        addresses.enumerated().map { symbolicate($0.element, index: $0.offset) }
    }

    private static func symbolicate(_ address: UInt64, index: Int) -> String {
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(address)),
              dladdr(pointer, &info) != 0
        else {
            return String(format: "%-3d ???  0x%llx", index, address)
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "???"
        guard let sname = info.dli_sname else {
            return String(format: "%-3d %@  0x%llx", index, image, address)
        }
        let symbol = demangle(String(cString: sname))
        let offset = address &- UInt64(UInt(bitPattern: info.dli_saddr))
        return String(format: "%-3d %@  %@ + %llu", index, image, symbol, offset)
    }

    private typealias SwiftDemangle = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
        UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private static let swiftDemangle: SwiftDemangle? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "swift_demangle") else { return nil }
        return unsafeBitCast(sym, to: SwiftDemangle.self)
    }()

    private static func demangle(_ mangled: String) -> String {
        guard mangled.hasPrefix("$s") || mangled.hasPrefix("_$s"),
              let demangle = swiftDemangle,
              let demangled = demangle(mangled, mangled.utf8.count, nil, nil, 0)
        else { return mangled }
        defer { free(demangled) }
        return String(cString: demangled)
    }
}
