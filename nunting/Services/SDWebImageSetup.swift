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
        let coderManager = SDImageCodersManager.shared
        coderManager.coders = (coderManager.coders ?? []).filter { !($0 is SignpostWebPCoder) }
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
        // 대비 여유가 크다. NSCache 소유라 압박 시 시스템이 걷어가고 백그라운드
        // 왕복이 어차피 비우므로(실측), 상한을 키워도 상주 위험은 선형이 아니다.
        cache.config.maxMemoryCost = 400 * 1024 * 1024
        // 500MB disk cap with a 7-day expiry. Cold-start to a recently-read
        // post should serve images from disk (the gap the old pipeline had —
        // URLCache evicts aggressively for image-sized payloads). 7 days is
        // a compromise between "user re-reads the same hot post" and
        // unbounded disk growth on heavy users.
        cache.config.maxDiskSize = 500 * 1024 * 1024
        cache.config.maxDiskAge = 7 * 24 * 60 * 60

        let downloader = SDWebImageDownloader.shared
        // 4 concurrent fetches. Higher values let more images race
        // for handshakes after scene-phase resume but spike the
        // gestures-unresponsive window; lower starves the queue on
        // long detail pages.
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
