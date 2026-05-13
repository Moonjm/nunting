import Hummingbird
import Foundation

let dbPath = ProcessInfo.processInfo.environment["NUNTING_DB_PATH"]
    ?? "/var/lib/nunting/state.db"
let store = try Store(path: dbPath)
let app = buildApp(store: store)
// Hummingbird ServiceGroup이 SIGTERM/SIGINT을 잡아 graceful shutdown 후 정상
// return하므로, 여기서 Store.close()를 호출해 WAL flush + sqlite handle 정리.
// throw 경로(예: 런타임 실패)에서도 같이 닫히도록 do/catch.
do {
    try await app.runService()
    await store.close()
} catch {
    await store.close()
    throw error
}
