import Foundation

// 하단 탭 선택 상태. 히스토리 탭(value 4, role:.search)은 탭 전환이 아니라 순수
// 버튼(마지막 상세 재노출) — selectedTab 을 4 로 바꾸지 않는다. 4 로 바꾸면 그
// 탭의 빈 Color.clear 가 한 프레임 노출돼 상세 슬라이드-인 중 화면이 깜빡인다.
// 재노출(detail.show)은 RootTabView 가 selectedTab 을 건드리지 않고 부수효과로
// 처리한다.
struct HistoryTabSelectionState: Equatable {
    var selectedTab: Int

    init(selectedTab: Int = 0) {
        self.selectedTab = selectedTab
    }

    // 히스토리(4)는 선택 탭이 아니므로 무시 — 언더레이가 직전 탭 그대로 유지돼
    // 깜빡이지 않는다. 그 외 값만 실제 탭 전환.
    mutating func selectTab(_ newTab: Int) {
        guard newTab != 4 else { return }
        selectedTab = newTab
    }
}
