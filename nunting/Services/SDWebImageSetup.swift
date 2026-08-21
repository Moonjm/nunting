import Foundation
import SDWebImage
import SDWebImageWebPCoder

/// One-shot SDWebImage configuration applied at app launch.
///
/// Registers the libwebp-backed coder so animated WebP (the dominant heavy
/// format on ppomppu / aagag bodies) decodes through libwebp instead of
/// ImageIO — measured 2-3× faster on multi-frame WebP and avoids the
/// per-frame `CGImageSource` random-access cost that pinned the previous
/// custom player's main thread.
///
/// Cache and downloader limits are sized for the same memory budget and
/// concurrent-fetch profile the previous pipeline used (200 MB memory
/// cache, 4 concurrent downloads); will tune from measurement once the
/// wrapper has run in production for a release.
enum SDWebImageSetup {
    static func configure() {
        // `addCoder` appends to the coders array, but
        // `SDImageCodersManager` walks coders **last-added-first** when
        // resolving a decoder — so the libwebp path wins over the
        // built-in ImageIO coder for `.webp` data without needing
        // explicit positioning. This is the registration form the
        // SDWebImage docs recommend.
        // 시그포스트 래퍼를 등록 — 디코드 로직은 super 그대로, 앞뒤로 mxSignpost
        // 만 끼워 WebP 디코드 CPU 를 이름으로 측정한다(SignpostWebPCoder 참조).
        // `SDImageCache.ioQueue` 를 **동시 큐**로. 기본은 직렬이라
        // (`SDImageCacheConfig.m:40-42`) 캐시 조회가 한 줄로 서는데, 그 큐 안에서
        // **디코드까지** 한다(`SDImageCache.m:524-528` diskImageForKey →
        // SDImageCacheDecodeImageData, 호출은 692-694). 즉 디스크에서 나오는 이미지는
        // 하나씩 순차 디코드된다 — 웜 캐시(네트워크 0건) 세션에서 본문 show p90 이
        // 1,672ms 였고 49장 디코드 합계가 3,888ms 였던 실측이 이 그림이다. 다운로드
        // 슬롯을 넓혀도 효과가 없던 것도 여기서 다시 만나기 때문이다.
        //
        // 라이브러리가 공식 지원하는 설정이다(`SDImageCacheConfig.h:130-137`).
        // 필수 조건인 `diskCacheWritingOptions == NSDataWritingAtomic` 은 기본값이고
        // (`SDImageCacheConfig.m:34`) 우리는 그 값을 건드리지 않는다 — `SDDiskCache` 에
        // 락이 하나도 없어서 안전성이 전적으로 이 원자적 쓰기에서 나온다.
        //
        // **순서가 중요하다**: 이 속성은 캐시가 만들어질 때 한 번 읽히고, 그 뒤 바꾸면
        // 조용히 무효다(같은 헤더의 "does not support dynamic changes"). 그래서
        // `SDImageCache.shared` 를 처음 건드리기 전에 세우고, 아래에서 실제로 먹었는지
        // 확인한다 — 조용한 무효화가 이 변경의 유일한 실패 모드다.
        SDImageCacheConfig.default.ioQueueAttributes = concurrentQueueAttribute()

        // 등록 순서가 곧 우선순위다 — `SDImageCodersManager` 는 나중에 등록된 코더를
        // 먼저 본다. ImageIO 코더를 **먼저**, libwebp 코더를 **나중에** 등록해야
        // WebP 가 libwebp 로 간다(iOS 14+ ImageIO 도 WebP 를 읽을 수 있어서, 순서가
        // 뒤집히면 libwebp 경로가 조용히 가로채인다).
        let coderManager = SDImageCodersManager.shared
        coderManager.coders = (coderManager.coders ?? []).filter {
            !($0 is SignpostWebPCoder) && !($0 is SignpostIOCoder)
        }
        coderManager.addCoder(SignpostIOCoder())
        coderManager.addCoder(SignpostWebPCoder())

        // Redirect http→https on the URLSession redirect callback. ATS
        // blocks `https → 302 → http` chains and Korean board image
        // CDNs hit that constantly (fmkorea getfile proxy → ext.fmkorea
        // → plaync.co.kr 처럼) — without this, those images silently
        // 404 to the retry placeholder.
        SDWebImageDownloader.shared.config.operationClass = HTTPSRedirectingDownloaderOperation.self

        let cache = SDImageCache.shared
        #if DEBUG
        // 위 순서가 깨지면(누가 먼저 `SDImageCache.shared` 를 건드리면) 설정이 조용히
        // 무시된다. 조용히 넘어가면 "켰는데 효과 없네" 로 오판하므로 여기서 깨뜨린다.
        assert(cache.config.ioQueueAttributes === concurrentQueueAttribute(),
               "ioQueueAttributes 가 안 먹었다 — SDImageCache.shared 가 configure() 보다 먼저 만들어졌다")
        #endif
        // 400MB. 종전 200MB 는 "이전 `ImageCache` 예산에 맞춘" 값이었고 근거가
        // 측정이 아니었다(이 주석의 원문도 "측정하면 튜닝하겠다" 였다). 기기
        // 계측으로 부족이 확인돼 올린다.
        //
        // 실측(2026-08-15, 앱 재시작 직후 · 백그라운드 왕복 없음): 이슈모음에서
        // 글 14개를 1분 남짓에 훑어 본문 이미지 누적 245MB. 그 뒤 **맨 처음 글**
        // (12MB, 4장)을 다시 열자 4장 전부 디스크 재디코드였다 —
        //   17:04:25  imgcache:f=m0/d4/n0,MB=12,id=…1648140
        //   17:05:34  imgcache:f=m0/d4/n0,MB=12          ← 재방문, 메모리 0
        // 즉 캡을 넘긴 누적이 초기 엔트리를 밀어냈다. 캡을 압박하는 건 "긴 글"
        // 이 아니다 — 같은 세션 단일 글 최대가 40MB 였고, 짧은 글을 빠르게
        // 넘겨보는 평범한 사용이 누적으로 넘긴다.
        //
        // 400MB 는 그 세션 전체(245MB)를 담고도 60% 여유. 이때 footprint 는
        // peak 252MB / avail 3.1GB 였으므로, 캐시가 400MB 까지 차도 한도(≈3.35GB)
        // 대비 여유가 크다. NSCache 소유라 압박이 오면 시스템이 걷어간다.
        //
        // 정정(2026-08-19) — 이 자리에 "백그라운드 왕복이 어차피 비우므로(실측)"
        // 라고 적혀 있었으나 **틀렸다**. 서버 footprint 562쌍
        // (background→active) 을 다시 보면 92.9% 가 live 힙 ±5MB 로 그대로고,
        // 6시간 이상 나가 있어도 평균 −2MB 다. 캐시는 백그라운드에서 안 비워진다.
        // 원 관찰은 8/15 15:40 백그라운드(live 330MB) → 16:32 `launch`(live 1MB)
        // 였는데, 그건 캐시가 비워진 게 아니라 **백그라운드에서 죽고 재실행된
        // 것**이다. 콜드 프로세스를 캐시 축출로 오독한 자리.
        //
        // 그래도 캡은 400MB 로 둔다. 상주가 실제로 해를 끼친다는 증거가 없다:
        // live 는 세션 ~19시간이면 240MB 안팎에서 포화해 그 뒤 40시간·글 1400개
        // 를 더 봐도 평평하고(래칫 아님), 포그라운드 OOM 0 · 크래시 0 이며,
        // 백그라운드 압박 종료(35일간 14회)는 우리 suspended memory 와 상관이
        // 없다(0회인 날 평균 183MB · 1회 209MB · 2회 116MB). 캡을 다시 만질
        // 거라면 "백그라운드가 비워 준다"가 아니라 이 숫자들 위에서 판단할 것.
        cache.config.maxMemoryCost = 400 * 1024 * 1024
        // 500MB disk cap with a 7-day expiry. Cold-start to a recently-read
        // post should serve images from disk (the gap the old pipeline had —
        // URLCache evicts aggressively for image-sized payloads). 7 days is
        // a compromise between "user re-reads the same hot post" and
        // unbounded disk growth on heavy users.
        cache.config.maxDiskSize = 500 * 1024 * 1024
        cache.config.maxDiskAge = 7 * 24 * 60 * 60

        let downloader = SDWebImageDownloader.shared
        // 4 슬롯 — **두 번 재봤고 폭은 병목이 아니다.**
        //
        // 이 값은 다운로드가 아니라 다운로드+디코드 동안 잡혀 있다(디코드가 오퍼레이션
        // 안 `coderQueue` 에서 돌고 `done` 은 그 뒤 barrier — 
        // `SDWebImageDownloaderOperation.m:363-425`). 그래서 폭을 넓히면 대기가 줄 거라
        // 봤는데, 같은 글·같은 콜드 조건에서 잰 결과가 그걸 부정한다(2026-08-21):
        //
        //            슬롯 4          슬롯 8
        //   대기 p90  4,590ms        4,356ms     ← 2배로 늘려도 그대로(노이즈 범위)
        //   1s초과    24/60(40%)     17/36(47%)
        //   본문 show p50 1,618ms    2,318ms     ← 오히려 나빠짐
        //   다운로드 p90 176ms       1,379ms     ← 동시 요청이 늘어 각자 느려짐
        //
        // 1차 실험은 가벼운 워크로드에서 비교해 판정이 무효였고(대기 p90 325ms),
        // 이번엔 캐시를 비우고 같은 글(webp 17장급 인벤 2건)로 양쪽 다 대기 4초대를
        // 재현한 상태에서 비교했다. 병목은 이 아래 직렬 지점(`SDImageCache.ioQueue`)이다.
        downloader.config.maxConcurrentDownloads = 4
        // 8s timeout per attempt to fast-fail stale keep-alive
        // connections (the iOS pool's -1005 / -1001 case after
        // backgrounding). SDWebImage's internal retry re-issues with
        // the same `downloadTimeout`, so worst-case end-to-end is
        // ~16s (8s timeout × 2 attempts) before a failure surfaces —
        // still inside the placeholder-fatigue threshold and an order
        // of magnitude better than the URLSession 60s default that
        // would freeze the slot for a full minute on a single bad
        // pool entry.
        downloader.config.downloadTimeout = 8

        // Match the mobile Safari UA the rest of the app uses. Several
        // Korean board image CDNs (the ones embedded in ppomppu /
        // humor / aagag bodies) reject the default `SDWebImage/x.y.z`
        // UA with 403 — observed regression after the migration:
        // body images flipping to the "다시 시도" retry placeholder en
        // masse on first load. `Networking.userAgent` is the same
        // string `URLSession` uses for HTML fetches, so the image and
        // HTML legs of a single post visit identify identically and
        // CDNs treat the second leg as a continuation of the first.
        downloader.setValue(Networking.userAgent, forHTTPHeaderField: "User-Agent")
    }

