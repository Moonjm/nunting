import Foundation
import os
import SDWebImage
import UIKit

/// 디스크 쓰기를 **보는 동안엔 미루는** 이미지 캐시.
///
/// 배경(2026-08-22 기기 계측). 이미지가 쏟아지는 동안 34장을 `SDImageCache.ioQueue`
/// (직렬)에서 순차로 디스크에 쓰는데, 그 스레드가 파일 I/O 에 묶여 백그라운드 스레드
/// 풀이 고갈된다. 그러면 디코드 블록이 풀에서 순서를 기다리고(빈 블록조차 4.5초 대기),
/// 다운로드 오퍼레이션이 안 끝나 슬롯이 안 풀리고, 뒤에 선 이미지는 다운로드조차
/// 시작하지 못한다. 저장 위치를 메모리로만 돌려 디스크 쓰기를 없앤 세션이 그걸 증명했다:
///
///                   쓰기 켬        쓰기 끔
///   본문 show p50   2,468ms         127ms
///   본문 show p90   5,049ms         383ms
///   bg 큐 지연    35건/2,100ms      0건/0ms
///
/// 쓰기 **비용**을 줄이는 것으로는 안 됐다(atomic 해제 → 변화 없음). 크기가 아니라
/// 쓰기가 스레드를 붙잡는다는 사실 자체가 문제라, **시점**을 옮긴다: 사용자가 보는
/// 동안엔 메모리에만 두고, 조용해지면(또는 백그라운드 진입 시) 몰아서 디스크에 쓴다.
///
/// 왜 `SDImageCache` 서브클래스인가 — SDWebImage 가 저장을 부르는 지점이 여기라
/// (data, key) 쌍을 정확히 받을 수 있다. 밖에서 키를 재구성하면 썸네일 컨텍스트마다
/// 달라지는 캐시 키 규칙을 우리가 다시 구현해야 하고, 그건 틀리기 쉽다.
/// 네임스페이스는 `SDImageCache.shared` 와 같은 `"default"` — 같은 디렉터리를 쓰므로
/// 기존에 받아둔 파일이 그대로 살아 있다.
///
/// 대가: 미룬 사이에 앱이 죽으면 그 이미지는 다음에 다시 받는다. 화면상으로는 그
/// 이미지 한 번이 느리게 뜨는 것으로 끝난다.
nonisolated final class AppImageCache: SDImageCache, @unchecked Sendable {
    /// 앱 전역에서 이 인스턴스 하나만 쓴다. 이름이 `shared` 가 아닌 이유: 부모(`SDImageCache`)에 같은 이름의 클래스
    /// 프로퍼티가 있어 가릴 수 없다. 부모의 `SDImageCache.shared` 와 **섞어 쓰면 안
    /// 된다** — 메모리 캐시가 둘로 갈라져(디스크는 같은 디렉터리) 한쪽에 넣은 걸
    /// 다른 쪽이 못 찾는다.
    static let app = AppImageCache(namespace: "default")

    private struct Pending {
        let key: String
        let data: Data
    }

    /// 튜닝 값. 초기화 시점에만 정해지고 그 뒤 안 바뀐다(락 없이 읽는 이유).
    private var quietWindow: TimeInterval = 1.5
    private var maxPendingBytes: Int = 32 * 1024 * 1024
    private let state = OSAllocatedUnfairLock(initialState: [Pending]())
    /// 디바운스 세대 번호. `DispatchWorkItem` 은 Sendable 이 아니라 락에 못 담아서,
    /// 예약할 때마다 번호를 올리고 깨어난 블록이 자기 번호가 최신일 때만 쓴다.
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    /// **부모의 지정 이니셜라이저를 반드시 구현해야 한다.** `SDImageCache` 는
    /// `initWithNamespace:` 같은 편의 생성자에서 결국 이 3-인자 지정 생성자로 내려오는데,
    /// Swift 서브클래스가 자기 지정 생성자를 따로 두면 부모 것을 상속하지 않아
    /// 런타임에 "Use of unimplemented initializer" 로 트랩한다(실제로 그렇게 죽었다).
    override init(namespace ns: String, diskCacheDirectory: String?,
                  config: SDImageCacheConfig?) {
        super.init(namespace: ns, diskCacheDirectory: diskCacheDirectory, config: config)
    }

    /// - Parameters:
    ///   - quietWindow: 마지막 저장 이후 이만큼 조용하면 몰아서 쓴다. 스크롤이 이어지는
    ///     동안엔 계속 밀리고, 사용자가 멈춘 뒤에 쓰이는 게 목적이다.
    ///   - maxPendingBytes: 대기분 상한. 넘으면 즉시 쓴다 — 미룬 데이터가 메모리에
    ///     무한정 쌓이면 OOM 이력이 있는 이 앱에서 위험을 다른 곳으로 옮기는 셈이다.
    convenience init(namespace: String, quietWindow: TimeInterval = 1.5,
                     maxPendingBytes: Int = 32 * 1024 * 1024) {
        self.init(namespace: namespace, diskCacheDirectory: nil, config: nil)
        self.quietWindow = quietWindow
        self.maxPendingBytes = maxPendingBytes
    }

    /// SDWebImage 가 저장을 요청하는 지점. 디스크가 포함된 요청만 가로챈다.
    override func store(_ image: UIImage?, imageData: Data?, forKey key: String?,
                        cacheType: SDImageCacheType, completion: (() -> Void)?) {
        guard cacheType == .all || cacheType == .disk,
              let key, let data = imageData, !data.isEmpty else {
            super.store(image, imageData: imageData, forKey: key,
                        cacheType: cacheType, completion: completion)
            return
        }

        // 메모리는 **즉시** — 미루는 건 디스크뿐이다. 메모리까지 미루면 방금 받은
        // 이미지를 표시 경로가 다시 디코드한다.
        if cacheType == .all, image != nil {
            super.store(image, imageData: data, forKey: key, cacheType: .memory, completion: nil)
        }

        let overCap = state.withLock { pending -> Bool in
            pending.append(Pending(key: key, data: data))
            return pending.reduce(0) { $0 + $1.data.count } > maxPendingBytes
        }

        // **completion 의 의미가 부모와 다르다**: 여기서는 "메모리 반영 완료" 이지
        // "디스크 기록 완료" 가 아니다. 디스크까지 보장이 필요한 호출부는
        // `flushPendingDiskWrites(completion:)` 를 써야 한다(테스트의 디스크 시드가 그 예).
        if overCap {
            flushPendingDiskWrites(completion: nil)
        } else {
            scheduleQuietFlush()
        }
        completion?()
    }

    /// 대기 중인 디스크 쓰기를 모두 내보낸다. 백그라운드 진입 시에도 호출한다 —
    /// 그때 안 쓰면 세션에서 받은 이미지가 통째로 날아간다.
    func flushPendingDiskWrites(completion: (() -> Void)? = nil) {
        // 예약된 디바운스를 무효화(세대 번호를 올려 깨어난 블록이 스스로 물러난다).
        generation.withLock { $0 &+= 1 }
        let batch = state.withLock { pending -> [Pending] in
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
        guard !batch.isEmpty else { completion?(); return }

        let group = DispatchGroup()
        for entry in batch {
            group.enter()
            super.store(nil, imageData: entry.data, forKey: entry.key,
                        cacheType: .disk) { group.leave() }
        }
        if let completion {
            group.notify(queue: .main) { completion() }
        }
    }

    private func scheduleQuietFlush() {
        let mine = generation.withLock { current -> Int in
            current &+= 1
            return current
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + quietWindow) { [weak self] in
            guard let self, self.generation.withLock({ $0 }) == mine else { return }
            self.flushPendingDiskWrites(completion: nil)
        }
    }
}
