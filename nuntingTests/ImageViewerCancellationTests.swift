import XCTest
import SDWebImage
@testable import nunting

/// 뷰어 디코드의 취소 브리지(`ImageViewer.OperationBox`) 계약.
///
/// `.task(id:)` 취소는 continuation 대기만 깨울 뿐 SDWebImage operation 은
/// 계속 돈다 — 극단 세로형의 20MP 2차 디코드가 뷰어를 닫은 뒤에도 CPU/메모리
/// 를 소모했다(Codex P2). onCancel(임의 스레드)과 operation 등록(메인) 사이
/// 레이스까지 포함해 "취소는 정확히 한 번, 등록 순서와 무관" 을 핀한다.
final class ImageViewerCancellationTests: XCTestCase {
    private final class FakeOperation: NSObject, SDWebImageOperation, @unchecked Sendable {
        private(set) var cancelCount = 0
        func cancel() { cancelCount += 1 }
    }

    func testCancelAfterStoreCancelsOperation() {
        let box = ImageViewer.OperationBox()
        let op = FakeOperation()
        box.store(op)
        box.cancel()
        XCTAssertEqual(op.cancelCount, 1)
    }

    func testStoreAfterCancelCancelsImmediately() {
        // onCancel 이 store 보다 먼저 도착하는 레이스 — 뒤늦게 등록된
        // operation 도 즉시 취소돼야 한다.
        let box = ImageViewer.OperationBox()
        let op = FakeOperation()
        box.cancel()
        box.store(op)
        XCTAssertEqual(op.cancelCount, 1)
    }

    func testNoCancelWithoutCancellation() {
        let box = ImageViewer.OperationBox()
        let op = FakeOperation()
        box.store(op)
        XCTAssertEqual(op.cancelCount, 0)
    }
}
