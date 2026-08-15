import Foundation
import SDWebImage
import UIKit

/// 본문 이미지 로드의 **출처**(memory / disk / network)를 글 단위로 집계해
/// footprint 타임라인에 한 점 남긴다. `SDImageCache` 메모리 캡(200MB)이 실제로
/// 병목인지 원격에서 판정하려고 넣은 **한시 진단**이다 — 결론이 나면 통째로
/// 제거한다(#118 의 leak 프로브 정리와 같은 취급).
///
/// ## 왜 첫 로드와 재로드를 나누나
///
/// 캡이 부족한지는 **재로드**에서만 드러난다. 첫 로드는 캐시에 없는 게 정상이라
/// disk/network 가 당연하고, 거기서 캡을 판단하면 늘 "부족" 처럼 보인다. 반대로
/// 이미 이 글에서 한 번 뜬 이미지가 다시 뜰 때 — `releasesWhenOffscreen` 이
/// 놓았다가 뷰포트 재진입, 또는 백그라운드 복귀 — memory 로 돌아오면 캡이
/// 충분한 것이고, disk 로 떨어지면 그 사이 NSCache 가 걷어갔다는 뜻이다.
/// 후자가 흰 슬롯 0.5~4.2s 의 직접 원인이므로, `r=` 의 d 값이 이 진단의 답이다.
///
/// ## MB 의 쓰임
///
/// 이 글 본문 이미지의 **유니크** 디코드 바이트 합. 캡 대비 몇 배인지가 그대로
/// "얼마로 올려야 하나" 의 답이 된다(캡 200MB, 세로 패널 1179×8192×4 ≈ 38MB).
/// SD 의 비용 계산과 같은 축으로 재려고 `CGImage` 의 `bytesPerRow × height` 를
/// 쓴다 — 애니메이션은 SD 도 poster 프레임 한 장만 계상하므로 그대로 일치한다.
///
/// 라벨 예: `imgcache:f=m0/d2/n8,r=m14/d6/n0,MB=214,id=1412160`
/// (서버 상한 80 runes 안 — `PostDetailLoader.mediaLabel` 과 같은 예산 규율.)
@MainActor
final class BodyImageLoadStats {
    static let shared = BodyImageLoadStats()

    /// 라벨 방출 seam — 프로덕션은 footprint 타임라인, 테스트는 스파이.
    /// `FootprintLogger.record` 를 직접 부르지 않는 이유는 그게 네트워크
    /// 배치를 건드리기 때문(`MemoryPressureResponder` 의 seam 과 같은 결).
    var emit: (String) -> Void = { FootprintLogger.shared.record($0) }

    private var postID: String?
    /// 이 글에서 이미 한 번 이상 성공한 캐시 키 — 첫 로드/재로드 판정축.
    private var seen: Set<String> = []
    private var first = Bucket()
    private var repeated = Bucket()
    private var uniqueBytes = 0

    private struct Bucket {
        var memory = 0, disk = 0, network = 0
        var isEmpty: Bool { memory == 0 && disk == 0 && network == 0 }
        var description: String { "m\(memory)/d\(disk)/n\(network)" }

        mutating func add(_ cacheType: SDImageCacheType) {
            switch cacheType {
            case .memory: memory += 1
            case .disk: disk += 1
            default: network += 1
            }
        }
    }

    private init() {}

    /// 새 글 시작 — 직전 글 집계를 먼저 내보내고 카운터를 리셋한다.
    /// 글 경계를 여기서 잡는 이유: 상세 뷰는 keep-alive 라 `post` 가 바뀌어도
    /// 뷰 identity 는 유지될 수 있어, flush 시점의 `post.id` 를 믿으면 직전 글
    /// 집계가 새 글 이름으로 찍힌다. 그래서 id 를 시작 시점에 못박는다.
    func begin(postID: String) {
        flush()
        self.postID = postID
    }

    /// 로드 1건 기록. `key` 는 SD 캐시 키(다운샘플 박스가 다르면 다른 이미지로
    /// 세는 게 맞다 — 실제로 별개 엔트리다).
    func record(key: String, cacheType: SDImageCacheType, bytes: Int) {
        if seen.insert(key).inserted {
            first.add(cacheType)
            uniqueBytes += bytes
        } else {
            repeated.add(cacheType)
        }
    }

    /// 뷰 계층에서 오는 편의 경로 — 바이트 계산을 한곳에 둔다.
    func record(url: URL, context: [SDWebImageContextOption: Any]?,
                cacheType: SDImageCacheType, image: UIImage) {
        guard let key = SDWebImageManager.shared.cacheKey(for: url, context: context) else { return }
        record(key: key, cacheType: cacheType, bytes: Self.decodedBytes(of: image))
    }

    /// 집계를 타임라인에 내보내고 리셋. 비어 있으면 no-op 이라 여러 경로에서
    /// 중복 호출해도 안전하다(글 전환 / 오버레이 닫힘 / 실제 teardown).
    func flush() {
        defer { reset() }
        guard !first.isEmpty || !repeated.isEmpty else { return }
        emit(Self.label(first: first.description,
                        repeated: repeated.description,
                        megabytes: uniqueBytes / (1024 * 1024),
                        postID: postID))
    }

    private func reset() {
        seen.removeAll(keepingCapacity: true)
        first = Bucket()
        repeated = Bucket()
        uniqueBytes = 0
        postID = nil
    }

    /// 라벨 조립 — 순수 함수라 포맷 계약을 테스트가 핀. id 는 맨 뒤이고 서버가
    /// 뒤에서 자르므로(`maxFootprintLabelRunes` 80), `mediaLabel` 과 같은 규칙
    /// 으로 고엔트로피 tail 24 runes 만 남긴다.
    nonisolated static func label(first: String, repeated: String,
                                  megabytes: Int, postID: String?) -> String {
        var label = "imgcache:f=\(first),r=\(repeated),MB=\(megabytes)"
        if let postID, !postID.isEmpty {
            label += ",id=\(postID.count <= 24 ? postID : String(postID.suffix(24)))"
        }
        return label
    }

    /// 디코드된 비트맵의 상주 바이트. `CGImage` 가 없으면(벡터 등) 포인트 크기
    /// × scale 로 근사한다.
    nonisolated static func decodedBytes(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return Int(pixels * 4)
    }
}
