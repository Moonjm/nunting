import Foundation
import Observation

/// Holds the user's currently-selected board / filter / search query
/// plus the navigation scope (which list the bottom-bar swipe-step
/// cycles through). Pulled out of `ContentView` so:
///
///  - Board switches are atomic at the *type* level — `select(_:navScope:)`
///    sets board + filter + search in a single transaction the way the
///    drawer's `onSelectBoard` and the swipe-step both want, and the
///    earlier `.onChange(of: selectedBoard)` reset hook isn't possible
///    to forget.
///  - Tests can drive selection state directly.
///  - `BoardListView`'s `taskKey` reads through one observed object
///    rather than three independent `@State` properties.
///
/// Filter changes from the `BoardFilterBar` (via `$selection.filter`
/// two-way binding) intentionally still flow through the property
/// directly; `ContentView` keeps the
/// `.onChange(of: selection.filter)` hook to clear `searchQuery`
/// because a filter swap can change the underlying path entirely
/// (`BoardFilter.replacementPath`).
@Observable
@MainActor
final class BoardSelection {
    var board: Board
    var filter: BoardFilter?
    var searchQuery: String?
    var navScope: DrawerSection
    /// Bumped by `requestReload()`. Attached to `mainScreen` via `.id()`
    /// so the entire list + filter bar + bottom bar subtree rebuilds and
    /// the underlying `BoardListView.task(id: taskKey)` re-fires
    /// regardless of the current search/filter state.
    private(set) var reloadToken: Int = 0

    init(initialBoard: Board, initialNavScope: DrawerSection) {
        self.board = initialBoard
        self.filter = initialBoard.defaultListFilter
        self.searchQuery = nil
        self.navScope = initialNavScope
    }

    /// Atomic transition to a new board: sets board + default filter +
    /// clears search in a single state-mutation batch. Drawer-driven
    /// selection and bottom-bar swipe-step both flow through this so
    /// `BoardListView.taskKey` changes exactly once per user action.
    /// The previous pattern (set board, let `.onChange(of: board)`
    /// reset filter on the next render) gave default-filter boards a
    /// guaranteed double-fire on entry — first task fetched with the
    /// previous board's filter, was cancelled, then the real fetch
    /// started.
    func select(_ board: Board, navScope: DrawerSection) {
        self.board = board
        self.filter = board.defaultListFilter
        self.searchQuery = nil
        self.navScope = navScope
    }

    /// Cycle through `pool` (favorites or a site's catalog), wrapping
    /// at the ends. No-ops on single-element pools — preserves the
    /// "swipe doesn't budge" UX for users with one favorite. Caller
    /// computes the pool from `FavoritesStore` / `BoardCatalogStore`
    /// because `BoardSelection` doesn't depend on either.
    func step(by delta: Int, within pool: [Board]) {
        guard pool.count > 1,
              let idx = pool.firstIndex(where: { $0.id == board.id })
        else { return }
        let next = ((idx + delta) % pool.count + pool.count) % pool.count
        let nextBoard = pool[next]
        // Same atomic batch as `select(_:navScope:)` — see that
        // doccomment for why a single mutation matters.
        self.board = nextBoard
        self.filter = nextBoard.defaultListFilter
        self.searchQuery = nil
    }

    /// Triggered by the bottom-bar's board-name double-tap. Clears
    /// search and bumps `reloadToken` so the mainScreen `.id()` rebuild
    /// forces a fresh list load even if the user is currently viewing
    /// the same board with the same filter.
    func requestReload() {
        searchQuery = nil
        reloadToken &+= 1
    }
}
