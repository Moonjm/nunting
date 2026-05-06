import SwiftUI

struct BoardFilterBar: View, Equatable {
    let board: Board
    /// The selection binding is passed through to each `Chip` rather than
    /// read here in the bar's body. That keeps SwiftUI's dependency
    /// tracking scoped per-chip — the bar's `ScrollView` body never
    /// recomputes on chip taps, so the underlying UIScrollView's offset
    /// (and any in-flight scroll gesture state) is preserved by default.
    /// Reading `selection.wrappedValue` directly inside `body` would make
    /// the entire bar a dependency of every selection write, which is
    /// what was triggering the snap-to-leading symptom.
    @Binding var selection: BoardFilter?

    /// Conform to `Equatable` (paired with `.equatable()` at the call
    /// site) so SwiftUI's view-update path skips body recomputation
    /// entirely when only `selection` changes — `==` ignores it on
    /// purpose. Tap events still flow through `$selection` into the
    /// per-chip subviews, which observe the binding individually and
    /// re-render their capsule color without dragging the surrounding
    /// `ScrollView` along.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.board.id == rhs.board.id
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabItems) { item in
                    Chip(item: item, selection: $selection)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color("AppSurface2"))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var tabItems: [FilterTabItem] {
        if board.id == Board.invenMaple.id {
            let byID = Dictionary(uniqueKeysWithValues: board.filters.map { ($0.id, $0) })
            return [
                byID["chu"].map(FilterTabItem.filter),
                byID["inbang"].map(FilterTabItem.filter),
                .all,
                byID["chuchu"].map(FilterTabItem.filter),
            ].compactMap(\.self)
        }
        return [.all] + board.filters.map(FilterTabItem.filter)
    }
}

/// Per-chip view: reads `selection` so its color can react to taps, but
/// the parent `BoardFilterBar` doesn't — meaning the bar's body (and
/// `ScrollView` identity / offset) never invalidates on chip presses.
private struct Chip: View {
    let item: FilterTabItem
    @Binding var selection: BoardFilter?

    var body: some View {
        let isSelected = item.isSelected(selection: selection)
        Button {
            selection = item.filter
        } label: {
            Text(item.label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    isSelected ? Color.accentColor : Color("AppSurface"),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct FilterTabItem: Identifiable {
    let id: String
    let label: String
    let filter: BoardFilter?

    static let all = FilterTabItem(id: "_all", label: "전체", filter: nil)

    nonisolated static func filter(_ filter: BoardFilter) -> FilterTabItem {
        FilterTabItem(id: filter.id, label: filter.name, filter: filter)
    }

    nonisolated func isSelected(selection: BoardFilter?) -> Bool {
        switch (filter, selection) {
        case (nil, nil):
            true
        case let (.some(filter), .some(selection)):
            filter.id == selection.id
        default:
            false
        }
    }
}
