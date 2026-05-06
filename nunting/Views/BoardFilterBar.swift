import SwiftUI

struct BoardFilterBar: View {
    let board: Board
    @Binding var selection: BoardFilter?
    /// Leading-most visible chip id, lifted into the parent's `@State` so the
    /// horizontal scroll offset survives the `safeAreaInset` content rebuild
    /// that fires on every `selection` change. Pure SwiftUI alternatives
    /// (`.scrollPosition(id:)`, plain `@State` inside the bar) intermittently
    /// snap the underlying UIScrollView back to the leading edge on rebuild
    /// in iOS 26 — visible as the bar flicking to "전체" every chip tap.
    /// Tracking the anchor explicitly via `GeometryReader` + restoring it
    /// via `ScrollViewReader.scrollTo` after the rebuild is a workaround
    /// that doesn't depend on private SwiftUI scroll-restoration heuristics.
    @Binding var scrolledID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabItems) { item in
                        tab(label: item.label, isSelected: item.isSelected(selection: selection)) {
                            // No `withAnimation`: an animated binding write
                            // ripples through `safeAreaInset` and triggers
                            // an implicit transition that interferes with
                            // the post-rebuild scroll restore below.
                            selection = item.filter
                        }
                        .id(item.id)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ChipFramesKey.self,
                                    value: [ChipFrame(id: item.id, minX: geo.frame(in: .named(Self.coordSpace)).minX)]
                                )
                            }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .coordinateSpace(name: Self.coordSpace)
            .onPreferenceChange(ChipFramesKey.self) { frames in
                // Leading-most chip whose minX is at-or-past the scroll
                // view's leading edge (frames with minX < 0 are scrolled
                // out of view to the left; pick the smallest non-negative).
                let visible = frames
                    .filter { $0.minX >= -0.5 }
                    .min(by: { $0.minX < $1.minX })
                if let id = visible?.id, id != scrolledID {
                    scrolledID = id
                }
            }
            .onChange(of: selection?.id) { _, _ in
                // The selection write rebuilt the bar; SwiftUI's default
                // is to leave the underlying UIScrollView at offset 0.
                // Re-anchor to the chip the user was looking at before
                // they tapped so the bar stays put. No animation —
                // animating the restore would itself look like a snap.
                if let id = scrolledID {
                    proxy.scrollTo(id, anchor: .leading)
                }
            }
        }
        .background(Color("AppSurface2"))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private static let coordSpace = "BoardFilterBar.scroll"

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

private struct ChipFrame: Equatable {
    let id: String
    let minX: CGFloat
}

private struct ChipFramesKey: PreferenceKey {
    static let defaultValue: [ChipFrame] = []
    static func reduce(value: inout [ChipFrame], nextValue: () -> [ChipFrame]) {
        value.append(contentsOf: nextValue())
    }
}
