import SwiftUI

struct MainBottomBar: View {
    let board: Board
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
            // drawer is now reachable only via a left-edge rightward
            // swipe handled by ContentView's panGesture; the bottom
            // bar's board name no longer surfaces it on tap.)
            //
            // The empty single-tap recognizer is intentionally kept:
            // when only `.onTapGesture(count: 2)` is attached alongside
            // the drag, SwiftUI holds the first touch waiting for a
            // potential second tap and the drag recognizer is starved
            // of `.onChanged` / `.onEnded` events — left-right swipe
            // for board step silently stops working. Pairing it with
            // a no-op single-tap restores the gesture mediation we had
            // before the drawer-on-tap removal, so the swipe arrives
            // at the drag handler again.
            //
            // Favorite-toggle (별 버튼) was removed from this bar by
            // user request — accidental taps during normal interaction
            // were silently un-favoriting boards. Add/remove favorites
            // is still available in the side drawer (사이트 카탈로그
            // 섹션의 별 아이콘).
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
            .onTapGesture {
                // Intentional no-op — see comment above.
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

            // Invisible right slot — matches the search button's flex
            // claim so removing the favorite-toggle doesn't recenter
            // search-icon + board-name. Keeping the bar's spatial
            // partition intact means muscle memory for swipe-step /
            // double-tap on the board name still hits the same area
            // it did before.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
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
