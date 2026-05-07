# 본문 미디어 리팩토링 — 웹같은 인라인 자동재생

## 1. 목표

본문 콘텐츠를 **모바일 Safari처럼 인라인으로 자동 재생**되게 한다. 사용자가 매번 탭해서 열어볼 필요 없이, 화면에 들어오면 알아서 보이고/움직이고/재생된다.

대상:
- 정적 이미지 — 이미 자동 표시 ✓
- 애니메이션 WebP / GIF / APNG — 자동재생 ✓ (단 현재 디코드 느림)
- **본문 mp4 / mov / webm 영상** — **현재 탭해서 봐야 함 → 인라인 자동재생으로 전환**

대상 외:
- YouTube 임베드 — 현 동작 유지 (썸네일 + 외부 열기). iframe 임베드 작업은 보류.

대표 페인포인트:
- `https://m.ppomppu.co.kr/new/bbs_view.php?id=car&no=969082` — 애니메이션 WebP 2개(2.3MB + 991KB)가 가만히 있어도 버벅거림.
- 본문 영상은 보드별로 빈도 다름 (etoland/clien에 흔함).

## 2. 현재 구조 요약

- `PpomppuParser.swift:283-429` 외 — `<img>` 전부 `.image(url)` 단일 타입. 정적/애니메이션 구분 없음.
- `Post.swift:53-83` — `ContentBlock`은 `.image(url, aspectRatio)` / `.video(url, posterURL)` 두 가지뿐.
- `CachedAsyncImage.swift` — fetch + ImageIO 디코드. multi-frame이면 `AnimatedImageView` → `DisplayLinkAnimatedImageView`(CADisplayLink + 12프레임 LRU)로 라우팅.
- 비디오 블록 렌더링은 `PostDetailView`에서 포스터 + 탭하면 풀스크린 플레이어 (별도 화면).

병목 지점:
1. **ImageIO 애니메이션 WebP 디코드가 libwebp 대비 2~3배 느림.**
2. **12프레임 LRU evict 시 display link tick 안에서 동기 디코드** — 메인 스레드 블로킹.
3. **본문 영상은 인라인 재생 자체가 없음** — UX 일관성 부재.

## 3. 시도/검토 경위 요약

| 안 | 내용 | 결론 |
|---|---|---|
| A | fps 30 캡 + 메모리 예산 내 전 프레임 사전 디코드 + race fix | **시도/원복.** 효과 일부, 잔존 버벅임 — ImageIO 자체가 한계. |
| B | libwebp 직접 또는 WebP 코덱만 교체 | 라이브러리 도입에 흡수되므로 단독 추진 보류. |
| C | 애니메이션 WebP → MP4 변환 + AVPlayer | 천장 효과 가장 높지만 작업량 큼. **장기 옵션.** |
| D | Kingfisher 또는 SDWebImage 또는 Nuke 도입 | **D + E 채택.** 아래 4번. |
| E | 본문 mp4/mov 인라인 자동재생 (`InlineVideoPlayerView` + `VideoPlayerPool`) | **신규 채택** — UX 통일. |

## 4. 선택: SDWebImage + InlineVideoPlayer

라이브러리: **SDWebImage + SDWebImageWebPCoder + SDWebImageSwiftUI**

선택 사유:
1. **WebP/GIF/APNG/HEIF/AVIF를 단일 `AnimatedImage` 뷰가 통합 처리** — 현재의 정적/애니메이션 분기 코드(`CachedAsyncImage`의 multi-frame 검출)가 라이브러리 안으로 들어가서 사라짐.
2. **`SDWebImageWebPCoder`는 SDWebImage org의 공식 플러그인**. Kingfisher의 WebP 플러그인은 third-party(yeatse, 1인 메인테이너).
3. **2026-05 기준 stars 25.7k (vs Kingfisher 24.3k, Nuke 8.6k)**. 활발히 유지 중.
4. "본문의 모든 미디어를 통합 컨테이너로 다룬다"는 사상이 다음 단계(인라인 비디오)와 맞물림.

라이브러리만으로는 안 되는 것: **본문 mp4/mov 인라인 자동재생.** 이는 `AVPlayer` 직접 + 풀링/visibility 관리로 별도 구현.

## 5. 콘텐츠 타입별 변경 범위

