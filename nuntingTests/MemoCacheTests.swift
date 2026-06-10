import XCTest
@testable import nunting

/// `MemoCache` — Hashable 키로 비싼 계산을 NSCache 에 메모이즈하는 제네릭
/// 헬퍼. 본문 richText 의 NSDataDetector linkify + AttributedString 조립이
/// body 재평가마다 전 블록 재실행되던 것을 블록별 1회로 줄이는 데 쓴다
/// (댓글 styledCache 와 같은 역할의 일반화).
final class MemoCacheTests: XCTestCase {
    func testComputeRunsOncePerKey() {
        let cache = MemoCache<String, Int>(countLimit: 10)
        var computeCalls = 0
        func length(of key: String) -> Int {
            computeCalls += 1
            return key.count
        }
        XCTAssertEqual(cache.value(for: "하나") { length(of: $0) }, 2)
        XCTAssertEqual(cache.value(for: "하나") { length(of: $0) }, 2)
        XCTAssertEqual(cache.value(for: "하나") { length(of: $0) }, 2)
        XCTAssertEqual(computeCalls, 1, "같은 키 재조회는 캐시 히트여야 함")
    }

    func testDistinctKeysComputeSeparately() {
        let cache = MemoCache<String, Int>(countLimit: 10)
        var computeCalls = 0
        let a = cache.value(for: "a") { _ in computeCalls += 1; return 1 }
        let b = cache.value(for: "bb") { _ in computeCalls += 1; return 2 }
        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 2)
        XCTAssertEqual(computeCalls, 2)
    }

    func testHashCollisionDoesNotCrossContaminate() {
        // NSCache 키는 isEqual 로 판별돼야 함 — hashValue 충돌이 다른 키의
        // 값을 돌려주면 안 된다. 같은 hash 를 갖도록 강제할 수는 없으니,
        // 배열 키(본문 세그먼트와 같은 꼴)로 내용 동등성이 지켜지는지 확인.
        let cache = MemoCache<[String], String>(countLimit: 10)
        let ab = cache.value(for: ["a", "b"]) { $0.joined() }
        let ba = cache.value(for: ["b", "a"]) { $0.joined() }
        XCTAssertEqual(ab, "ab")
        XCTAssertEqual(ba, "ba", "키 내용이 다르면 다른 값이어야 함")
    }
}
