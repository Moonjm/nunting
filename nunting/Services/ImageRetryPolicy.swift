import Foundation
import SDWebImage

/// 이미지 로드 실패에서 **회복하는** 규칙.
///
/// `SDWebImageManager` 는 실패한 URL 을 `failedURLs` 에 넣고, 이후
/// `SDWebImageRetryFailed` 옵션 없는 로드를 네트워크에 보내지 않고 즉시
/// `SDWebImageErrorBlackListed` 로 끊는다(`SDWebImageManager.m:221`).
/// 본문 이미지는 옵션 없이(`AnimatedImage`) 로드하므로 이 블랙리스트에
/// 그대로 걸린다. 시뮬레이터 실측:
///
///   1차 로드         → BadImageData (1001)  0.58s   ← 네트워크를 탐
///   2차 "다시 시도"   → BlackListed  (1003)  0.00s   ← 네트워크를 안 탐
///
/// 즉 사용자가 "다시 시도" 를 눌러도 같은 실패가 0초 만에 되돌아온다 —
/// 앱을 껐다 켜기 전까지 그 이미지는 영영 안 뜬다(실사용 보고: 다모앙
/// 7036127, 3.34MB/30.5MP 세로 짤이 다시 시도로 고착). 블랙리스트에 걸리는
/// 경로는 디코드 실패(`BadImageData`)와 비-transient URL 에러이고, 다운로드가
/// 백그라운드 전환으로 잘려 데이터가 불완전해도 `BadImageData` 가 된다.
///
/// 그래서 블랙리스트 자체는 유지하되(자동 로드가 죽은 URL 을 계속 두드리는
/// 걸 막는 보호막이다), **사람이 의도를 표시한 순간**과 **조건이 바뀐 순간**
/// 두 곳에서만 명시적으로 푼다.
@MainActor
enum ImageRetryPolicy {

    /// 프로덕션 배선. 테스트가 스파이로 갈아끼운다(`MemoryPressureResponder`
    /// 의 seam 과 같은 결 — SDK 싱글턴을 건드리지 않고 배선을 핀).
    static var clearFailedURL: (URL) -> Void = {
        SDWebImageManager.shared.removeFailedURL($0)
    }
    static var clearAllFailedURLs: () -> Void = {
        SDWebImageManager.shared.removeAllFailedURLs()
    }

    /// 사용자가 "다시 시도" 를 눌렀을 때. **`atsSafe` 로 정규화해서** 지운다 —
    /// 블랙리스트의 키는 실제로 로드한 URL 이라(본문 이미지는 `url.atsSafe`
    /// 로 로드한다) 원본 `http://` URL 을 지우면 아무 일도 일어나지 않는다.
    static func prepareRetry(for url: URL) {
        clearFailedURL(url.atsSafe)
    }

    /// 포그라운드 복귀. 실패의 흔한 방아쇠가 "다운로드 중 백그라운드 전환"
    /// 이라, 돌아온 시점엔 실패 이력이 더 이상 현재 조건을 반영하지 않는다 —
    /// 통째로 비워 다음 표시에서 자연히 재시도되게 한다. 성공한 이미지는
    /// 캐시에서 오므로 이 비움이 재다운로드를 유발하지 않는다.
    static func onForeground() {
        clearAllFailedURLs()
    }
}
