import Foundation

/// 마지막 성공 목록 1건의 디스크 스냅샷 — 콜드 스타트에서 즉시 렌더 +
/// 백그라운드 재검증(SWR)의 재료. `BoardListLoader` 가 첫 페이지 성공마다
/// 덮어쓰고, 세션 첫 refresh(인메모리 캐시가 비어 있을 때)에서 key 가
/// 일치하면 복원한다.
///
/// actor 라 파일 IO 가 main actor 밖에서 직렬화된다. 손상/부재 파일은
/// nil 로 조용히 폴백 — 스냅샷은 순수 최적화 계층이라 실패가 기능을
/// 막으면 안 된다.
actor BoardListSnapshotStore {
    struct Snapshot: Codable {
        let key: String
        let posts: [Post]
    }

    private let fileURL: URL

    /// 기본 위치: Application Support/list-snapshot.json. 캐시성 데이터지만
    /// Caches 디렉토리는 OS 가 임의 시점에 비울 수 있어 "기동 직후 즉시
    /// 렌더"라는 목적에 안 맞는다 — 수십 KB 라 AS 에 둬도 부담 없음.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            // Application Support 는 표준 디렉토리라 사실상 항상 존재하지만,
            // 스냅샷은 순수 최적화 계층이라 디렉토리 조회 실패로 앱이 죽으면
            // 안 된다 — 빈 결과면 temp 로 폴백(다음 기동에 다시 시도).
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("list-snapshot.json")
        }
    }

    func save(key: String, posts: [Post]) {
        let snapshot = Snapshot(key: key, posts: posts)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
