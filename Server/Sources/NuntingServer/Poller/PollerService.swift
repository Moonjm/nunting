import Foundation
import ServiceLifecycle

/// Hummingbird ServiceGroup이 SIGTERM 시 cancel 호출 → 루프가 종료.
/// `Service`는 swift-service-lifecycle의 프로토콜.
public struct PollerService: Service {
    private let poller: PpomppuPoller
    private let interval: Duration

    public init(poller: PpomppuPoller, interval: Duration = .seconds(180)) {
        self.poller = poller
        self.interval = interval
    }

    public func run() async throws {
        // 시작 직후 첫 tick (sentinel 잡기).
        await poller.tick()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch is CancellationError {
                return
            }
            await poller.tick()
        }
    }
}
