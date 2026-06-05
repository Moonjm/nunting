import SwiftUI
struct MainBottomBar: View {
    let board: Board
    let onBoardDoubleTap: () -> Void
    let onSearch: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void
    /// 안 읽은 알림 수 — 종 아이콘 위 빨강 뱃지. 0 이면 뱃지 숨김.
    let unreadCount: Int
    /// 종 탭 → 키워드 알림 화면(KeywordListView) 진입.
    let onAlerts: () -> Void

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

            // Right slot: 키워드 알림(종) 버튼. 좌측 검색 버튼과 동일한
            // `barButton`(maxWidth:.infinity) 라 [검색]·보드명·[종] 으로
            // 대칭이 유지된다(예전 phantom spacer 가 잡던 폭을 그대로 차지).
            // 안 읽은 알림이 있으면 종 위에 빨강 카운트 뱃지.
            barButton {
                Image(systemName: "bell")
                    .font(.callout)
                    .overlay(alignment: .topTrailing) {
                        if unreadCount > 0 {
                            Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.red, in: Capsule())
                                .fixedSize()
                                .offset(x: 10, y: -7)
                        }
                    }
            } action: {
                onAlerts()
            }
            .accessibilityLabel(unreadCount > 0 ? "알림 \(unreadCount)건" : "알림")
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
