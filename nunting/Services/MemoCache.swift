import Foundation

/// Hashable 키로 비싼 순수 계산을 NSCache 에 메모이즈하는 제네릭 헬퍼.
/// 댓글 `styledCache`(NSString 키 한정)의 일반화 — 임의 Hashable 키를
/// `isEqual`/`hash` 를 위임하는 KeyBox 로 감싸 NSCache 에 싣는다. 해시가
/// 충돌해도 `isEqual` 이 내용을 비교하므로 다른 키의 값이 새지 않는다.
///
/// NSCache 를 쓰는 이유: countLimit 으로 정상 상태 크기를 묶고 메모리
/// 압박 시 시스템이 알아서 비운다 — 긴 세션에서 무한 증가하지 않는다.
/// NSCache 자체는 thread-safe; compute 가 경합 중 두 번 실행될 수 있으나
/// 순수 함수 전제라 무해하다(마지막 쓰기가 남을 뿐).
// nonisolated(타입 단위): NSCache 는 thread-safe 고 이 래퍼는 그 위임뿐 —
// 기본 MainActor 격리에서 빼 nonisolated 테스트/호출부가 직접 쓸 수 있게.
nonisolated final class MemoCache<Key: Hashable, Value> {
    // nonisolated: NSObject 의 `isEqual`/`hash` 는 nonisolated 선언이라,
    // 기본 MainActor 격리 추론이 붙은 오버라이드는 Swift 6 모드에서
    // "different actor isolation" 에러가 된다. 순수 값 래퍼라 격리 불필요.
    nonisolated private final class KeyBox: NSObject {
        let key: Key
        init(_ key: Key) { self.key = key }
        override func isEqual(_ object: Any?) -> Bool {
            (object as? KeyBox)?.key == key
        }
        override var hash: Int { key.hashValue }
    }

    private final class ValueBox {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private let cache = NSCache<KeyBox, ValueBox>()

    init(countLimit: Int) {
        cache.countLimit = countLimit
    }

    func value(for key: Key, compute: (Key) -> Value) -> Value {
        let box = KeyBox(key)
        if let cached = cache.object(forKey: box) {
            return cached.value
        }
        let result = compute(key)
        cache.setObject(ValueBox(result), forKey: box)
        return result
    }
}