| 타입 | 현재 | 이후 |
|---|---|---|
| 정적 이미지 | `CachedAsyncImage` | SD `AnimatedImage` (정적 자동 처리) |
| 애니메이션 WebP/GIF/APNG | `CachedAsyncImage` → `DisplayLinkAnimatedImageView` | SD `AnimatedImage` (libwebp 디코드, 자동재생) |
| mp4/mov/webm | 포스터 + 탭하면 풀스크린 | **`InlineVideoPlayerView` 인라인 muted autoplay loop** |
| YouTube | 썸네일 + 외부 링크 | **변경 없음** |

## 6. 라이브러리 기본값으로 안 덮이는 커스텀 로직

도입 시 사라지면 회귀가 생기는 항목들. 얇은 SwiftUI 래퍼 또는 SD 설정으로 보존 필요.

| 기능 | 현 위치 | 왜 필요한가 |
|---|---|---|
| `visibilityGated` | `CachedAsyncImage.swift:46`, `:174-195` | 30개 이미지 글에서 진입 즉시 30개 fetch 큐잉 방지. `LazyVStack`이 ~2-3 화면 분량 미리 realize하므로 `WebImage`/`AnimatedImage` 단독으론 부족. **인라인 비디오에도 같은 게이트 적용 필수.** |
| `ImageDataLoader` URL 중복제거 | `CachedAsyncImage.swift:1008-1112` | 이전 디테일 teardown + 새 디테일 appear가 동일 URL 동시 요청 시 한 번만. SD의 `SDWebImageDownloader`도 일부 dedup함 — 동작 정책 검증. |
| `ImageThrottle` (fetch 4 / decode 2 분리) | `CachedAsyncImage.swift:1114-1129` | I/O와 CPU 예산 분리. SD는 단일 동시성 캡 — 분리 효과 잃을 가능성. 측정 후 결정. |
| `loadPriority` (block index 기반 top-down) | `CachedAsyncImage.swift:21`, `:267` | 글 위에서부터 순차 로드. SD의 `SDWebImageContextOption`에 priority 있음. |
| Aspect-ratio / natural-width 프라임 캐시 | `CachedAsyncImage.swift:91-101` | LazyVStack 재realize 시 첫 layout부터 최종 크기 잡아 점프 방지. SD 도입 시에도 별도 캐시 유지. |
| Tap-to-retry 실패 UI | `CachedAsyncImage.swift:132-158` | ppomppu/aagag/humor에서 가끔 발생하는 산발적 fail 대응. SD의 `onFailure` 분기로 재현. |
| First-attempt 8s timeout + 1회 retry (-1005/-1001/-1004) | `CachedAsyncImage.swift:1062-1107` | 백그라운드 복귀 후 stale keep-alive 끊김 케이스. SD의 `SDWebImageDownloaderConfig.timeout` + 자체 retry로 이식. |
| `clampsToNaturalWidth` | `CachedAsyncImage.swift:29`, `:167` | 127×100 placeholder 업스케일 방지. modifier 단계에서 처리. |

## 7. 권장 진입 형태

### 7.1 이미지 (정적 + 애니메이션 통합)

```swift
struct VisibilityGatedAnimatedImage: View {
    let url: URL
    let aspectRatio: CGFloat?
    let priority: SDWebImagePriority   // 본문 이미지 = block index 기반

    @State private var hasBeenVisible = false

    var body: some View {
        AnimatedImage(url: hasBeenVisible ? url : nil)   // url=nil이면 SD 로드 안 함
            .placeholder { Color("AppSurface2") }
            .onFailure { _ in /* 재시도 UI */ }
            .resizable()
            .scaledToFit()
            .aspectRatio(aspectRatio, contentMode: .fit)
            .onScrollVisibilityChange(threshold: 0) { visible in
                if visible { hasBeenVisible = true }     // 단방향 플립
            }
    }
}
```

핵심:
- `AnimatedImage`는 정적/애니메이션 자동 분기 — 호출부 코드 단순.
- `hasBeenVisible` **단방향 플립** (양방향이면 스크롤 벗어날 때 unmount → 깜빡임).
- `url: nil` 패턴으로 mount/unmount 없이 로드만 차단.

### 7.2 본문 비디오 (mp4/mov 인라인)

