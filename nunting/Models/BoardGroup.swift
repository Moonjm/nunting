import Foundation

/// Categorical bucket of boards inside a single site (e.g. ppomppu's
/// "뽐뿌 / 커뮤니티 / 포럼"). When `name` is nil the boards are flat — the
/// drawer renders them without a section header.
struct BoardGroup: Identifiable, Hashable {
    let id: String
    let name: String?
    let boards: [Board]
}
