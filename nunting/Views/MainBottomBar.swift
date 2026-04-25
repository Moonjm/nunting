import SwiftUI

struct MainBottomBar: View {
    let board: Board
    let favorites: FavoritesStore
    let onBoardDoubleTap: () -> Void
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

            // Board name area: double tap clears the active search,
            // horizontal swipe steps through the current scope's boards.
            // (Single-tap → side drawer was removed by request — the
            // drawer is reachable via the right-edge swipe and the
            // bottom-bar-name no longer surfaces it on tap.)
            Group {
                Text(board.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onBoardDoubleTap()
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
