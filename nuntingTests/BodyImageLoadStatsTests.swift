import SDWebImage
import XCTest
@testable import nunting

/// `BodyImageLoadStats` — 본문 이미지 로드 출처 집계의 계약.
///
/// 이 진단의 결론(메모리 캡 200MB 를 올릴 것인가)이 전적으로 `r=`(재로드)
/// 버킷의 disk 값에서 나오므로, 첫 로드/재로드 분리와 라벨 포맷이 틀리면
/// 계측 자체가 무의미해진다 — 그래서 그 둘을 여기서 못박는다.
@MainActor
final class BodyImageLoadStatsTests: XCTestCase {

    private var emitted: [String] = []
    private var stats: BodyImageLoadStats!

    override func setUp() async throws {
        try await super.setUp()
        stats = BodyImageLoadStats.shared
        // 앞선 테스트/앱 배선이 남긴 집계를 조용히 버리고 시작.
        stats.emit = { _ in }
        stats.flush()
        emitted = []
        stats.emit = { [weak self] label in self?.emitted.append(label) }
    }

    override func tearDown() async throws {
        stats.emit = { _ in }
        stats.flush()
        try await super.tearDown()
    }

    private let oneMB = 1024 * 1024

    func testFirstLoadAndRepeatLoadAreCountedSeparately() {
        stats.begin(postID: "1412160")
        stats.record(key: "a", cacheType: .none, bytes: 10 * oneMB)   // 첫 로드(네트워크)
        stats.record(key: "b", cacheType: .disk, bytes: 20 * oneMB)   // 첫 로드(디스크)
        stats.record(key: "a", cacheType: .memory, bytes: 10 * oneMB) // 재진입 — 캐시 히트
        stats.record(key: "b", cacheType: .disk, bytes: 20 * oneMB)   // 재진입 — 축출됨
        stats.flush()

        XCTAssertEqual(emitted, ["imgcache:f=m0/d1/n1,r=m1/d1/n0,MB=30,id=1412160"])
    }

    func testRepeatLoadsDoNotInflateByteBudget() {
        // MB 는 "이 글이 캐시에 요구하는 예산" 이라 유니크 이미지 기준이어야
        // 한다 — 재로드를 더하면 스크롤을 많이 한 글일수록 예산이 부풀어
        // 캡 결정을 왜곡한다.
        stats.begin(postID: "p")
        for _ in 0..<5 { stats.record(key: "same", cacheType: .disk, bytes: 40 * oneMB) }
        stats.flush()

        XCTAssertEqual(emitted, ["imgcache:f=m0/d1/n0,r=m0/d4/n0,MB=40,id=p"])
    }

    func testFlushIsNoOpWhenNothingRecorded() {
        stats.begin(postID: "empty")
        stats.flush()
        stats.flush()
        XCTAssertEqual(emitted, [], "빈 집계는 타임라인을 오염시키지 않는다")
    }

    func testBeginEmitsPreviousPostBeforeResetting() {
        // 글 전환은 flush 지점이기도 하다 — 직전 글 집계를 잃지 않아야 하고,
        // 그 집계가 **직전 글 id** 로 찍혀야 한다(상세 뷰는 keep-alive 라
        // 전환 시점의 post.id 는 이미 새 글이다).
        stats.begin(postID: "old")
        stats.record(key: "x", cacheType: .memory, bytes: oneMB)
        stats.begin(postID: "new")

        XCTAssertEqual(emitted, ["imgcache:f=m1/d0/n0,r=m0/d0/n0,MB=1,id=old"])

        stats.record(key: "y", cacheType: .none, bytes: 2 * oneMB)
        stats.flush()
        XCTAssertEqual(emitted.last, "imgcache:f=m0/d0/n1,r=m0/d0/n0,MB=2,id=new",
                       "새 글 집계는 이전 글 카운트를 물려받지 않는다")
    }

    func testLabelTruncatesLongPostIDFromTheFront() {
        // 서버가 라벨을 뒤에서 80 runes 로 자르므로 고엔트로피 tail 을 남긴다
        // (`PostDetailLoader.mediaLabel` 과 같은 규율). 애객 미러처럼 원본
        // URL 을 통째로 담은 id 가 이 경로.
        let longID = "issue-2026-08-15/issue/?idx=987654"
        let label = BodyImageLoadStats.label(
            first: "m0/d2/n8", repeated: "m14/d6/n0", megabytes: 214, postID: longID)

        XCTAssertTrue(label.hasSuffix(",id=" + String(longID.suffix(24))))
        XCTAssertLessThanOrEqual(label.count, 80, "서버 상한(80 runes) 안")
    }

    func testLabelOmitsIDWhenUnknown() {
        XCTAssertEqual(
            BodyImageLoadStats.label(first: "m0/d0/n1", repeated: "m0/d0/n0",
                                     megabytes: 0, postID: nil),
            "imgcache:f=m0/d0/n1,r=m0/d0/n0,MB=0")
    }

    /// 바이트 계산은 SD 의 비용 축(`bytesPerRow × height`)과 같아야 캡 대비
    /// 비율이 의미를 갖는다.
    func testDecodedBytesMatchesBitmapResidency() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 4)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 4))
        }
        let cgImage = try? XCTUnwrap(image.cgImage)
        XCTAssertEqual(BodyImageLoadStats.decodedBytes(of: image),
                       (cgImage?.bytesPerRow ?? 0) * (cgImage?.height ?? 0))
    }
}