    /// `DISPATCH_QUEUE_CONCURRENT` 의 Swift 대체.
    ///
    /// Swift 에는 이 매크로가 안 열려 있다 — 매크로는 `(dispatch_queue_attr_t)&_dispatch_queue_attr_concurrent`
    /// 인데 그 심볼이 불완전 타입이라 Swift 가 "cannot reference invalid declaration" 로
    /// 막는다. 그래서 심볼 **주소**를 직접 얻는다. C 에서 매크로 값과 `dlsym` 결과가
    /// 같은 주소임을 확인했다(둘 다 `0x1fb0e0f80`).
    ///
    /// 대안은 브리징 헤더를 추가하는 것인데, 상수 하나 때문에 빌드 설정을 바꾸는 것보다
    /// 이쪽이 국소적이다. 엉뚱한 값을 잡으면 캐시가 조용히 직렬로 돌아가므로,
    /// `SDWebImageSetupTests` 가 "이 attr 로 만든 큐가 실제로 동시 실행되는지" 를 잰다.
    static func concurrentQueueAttribute() -> dispatch_queue_attr_t? {
        // RTLD_DEFAULT — libdispatch 는 이미 프로세스에 올라와 있다.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "_dispatch_queue_attr_concurrent") else { return nil }
        return unsafeBitCast(symbol, to: dispatch_queue_attr_t.self)
    }

    /// 테스트가 위 attr 의 실제 동시성을 확인할 수 있게 열어둔 생성 통로.
    /// (프로덕션 경로는 SDWebImage 가 같은 attr 로 자기 큐를 만든다.)
    static func makeQueue(label: String, attr: dispatch_queue_attr_t?) -> DispatchQueue {
        DispatchQueue(__label: label, attr: attr)
    }
}