```swift
struct InlineVideoPlayerView: UIViewRepresentable {
    let url: URL
    let aspectRatio: CGFloat?

    func makeUIView(context: Context) -> VideoPlayerView {
        let v = VideoPlayerView()
        v.url = url
        return v
    }

    func updateUIView(_ v: VideoPlayerView, context: Context) {
        if v.url != url { v.url = url }
    }
}

private final class VideoPlayerView: UIView {
    var url: URL? { didSet { if url != oldValue { reload() } } }

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var leaseToken: VideoPlayerPool.LeaseToken?

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { releaseLease() }
    }

    func bindVisibility(_ visible: Bool) {
        if visible {
            acquireLeaseAndPlay()
        } else {
            player?.pause()      // pause는 lease 유지 (resume 빠름)
        }
    }

    private func acquireLeaseAndPlay() {
        guard let url else { return }
        leaseToken = VideoPlayerPool.shared.lease(for: url) { [weak self] player in
            guard let self else { return }
            self.player = player
            if self.playerLayer?.player !== player {
                self.playerLayer?.removeFromSuperlayer()
                let layer = AVPlayerLayer(player: player)
                layer.videoGravity = .resizeAspect
                self.layer.addSublayer(layer)
                self.playerLayer = layer
                self.setNeedsLayout()
            }
            player.isMuted = true
            player.play()
        }
    }

    private func releaseLease() {
        player?.pause()
        leaseToken?.release()
        leaseToken = nil
    }
}
```

핵심:
- `isMuted = true` — iOS의 unmute 자동재생 정책 회피. user gesture 없이 인라인 재생 가능.
- `actionAtItemEnd = .none` + observer로 `seek(.zero)` → loop.
- `playsinline` 개념은 AVPlayer엔 없음 (기본이 인라인). 풀스크린 모드만 명시 필요.
- **lease 패턴**: `VideoPlayerPool`에서 AVPlayer 인스턴스 풀을 관리, 동시 활성 캡 초과 시 가장 오래되거나 화면에서 가장 먼 lease를 회수.

### 7.3 VideoPlayerPool

```swift
actor VideoPlayerPool {
    static let shared = VideoPlayerPool()

    private let maxConcurrent = 3   // 활성 AVPlayer 동시 캡
    private struct Lease { let url: URL; let player: AVPlayer; let acquiredAt: Date }
    private var active: [UUID: Lease] = [:]

    struct LeaseToken {
        let id: UUID
        func release() { Task { await VideoPlayerPool.shared.releaseLease(id: id) } }
    }

    func lease(for url: URL, install: @MainActor @escaping (AVPlayer) -> Void) -> LeaseToken {
        // 동일 URL에 이미 active lease가 있으면 그 player 재사용 (예: 같은 영상이 두 번 등장하는 글)
        // 캡 초과면 가장 오래된 lease 강제 회수
        // 새 AVPlayer 생성 + install 콜백으로 호출자에게 전달
        // ...
    }

    func releaseLease(id: UUID) {
        guard let lease = active.removeValue(forKey: id) else { return }
        lease.player.pause()
        lease.player.replaceCurrentItem(with: nil)   // 디코더 즉시 release
    }
}
```

핵심:
- **동시 활성 AVPlayer 3개로 캡**. 4번째 비디오가 visible로 들어오면 가장 오래된 lease 회수 (그 비디오는 first frame poster만 남음).
- AVPlayer 인스턴스당 ~10-20MB + 디코더 자원. 캡 없으면 5개 영상 글에서 100MB+ 잡힘.

### 7.4 visibility 통합

`VisibilityGatedAnimatedImage`와 `InlineVideoPlayerView` 모두 같은 `onScrollVisibilityChange` 패턴.
- 이미지: `hasBeenVisible` 단방향 플립.
- 비디오: 양방향 (`bindVisibility(true/false)`로 play/pause). 유튜브 자동재생과 동일한 UX.

## 8. 셀룰러/배터리 정책

데이터/배터리/발열을 의식해야 함. Safari도 셀룰러에선 자동재생 막는 설정이 있음.

- **`NWPathMonitor`로 expensive interface 감지** — 셀룰러면 비디오 자동재생 비활성화 (poster + 탭 재생으로 fallback). 이미지/애니메이션 WebP는 자동재생 유지.
- **Settings 토글 추가** — "Wi-Fi에서만 비디오 자동재생" / "항상 자동재생" / "탭 재생". 기본 = "Wi-Fi에서만".
- **Low Power Mode 감지** — `ProcessInfo.processInfo.isLowPowerModeEnabled` 시 모든 자동재생 비활성화.

## 9. 단계별 작업 계획

1. **SPM 추가**
   - `https://github.com/SDWebImage/SDWebImage`
   - `https://github.com/SDWebImage/SDWebImageWebPCoder`
   - `https://github.com/SDWebImage/SDWebImageSwiftUI`
2. **SDWebImage 초기 설정**
   - WebP 코덱 등록: `SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)`
   - 메모리 캐시 cap 설정 (현 `ImageCache.shared` 200MB와 동등)
   - 디스크 캐시 정책 (예: 만료 1주, 최대 500MB)
   - 다운로더 timeout / retry
