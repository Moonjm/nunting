import SwiftUI

struct MainBottomBar: View {
    let board: Board
    let favorites: FavoritesStore
    let onBoardTap: () -> Void
    let onSearch: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            barButton {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
            } action: {
                onSearch()
            }

            // Board name area: tap to open drawer, horizontal swipe to step
            // through the current site's boards.
            barButton {
                Text(board.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } action: {
                onBoardTap()
            }
            // High priority so the parent drawer-pan gesture in ContentView
                // doesn't swallow the swipe before it can reach the bar.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            let dx = value.translation.width
                            if dx < -40 { onNext() }
                            else if dx > 40 { onPrev() }
                        }
                )

            barButton {
                Image(systemName: favorites.isFavorite(board) ? "star.fill" : "star")
                    .font(.callout)
                    .foregroundStyle(favorites.isFavorite(board) ? Color.yellow : Color.primary)
            } action: {
                favorites.toggle(board)
            }
        }
        .frame(height: 50)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    @ViewBuilder
    private func barButton<Content: View>(
        @ViewBuilder content: () -> Content,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
