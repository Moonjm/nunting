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

            // Phantom right slot. The favorite-toggle (별 버튼) used
            // to live here but was removed by user request —
            // accidental taps during normal swipe-step / double-tap
            // interaction on the board name were silently un-
            // favoriting boards. Add/remove favorites is still
            // available in the side drawer (사이트 카탈로그 섹션의
            // 별 아이콘).
            //
            // The slot itself stays as an invisible flex spacer
            // matching the search button's `.frame(maxWidth: .infinity)`
            // claim — without it the HStack collapses to a 50/50 split
            // and search-icon + board-name shift left, breaking muscle
            // memory for swipe-step and double-tap-reload areas.
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
