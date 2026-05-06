import SwiftUI
import UIKit

/// Horizontal filter chip bar for the active board. Wraps a real
/// `UIScrollView` via `UIViewRepresentable` because SwiftUI's
/// `ScrollView` snapped back to offset 0 on every chip tap inside
/// `safeAreaInset` on iOS 26 — every pure-SwiftUI workaround
/// (`.scrollPosition(id:)`, per-chip dependency scoping,
/// `.equatable()`, GeometryReader+ScrollViewReader) was either
/// no-op or papered over it. UIKit's `UIScrollView` keeps its
/// `contentOffset` across `updateUIView` calls by default, so the
/// bar literally cannot move once the user has scrolled it.
struct BoardFilterBar: View {
    let board: Board
    @Binding var selection: BoardFilter?

    var body: some View {
        ChipScrollViewRepresentable(
            board: board,
            chips: tabItems,
            selectedID: tabItems.first(where: { $0.isSelected(selection: selection) })?.id ?? FilterTabItem.all.id,
            onTap: { item in selection = item.filter }
        )
        .frame(height: 38)
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

private struct FilterTabItem: Identifiable, Equatable {
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

    static func == (lhs: FilterTabItem, rhs: FilterTabItem) -> Bool {
        lhs.id == rhs.id && lhs.label == rhs.label
    }
}

/// UIKit-backed chip scroller. Build the button row once when the host
/// board changes; otherwise just refresh capsule colors against
/// `selectedID` without touching `contentOffset`.
private struct ChipScrollViewRepresentable: UIViewRepresentable {
    let board: Board
    let chips: [FilterTabItem]
    let selectedID: String
    let onTap: (FilterTabItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.contentInset = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        scroll.backgroundColor = .clear

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])

        context.coordinator.stack = stack
        context.coordinator.boardID = board.id
        context.coordinator.rebuild(chips: chips, selectedID: selectedID)

        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.onTap = onTap
        // Rebuild the chip row only when the board (= chip set) actually
        // changes. Tap-driven `selectedID` updates run a cheap repaint
        // pass that doesn't touch `arrangedSubviews` — `contentOffset`
        // sticks because UIKit doesn't reset it.
        if context.coordinator.boardID != board.id {
            context.coordinator.boardID = board.id
            context.coordinator.rebuild(chips: chips, selectedID: selectedID)
            uiView.contentOffset = .zero
        } else {
            context.coordinator.refreshSelection(selectedID: selectedID)
        }
    }

    final class Coordinator {
        var stack: UIStackView?
        var boardID: String = ""
        var chipIDs: [String] = []
        var onTap: (FilterTabItem) -> Void
        private var pendingChips: [FilterTabItem] = []

        init(onTap: @escaping (FilterTabItem) -> Void) {
            self.onTap = onTap
        }

        func rebuild(chips: [FilterTabItem], selectedID: String) {
            guard let stack else { return }
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            chipIDs = chips.map(\.id)
            pendingChips = chips
            for (idx, chip) in chips.enumerated() {
                let button = makeButton(for: chip, idx: idx)
                applyStyle(button, isSelected: chip.id == selectedID)
                stack.addArrangedSubview(button)
            }
        }

        func refreshSelection(selectedID: String) {
            guard let stack else { return }
            for (idx, view) in stack.arrangedSubviews.enumerated() {
                guard idx < chipIDs.count, let button = view as? UIButton else { continue }
                applyStyle(button, isSelected: chipIDs[idx] == selectedID)
            }
        }

        private func makeButton(for chip: FilterTabItem, idx: Int) -> UIButton {
            let button = UIButton(type: .system)
            button.tag = idx
            button.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
            button.contentEdgeInsets = UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
            button.setTitle(chip.label, for: .normal)
            button.layer.masksToBounds = true
            button.addAction(
                UIAction { [weak self] _ in
                    guard let self,
                          self.pendingChips.indices.contains(idx)
                    else { return }
                    self.onTap(self.pendingChips[idx])
                },
                for: .touchUpInside
            )
            // Capsule corner radius is set after layout so the button has
            // a real height to halve.
            DispatchQueue.main.async { [weak button] in
                guard let button else { return }
                button.layer.cornerRadius = button.bounds.height / 2
            }
            return button
        }

        private func applyStyle(_ button: UIButton, isSelected: Bool) {
            if isSelected {
                button.backgroundColor = UIColor(named: "AccentColor") ?? .systemBlue
                button.setTitleColor(.white, for: .normal)
            } else {
                button.backgroundColor = UIColor(named: "AppSurface") ?? .secondarySystemBackground
                button.setTitleColor(.label, for: .normal)
            }
        }
    }
}
