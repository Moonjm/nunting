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
        // 4 슬롯. 이 값은 다운로드가 아니라 **다운로드+디코드** 동안 잡혀 있다 —
        // SDWebImage 는 디코드를 오퍼레이션 안(`coderQueue`)에서 돌리고 오퍼레이션을
        // 끝내는 `done` 은 그 뒤 barrier 로 부른다(`SDWebImageDownloaderOperation.m:363-425`).
        //
        // **8 로 넓혀 봤고, 안 됐다**(2026-08-21 기기 계측, 사전에 정한 기준으로 판정):
        //   슬롯 4: 대기 0ms 64% · >100ms 14% · >500ms 8% · 평균 136ms · peak 433MB
        //   슬롯 8: 대기 0ms 58% · >100ms 14% · >500ms 8% · 평균 209ms · peak 577MB
        // 대기 분포가 그대로고 메모리 피크만 +144MB 올랐다. 폭이 병목이었다면 2배로
        // 늘렸을 때 대기 비율이 내려갔어야 한다 — 안 내려갔으므로 병목은 슬롯 수가
        // 아니다(파이프라인이 그 아래 어딘가에서 이미 포화). 다시 넓히려는 사람은
        // 이 숫자부터 반박할 것.
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
}
