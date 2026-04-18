import SwiftUI

struct MainBottomBar: View {
    let board: Board
    let favorites: FavoritesStore
    let onSiteTap: () -> Void
    let onSearch: () -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            barButton {
                VStack(spacing: 2) {
                    Circle()
                        .fill(board.site.accentColor)
                        .frame(width: 6, height: 6)
                    Text(board.site.displayName)
                        .font(.caption2.weight(.medium))
                }
            } action: {
                onSiteTap()
            }

            barButton {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
            } action: {
                onSearch()
            }

            barButton {
                Text(board.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } action: {
                onSiteTap()
            }

            barButton {
                Image(systemName: favorites.isFavorite(board) ? "star.fill" : "star")
                    .font(.callout)
                    .foregroundStyle(favorites.isFavorite(board) ? Color.yellow : Color.primary)
            } action: {
                favorites.toggle(board)
            }

            barButton {
                Image(systemName: "ellipsis")
                    .font(.callout)
            } action: {
                onMore()
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
