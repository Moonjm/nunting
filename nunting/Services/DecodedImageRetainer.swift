import Foundation
import os
import UIKit

/// 방금 디코드한 비트맵을 **아주 잠깐** 강하게 붙잡는다.
///
/// 왜 필요한가 — SDWebImage 는 같은 URL 에 두 요청이 오면 다운로드를 공유하고 토큰만
/// 추가하는데(`SDWebImageDownloader.m:254/262`), **디코드는 토큰마다 돈다**
/// (`SDWebImageDownloaderOperation.startCoderOperationWithImageData`). 재사용용
/// `imageMap` 이 있지만 값이 weak 이라(`SDWebImageDownloaderOperation.m:119` —
/// `NSPointerFunctionsWeakMemory`), 첫 디코드 결과를 그 찰나에 아무도 강하게 잡고
/// 있지 않으면 엔트리가 비고 두 번째 토큰이 같은 바이트를 통째로 다시 디코드한다.
///
/// 우리 앱에서 그 두 요청은 본문 이미지 프리페치와 표시 로드다(컨텍스트를 일부러
/// 맞춰놔서 `decodeOptions` 는 동일 — 키 불일치가 아니라 순수 수명 문제다).
/// 기기 계측(2026-08-21): webpStatic 214건 중 46쌍(42%)이 **같은 출력 크기로 0~1초
/// 간격** 중복이었고 그 중복분이 전체 디코드 시간의 24%. 9.85MP 짜리는 1,025ms +
/// 1,056ms 로 한 장에 2초를 썼다. 첫 결과를 잠깐만 살려두면 그 쌍이 사라진다.
///
/// 성격을 분명히 해두자: 이건 라이브러리의 weak 캐시를 밖에서 떠받치는 **우회**다.
/// SDWebImage 의 설계를 고치는 게 아니라 그 설계의 타이밍 틈을 메운다. 그래서
/// 붙잡는 창을 짧게 두고(형제 토큰의 디코드 블록은 같은 직렬 `coderQueue` 에서
/// 곧바로 뒤따른다) 상한을 건다.
///
/// 상한이 이 타입의 본체인 이유: 9.8MP 한 장이 ~39MB 다. 장수만 세면 메모리가 안
/// 잡히고, 이 앱에는 OOM 이력이 있다. 그래서 장수·바이트·시간 세 축을 전부 건다.
///
/// 격리: 디코드는 오퍼레이션마다 별도 `coderQueue` 에서 도므로 여러 스레드가 동시에
/// 들어온다. `nonisolated` + 락.
nonisolated final class DecodedImageRetainer: Sendable {
    static let shared = DecodedImageRetainer()

    private struct Entry {
        let image: UIImage
        let bytes: Int
        let at: Date
    }

    private let maxCount: Int
    private let maxBytes: Int
    private let window: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: [Entry]())

    /// - Parameters:
    ///   - maxCount: 동시에 붙잡는 최대 장수.
    ///   - maxBytes: 붙잡은 비트맵 합계 상한. 형제 토큰 한 쌍을 살리는 게 목적이라
    ///     큰 값이 필요 없다 — 9.8MP 두 장(≈78MB)이 들어갈 만큼이면 충분하다.
    ///   - window: 이보다 오래된 항목은 놓는다. 형제 디코드는 곧바로 뒤따르므로
    ///     1초면 넉넉하고, 길게 잡으면 "잠깐 붙잡기" 가 아니라 캐시가 된다.
    init(maxCount: Int = 4, maxBytes: Int = 80 * 1024 * 1024, window: TimeInterval = 1) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.window = window
    }

    /// 디코드 직후 호출. `bytes` 는 비트맵 크기 추정치(픽셀×4).
    func hold(_ image: UIImage, bytes: Int, now: Date = Date()) {
        state.withLock { entries in
            // 만료분 정리 — 타이머 없이 삽입 시점에만 한다. 새 디코드가 없으면
            // 마지막 몇 장이 남지만 그 총량은 상한이 이미 묶는다.
            entries.removeAll { now.timeIntervalSince($0.at) > window }

            // 상한보다 큰 한 장은 아예 안 받는다 — 받아도 상한을 넘고, 그 한 장이
            // 나머지를 전부 밀어내면 정작 중복 제거 효과가 사라진다.
            guard bytes <= maxBytes else { return }

            entries.append(Entry(image: image, bytes: bytes, at: now))
            while entries.count > maxCount { entries.removeFirst() }
            var total = entries.reduce(0) { $0 + $1.bytes }
            while total > maxBytes, entries.count > 1 {
                total -= entries.removeFirst().bytes
            }
        }
    }

    /// 테스트용 — 지금 붙잡고 있는 장수.
    var heldCount: Int { state.withLock { $0.count } }

    /// 계측 배치에 실리는 설정 라벨. 상한을 조정한 세션과 원래 세션이 표에서
    /// 섞이지 않게 값 자체를 라벨에 넣는다("retain=장수/MB/초").
    var configLabel: String {
        "retain=\(maxCount)/\(maxBytes / (1024 * 1024))/\(Int(window))"
    }
}
