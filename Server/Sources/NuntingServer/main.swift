import Hummingbird
import Foundation

let dbPath = ProcessInfo.processInfo.environment["NUNTING_DB_PATH"]
    ?? "/var/lib/nunting/state.db"
let store = try Store(path: dbPath)
let app = buildApp(store: store)
try await app.runService()
