import SwiftUI

struct BoardFilterBar: View {
    let board: Board
    @Binding var selection: BoardFilter?
    /// Horizontal scroll offset, lifted into the parent so the position
    /// survives the `safeAreaInset` content rebuild that fires on every
    /// `selection` change. Holding this as `@State` inside `BoardFilterBar`
    /// itself isn't enough — the inset's content closure re-evaluates,
    /// SwiftUI tears the chip-bar subtree down, and the in-bar `@State`
    /// resets to nil before the next `.scrollPosition` apply runs. Owning
    /// the binding outside the bar keeps the leading-anchor stable across
    /// rebuilds.
    @Binding var scrolledID: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(tabItems) { item in
                    tab(label: item.label, isSelected: item.isSelected(selection: selection)) {
                        // No `withAnimation` here: animating a binding write
                        // that ripples up through `safeAreaInset` triggers an
                        // implicit transition on the entire chip bar, which
                        // (combined with the parent rebuild) causes the
                        // underlying UIScrollView to snap back to the leading
                        // edge. The capsule color change still feels instant.
                        selection = item.filter
                    }
                    .id(item.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollPosition(id: $scrolledID, anchor: .leading)
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

    private func tab(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
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
