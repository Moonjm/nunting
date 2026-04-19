import SwiftUI

struct BoardFilterBar: View {
    let board: Board
    @Binding var selection: BoardFilter?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabItems) { item in
                    tab(label: item.label, isSelected: item.isSelected(selection: selection)) {
                        withAnimation(.easeInOut(duration: 0.15)) { selection = item.filter }
                    }
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
