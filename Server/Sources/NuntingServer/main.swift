import Hummingbird
import Foundation
import NuntingCore

let env = ProcessInfo.processInfo.environment

// 1) DB
let dbPath = env["NUNTING_DB_PATH"] ?? "/var/lib/nunting/state.db"
let store = try Store(path: dbPath)

// 2) APNs (선택). dev에선 env 없으면 stub-print 모드로 폴백 — 폴러는 그래도 돈다.
let apns: any APNsSender = try makeAPNsSender(env: env)

// 3) Poller — 뽐뿌 모바일 리스트(`m.ppomppu.co.kr/new/bbs_list.php?id=ppomppu`).
//   `Board.ppomppuMain` 카논 path를 그대로 쓴다(iOS 앱과 동일 경로) — 데스크탑
//   `/zboard/zboard.php`는 다른 DOM이라 `PpomppuParser`가 0건 반환하고
//   sentinel/매칭이 영영 안 잡힌다(Task 8 스모크에서 발견).
let board = Board.ppomppuMain
let poller = PpomppuPoller(
    board: board,
    store: store,
    apns: apns,
    fetcher: { url, encoding in
        try await ServerNetworking.fetchHTML(url: url, encoding: encoding)
    }
)

let interval: Duration
if let raw = env["NUNTING_POLL_INTERVAL_SECONDS"], let s = Int(raw) {
    interval = .seconds(s)
} else {
    interval = .seconds(180)
}
let pollerService = PollerService(poller: poller, interval: interval)

// 4) Application
let app = buildApp(store: store, additionalServices: [pollerService])

do {
    try await app.runService()
    await store.close()
} catch {
    await store.close()
    throw error
}

// MARK: - APNs sender 구성

/// 4개 env(`APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`) 모두
/// 있으면 실 APNsClient. 하나라도 누락이면 stub-print 모드(stderr 로그).
/// 1인 도구 + 비공개 배포라 sample creds 박지 않고 graceful degrade.
func makeAPNsSender(env: [String: String]) throws -> any APNsSender {
    guard
        let keyPath = env["APNS_KEY_PATH"],
        let keyId = env["APNS_KEY_ID"],
        let teamId = env["APNS_TEAM_ID"],
        let topic = env["APNS_TOPIC"]
    else {
        FileHandle.standardError.write(Data(
            "[main] APNS_* env 누락 — stub-print 모드로 폴러 진행\n".utf8
        ))
        return StubPrintAPNs()
    }
    let host = env["APNS_HOST"] ?? "api.sandbox.push.apple.com"
    let keyPEM = try String(contentsOfFile: keyPath, encoding: .utf8)
    let config = APNsConfig(
        keyPath: keyPath, keyId: keyId, teamId: teamId, topic: topic, host: host
    )
    return APNsClient(config: config, keyPEM: keyPEM) { url, headers, body in
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (respBody, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (status, respBody)
    }
}

/// 개발 환경용. 실제 APNs creds 없이도 매칭 흐름을 stderr로 관찰할 수 있다.
struct StubPrintAPNs: APNsSender {
    func send(deviceToken: String, payload: APNsPayload) async throws -> APNsResult {
        let log = "[APNs stub] token=\(deviceToken) title=\(payload.aps.alert.title) body=\(payload.aps.alert.body)"
        FileHandle.standardError.write(Data("\(log)\n".utf8))
        return .ok
    }
}