3. **`VisibilityGatedAnimatedImage` 래퍼 추가** (7.1).
4. **`PostDetailView` 본문 이미지 1곳만 먼저 교체** → ppomppu 969082 글에서 측정. 가만히/스크롤 모두 체감 + Instruments로 메인 스레드 점유 비교.
5. 회귀 없으면 **나머지 caller(댓글 아이콘/스티커/영상 포스터/유튜브 썸네일) 점진 교체**. 각 caller는 visibilityGated/clampsToNaturalWidth 등 옵션 차등 적용.
6. **`InlineVideoPlayerView` + `VideoPlayerPool` 추가** (7.2, 7.3).
7. **`PostDetailView`의 `.video()` 블록 렌더링을 새 뷰로 교체**. 파서 수정 불필요.
8. **셀룰러/Low Power 정책 + Settings 토글** (8번 참조).
9. **`CachedAsyncImage` 제거** — 모든 caller 마이그레이션 완료 후. `ImageDataLoader` / `ImageThrottle` / `ImageCache`는 SD 설정으로 효과 동등하면 제거, 아니면 어댑터로 유지.
10. **DEBUG 가드 이식** — `visibilityGated` 래퍼가 ScrollView 밖에 놓여 영원히 placeholder만 뜨는 상황을 1초 후 콘솔 경고 (현 `CachedAsyncImage.swift:205-213`).

## 10. 측정 기준 (회귀 가드)

이전 vs 이후를 같은 디바이스/네트워크에서:

**이미지**
- ppomppu 969082 진입 후 **첫 화면 첫 이미지 displayed 시간** (목표 ≤0.5s).
- 본문 끝까지 스크롤 시 **메인 스레드 사용률** (애니메이션 2개 동시 재생 중 ≤15% 목표; 현 ~30-40% 추정).
- **가만히 있을 때 메인 스레드 사용률** (애니메이션 재생 중에도 ~5% 이하).
- **콜드 스타트 후 직전 본 글 재진입 시 첫 이미지 displayed 시간** — SD 디스크 캐시 효과 직접 측정.
- 상세 진입 직후 **fetch 큐 깊이** (visibilityGated 동작 확인, 기대값 = 화면에 보이는 이미지 수).

**비디오 (신규)**
- 본문 영상 등장 글 진입 시 **자동재생 시작까지 시간** (목표 ≤1s, Wi-Fi).
- 활성 AVPlayer 인스턴스 수 (`VideoPlayerPool` 캡 검증, ≤3).
- 비디오 5개 글 스크롤 시 **메모리 피크** (캡 없이는 100MB+, 캡 있으면 ≤60MB 목표).
- 셀룰러 환경에서 자동재생 차단 동작 확인.

## 11. 트레이드오프 (사용자에게 노출되는 것)

- **데이터 사용량 증가** — 본문 영상 자동재생이 데이터 소비. 셀룰러 정책 + Settings 토글로 완화.
- **배터리** — AVPlayer는 디코더/GPU 사용, 발열/배터리 영향. Low Power Mode 자동 비활성화 + 캡으로 완화.
- **메모리** — AVPlayer 활성 3개 = ~30-60MB 추가 상시. 디바이스에 여유 있는 한 OK.
- **사용자 기대 차이** — "탭해야 재생되던" 영상이 갑자기 자동재생되면 혼란 가능. 첫 릴리스 changelog에 명시.

## 12. 보류 / 후속

- **YouTube 인라인 자동재생** (WKWebView + iframe). 본 작업 마치고 별도 결정. 추적/광고 이슈 + 구현 비용 vs UX 통일성 저울.
- **C안 — 애니메이션 WebP → MP4 변환 + AVPlayer**. SD 적용 후에도 ProMotion에서 두 애니메이션 동시 재생 부드럽지 않으면 검토. 변환 후 `VideoPlayerPool` 인프라 그대로 활용 가능.
- **Parser 단계에서 애니메이션 여부 사전 판별** — 디코드 전 URL 확장자/HEAD 응답으로 미리 알면 게이트 정책 차등화 가능.
- **`ContentBlock`에 `.animatedImage` 추가** — 정적/애니메이션 분리 모델로 가야 정적 path를 더 가볍게 갈 수 있음. SD 적용 후 자연스럽게 따라오는 리팩토링.
- **비디오 사운드 토글 UX** — 시작은 muted, 탭하면 unmute. 어디서 탭 받을지 (오버레이? 탭 영역?) UX 결정 필요.
